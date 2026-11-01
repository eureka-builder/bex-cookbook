// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CycleExecutor, TipFailed, RemainderFailed} from "../src/CycleExecutor.sol";
import {Pools} from "../src/lib/Pools.sol";
import {Leg, Plan, V3, Venues, UnexpectedCallback} from "../src/Types.sol";

/// Plain ERC20 balances, mintable.
contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// WETH: mintable for funding pools; `withdraw` pays real ETH (the test deals it ETH backing).
contract MockWETH is MockToken {
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "withdraw");
    }

    receive() external payable {}
}

interface IV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// A V3 pool at a fixed price, one direction (tokenIn -> tokenOut): sends `in * NUM / DEN` first, then
/// calls back for the input and checks it arrived, like the real pool. Etched at the derived address;
/// its state is only immutables and token balances.
contract MockV3Pool {
    address immutable TOKEN_IN;
    address immutable TOKEN_OUT;
    uint256 immutable NUM;
    uint256 immutable DEN;

    constructor(address tokenIn, address tokenOut, uint256 num, uint256 den) {
        (TOKEN_IN, TOKEN_OUT, NUM, DEN) = (tokenIn, tokenOut, num, den);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 d0, int256 d1)
    {
        require(zeroForOne == (TOKEN_IN < TOKEN_OUT), "direction");
        uint256 amountIn = uint256(amountSpecified);
        uint256 out = amountIn * NUM / DEN;
        MockToken(TOKEN_OUT).transfer(recipient, out);
        (d0, d1) = zeroForOne ? (int256(amountIn), -int256(out)) : (-int256(out), int256(amountIn));
        uint256 before = MockToken(TOKEN_IN).balanceOf(address(this));
        IV3SwapCallback(msg.sender).uniswapV3SwapCallback(d0, d1, data);
        require(MockToken(TOKEN_IN).balanceOf(address(this)) >= before + amountIn, "not paid");
    }
}

/// A payee (coinbase or caller) whose receive() tries every way back into the executor during the payout.
/// Each must revert UnexpectedCallback. With `bubble`, it then reverts itself, so the payout and the whole
/// cycle revert; without, it counts the blocked attempts and takes the ETH.
contract ReenteringPayee {
    error Reentered(bytes reason);

    CycleExecutor immutable EX;
    bool immutable BUBBLE;
    uint256 public blocked;

    constructor(CycleExecutor ex, bool bubble) {
        (EX, BUBBLE) = (ex, bubble);
    }

    function _try(bytes memory callData) internal {
        (bool ok, bytes memory reason) = address(EX).call(callData);
        if (ok || bytes4(reason) != UnexpectedCallback.selector) revert("re-entry not blocked");
        if (BUBBLE) revert Reentered(reason);
        ++blocked;
    }

    receive() external payable {
        Plan memory empty;
        _try(abi.encodeCall(CycleExecutor.execute, (empty)));
        _try(abi.encodeCall(CycleExecutor.sweep, (address(0))));
        _try(abi.encodeCall(CycleExecutor.uniswapV3SwapCallback, (1, -1, "")));
        _try(abi.encodeCall(CycleExecutor.uniswapV2Call, (address(EX), 1, 0, "")));
        _try(abi.encodeCall(CycleExecutor.unlockCallback, ("")));
    }
}

/// No receive, no fallback: refuses ETH.
contract NoReceive {}

/// Payout invariants without a fork: a WETH -> TKN -> WETH cycle on two mock V3 pools that pays 10%.
contract ExecutorPayoutTest is Test {
    uint256 constant IN = 1 ether;
    uint256 constant OUT = 1.1 ether; // 1 WETH -> 2000 TKN -> 1.1 WETH
    uint256 constant PROFIT = OUT - IN;

    MockWETH weth;
    MockToken tkn;
    CycleExecutor executor;
    Venues v;
    address pool0;
    address pool1;
    address COINBASE = makeAddr("payout coinbase");
    address CALLER = makeAddr("payout caller");

    function setUp() public {
        weth = new MockWETH();
        tkn = new MockToken();
        v = Venues(address(0xF2), bytes32(uint256(2)), address(0xF3), bytes32(uint256(3)), address(0xF4), address(weth));
        executor = new CycleExecutor(v);
        pool0 = Pools.v3Pool(v, address(weth), address(tkn), 500);
        pool1 = Pools.v3Pool(v, address(tkn), address(weth), 3000);
        vm.etch(pool0, address(new MockV3Pool(address(weth), address(tkn), 2000, 1)).code);
        vm.etch(pool1, address(new MockV3Pool(address(tkn), address(weth), 11, 20000)).code);
        tkn.mint(pool0, 1_000_000 ether);
        weth.mint(pool1, 1_000 ether);
        vm.deal(address(weth), 1_000 ether); // ETH backing for withdraw
        vm.deal(CALLER, 1 ether); // a transaction's sender is never an empty account
        vm.coinbase(COINBASE);
    }

    address RECIPIENT = makeAddr("payout recipient");

    /// recipient address(0): the remainder goes to the caller.
    function plan(uint16 share) internal view returns (Plan memory) {
        return plan(share, address(0));
    }

    function plan(uint16 share, address recipient) internal view returns (Plan memory) {
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V3, address(weth), address(tkn), 500, 10);
        legs[1] = Leg(V3, address(tkn), address(weth), 3000, 60);
        return Plan(IN, OUT, PROFIT, share, recipient, bytes32(uint256(0xaa)), legs);
    }

    function holdings() internal view returns (uint256) {
        return address(executor).balance + weth.balanceOf(address(executor));
    }

    function test_mockCycle_lands() public {
        vm.prank(CALLER);
        executor.execute(plan(5000));
        assertEq(COINBASE.balance, PROFIT / 2);
        assertEq(CALLER.balance, 1 ether + PROFIT / 2);
        assertEq(holdings(), 0);
    }

    // ---- recipient: the remainder goes to the plan's recipient, not the caller ----

    function test_recipient_getsRemainder_callerNothing() public {
        vm.prank(CALLER);
        executor.execute(plan(5000, RECIPIENT));
        assertEq(COINBASE.balance, PROFIT / 2);
        assertEq(RECIPIENT.balance, PROFIT - PROFIT / 2, "the recipient got the rest");
        assertEq(CALLER.balance, 1 ether, "the caller got nothing");
        assertEq(holdings(), 0);
    }

    function test_recipient_fullShare_getsNothing() public {
        vm.prank(CALLER);
        executor.execute(plan(10000, RECIPIENT));
        assertEq(COINBASE.balance, PROFIT);
        assertEq(RECIPIENT.balance, 0);
        assertEq(CALLER.balance, 1 ether);
    }

    /// A recipient that cannot take ETH fails the remainder: the whole cycle reverts, and the caller
    /// cannot take the recipient's place.
    function test_recipientRefusesEth_cycleReverts_noStateChange() public {
        address nr = address(new NoReceive());
        uint256 p0 = weth.balanceOf(pool1);
        vm.prank(CALLER);
        vm.expectRevert(RemainderFailed.selector);
        executor.execute(plan(5000, nr));
        assertEq(weth.balanceOf(pool1), p0);
        assertEq(COINBASE.balance, 0);
        assertEq(nr.balance, 0);
        assertEq(CALLER.balance, 1 ether);
        assertEq(holdings(), 0);
    }

    /// The recipient is paid with the re-entrancy guard set, like the caller.
    function test_recipientReentry_blocked_cycleLands() public {
        ReenteringPayee payee = new ReenteringPayee(executor, false);
        vm.prank(CALLER);
        executor.execute(plan(5000, address(payee)));
        assertEq(payee.blocked(), 5, "every re-entry reverted UnexpectedCallback");
        assertEq(address(payee).balance, PROFIT - PROFIT / 2);
        assertEq(COINBASE.balance, PROFIT / 2);
        assertEq(CALLER.balance, 1 ether);
        assertEq(holdings(), 0);
    }

    // ---- balances already in the executor are never profit ----

    /// 1 ETH and 1 WETH sit in the executor before the cycle. Only the cycle's own profit is paid out (in
    /// ETH, so the standing ETH may fund it while the profit stays as WETH: one asset). The 2 ETH-equivalent
    /// stay, and anyone can sweep them to coinbase afterwards.
    function test_standingEthAndWeth_notPaidOut_thenSweepable() public {
        vm.deal(address(executor), 1 ether);
        weth.mint(address(executor), 1 ether);
        vm.prank(CALLER);
        executor.execute(plan(5000));
        assertEq(COINBASE.balance, PROFIT / 2, "tip is the cycle's share only");
        assertEq(CALLER.balance - 1 ether, PROFIT - PROFIT / 2, "remainder is the cycle's rest only");
        assertEq(holdings(), 2 ether, "standing ETH+WETH unchanged");

        uint256 cb = COINBASE.balance;
        vm.startPrank(makeAddr("anyone"));
        executor.sweep(address(0));
        executor.sweep(address(weth));
        vm.stopPrank();
        assertEq(COINBASE.balance - cb + weth.balanceOf(COINBASE), 2 ether, "swept to coinbase");
        assertEq(holdings(), 0);
    }

    function test_standingWethOnly_notPaidOut() public {
        weth.mint(address(executor), 1 ether);
        vm.prank(CALLER);
        executor.execute(plan(9000));
        assertEq(COINBASE.balance, PROFIT * 9000 / 10000);
        assertEq(CALLER.balance - 1 ether, PROFIT - PROFIT * 9000 / 10000);
        assertEq(holdings(), 1 ether);
    }

    // ---- payees cannot re-enter during the payout ----

    function test_coinbaseReentry_blocked_cycleLands() public {
        ReenteringPayee payee = new ReenteringPayee(executor, false);
        vm.coinbase(address(payee));
        vm.prank(CALLER);
        executor.execute(plan(5000));
        assertEq(payee.blocked(), 5, "every re-entry reverted UnexpectedCallback");
        assertEq(address(payee).balance, PROFIT / 2);
        assertEq(CALLER.balance - 1 ether, PROFIT - PROFIT / 2);
        assertEq(holdings(), 0);
    }

    function test_callerReentry_blocked_cycleLands() public {
        ReenteringPayee payee = new ReenteringPayee(executor, false);
        vm.prank(address(payee));
        executor.execute(plan(5000));
        assertEq(payee.blocked(), 5);
        assertEq(address(payee).balance, PROFIT - PROFIT / 2);
        assertEq(COINBASE.balance, PROFIT / 2);
        assertEq(holdings(), 0);
    }

    /// A coinbase that reverts after its blocked re-entry fails the tip: the whole cycle reverts.
    function test_coinbaseReentry_bubbles_cycleReverts_noStateChange() public {
        ReenteringPayee payee = new ReenteringPayee(executor, true);
        vm.coinbase(address(payee));
        uint256 p0 = weth.balanceOf(pool1);
        uint256 t0 = tkn.balanceOf(pool0);
        vm.prank(CALLER);
        vm.expectRevert(TipFailed.selector);
        executor.execute(plan(5000));
        assertEq(weth.balanceOf(pool1), p0);
        assertEq(tkn.balanceOf(pool0), t0);
        assertEq(address(payee).balance, 0);
        assertEq(CALLER.balance, 1 ether);
        assertEq(holdings(), 0);
    }

    function test_callerReentry_bubbles_cycleReverts_noStateChange() public {
        ReenteringPayee payee = new ReenteringPayee(executor, true);
        uint256 p0 = weth.balanceOf(pool1);
        vm.prank(address(payee));
        vm.expectRevert(RemainderFailed.selector);
        executor.execute(plan(5000));
        assertEq(weth.balanceOf(pool1), p0);
        assertEq(COINBASE.balance, 0);
        assertEq(address(payee).balance, 0);
        assertEq(holdings(), 0);
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {ForkTest, _v, WETH} from "./Fork.t.sol";
import {V2Pusher, V3Pusher, V4Pusher} from "./Push.sol";
import {CycleExecutor, RemainderFailed} from "../src/CycleExecutor.sol";
import {CycleSolver} from "../src/CycleSolver.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {Pools} from "../src/lib/Pools.sol";
import {LegSim} from "../src/lib/LegSim.sol";
import {LegProbe} from "./LegProbe.sol";
import {Leg, Plan, V2, V3, V4, BadLeg, ProfitBelowPlan, UnexpectedCallback} from "../src/Types.sol";

/// A V2 pair etched at a derived address: its swap re-enters `execute` and reports why that failed.
contract ReenteringPair {
    error Reentered(bytes reason);

    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (1e18, 1e18, 0);
    }

    function swap(uint256, uint256, address to, bytes calldata) external {
        Plan memory empty;
        try CycleExecutor(payable(to)).execute(empty) {
            revert("re-entry succeeded");
        } catch (bytes memory reason) {
            revert Reentered(reason);
        }
    }
}

/// Like ReenteringPair, but its swap calls `sweep` mid-cycle.
contract SweepingPair {
    error Reentered(bytes reason);

    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (1e18, 1e18, 0);
    }

    function swap(uint256, uint256, address to, bytes calldata) external {
        try CycleExecutor(payable(to)).sweep(address(0)) {
            revert("sweep succeeded");
        } catch (bytes memory reason) {
            revert Reentered(reason);
        }
    }
}

/// A caller that cannot take ETH: no receive, no fallback.
contract NoReceive {}

/// An ERC20 that burns 1% of every transfer sent by `taxedSender` (here: its V2 pair), so what the pair
/// sends is not what arrives.
contract FeeToken {
    mapping(address => uint256) public balanceOf;
    address public taxedSender;

    function setTaxedSender(address a) external {
        taxedSender = a;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += msg.sender == taxedSender ? amount - amount / 100 : amount;
        return true;
    }
}

interface IV2FactoryCreate {
    function createPair(address a, address b) external returns (address);
}

interface IV2PairMint {
    function mint(address to) external returns (uint256);
}

interface IV3FactoryCreate {
    function createPool(address a, address b, uint24 fee) external returns (address);
}

interface IV3PoolSeed {
    function initialize(uint160 sqrtPriceX96) external;
    function mint(address recipient, int24 tickLower, int24 tickUpper, uint128 amount, bytes calldata data)
        external
        returns (uint256, uint256);
}

/// Transient storage lasts one transaction. Under `forge test --isolate` every call the test makes is
/// its own transaction, so what `set` stores is gone by `get`.
contract TxProbe {
    function set() external {
        assembly {
            tstore(0, 1)
        }
    }

    function get() external view returns (uint256 v) {
        assembly {
            v := tload(0)
        }
    }
}

/// The fork fixtures of the executor tests: pushes, cycles, execute-and-check and the budget-corner pools.
abstract contract ExecutorFork is ForkTest {
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant USDT_WETH_V3_1BP = 0xc7bBeC68d12a0d1830360F8Ec58fA599bA1b0e9b;
    address constant USDC_WETH_V2 = 0xB4e16d0168e52d35CaCD2c6185b44281Ec28C9Dc;
    uint256 constant PUSH_V4 = 30 ether;
    uint256 constant PUSH = 300 ether;

    CycleSolver solver;
    CycleExecutor executor;
    IWETH weth = IWETH(WETH);
    address COINBASE = makeAddr("bex-backrun test coinbase");
    address CALLER = makeAddr("bex-backrun test caller");
    /// The bot's convention: the signer address, left-padded.
    bytes32 constant TAG = bytes32(uint256(0xaa));

    function setUp() public override {
        super.setUp();
        solver = new CycleSolver(_v());
        executor = new CycleExecutor(_v());
        vm.coinbase(COINBASE);
        assertEq(COINBASE.code.length + CALLER.code.length, 0, "fresh EOAs on the fork");
        vm.deal(CALLER, 1 ether); // a transaction's sender has paid for gas: never an empty account
    }

    // ---- pushes ----

    function pushV3(address pool, bool wethIsToken0, uint256 wethIn) internal {
        vm.deal(address(this), wethIn);
        new V3Pusher().push{value: wethIn}(pool, wethIsToken0);
    }

    /// Sells WETH into the USDC/WETH 1bp pool (WETH is token1): WETH is cheap there.
    function pushUsdcWeth(uint256 wethIn) internal {
        pushV3(USDC_WETH_V3_1BP, false, wethIn);
    }

    /// Sells ETH into the V4 ETH/USDC 1bp pool: ETH is cheap there.
    function pushV4EthUsdc(uint256 ethIn) internal {
        vm.deal(address(this), ethIn);
        new V4Pusher().push{value: ethIn}(Pools.v4Key(Leg(V4, address(0), USDC, 100, 1)), ethIn);
    }

    /// Sells WETH into the USDC/WETH V2 pair (WETH is token1): WETH is cheap there.
    function pushV2UsdcWeth(uint256 wethIn) internal {
        vm.deal(address(this), wethIn);
        new V2Pusher().push{value: wethIn}(USDC_WETH_V2, false);
    }

    // ---- cycles ----

    /// Sell WETH on the 5bp pool, buy it back on the pushed 1bp pool.
    function cycleV3V3() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USDC, 500, 10);
        legs[1] = Leg(V3, USDC, WETH, 100, 1);
    }

    function cycleV2V3() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = Leg(V2, WETH, USDC, 3000, 0);
        legs[1] = Leg(V3, USDC, WETH, 100, 1);
    }

    function cycleV4V3() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = Leg(V4, address(0), USDC, 100, 1);
        legs[1] = Leg(V3, USDC, WETH, 100, 1);
    }

    function cycleV3V4() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V4, USDC, address(0), 100, 1);
    }

    function cycleV3V4V3() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](3);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V4, USDC, USDT, 7, 1);
        legs[2] = Leg(V3, USDT, WETH, 100, 1);
    }

    function cycleV3V2() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V2, USDC, WETH, 3000, 0);
    }

    /// The asset mid-cycle: leg 1 ends in ETH, leg 2 starts from WETH (wrapped between the legs).
    function cycleEthMidway() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](4);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V4, USDC, address(0), 100, 1);
        legs[2] = Leg(V3, WETH, USDT, 100, 1);
        legs[3] = Leg(V3, USDT, WETH, 500, 10);
    }

    /// Leg 2 is a V4 leg fed native ETH by leg 1: it settles ETH with i > 0.
    function cycleLaterV4Eth() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](4);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V4, USDC, address(0), 100, 1);
        legs[2] = Leg(V4, address(0), USDT, 100, 1);
        legs[3] = Leg(V3, USDT, WETH, 100, 1);
    }

    /// Ends on the pushed USDC/WETH 1bp pool; a V4 stable leg in the middle.
    function cycleFive() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](5);
        legs[0] = Leg(V3, WETH, USDT, 100, 1);
        legs[1] = Leg(V4, USDT, USDC, 7, 1);
        legs[2] = Leg(V3, USDC, DAI, 100, 1);
        legs[3] = Leg(V3, DAI, USDC, 500, 10);
        legs[4] = Leg(V3, USDC, WETH, 100, 1);
    }

    // ---- helpers ----

    function holdings(address a) internal view returns (uint256) {
        return a.balance + weth.balanceOf(a);
    }

    /// Leg `k`'s input on the plan's path, at the current state.
    function inputOfLeg(Plan memory p, uint256 k) internal view returns (uint256 amount) {
        amount = p.amountIn;
        for (uint256 j; j < k; ++j) {
            (amount,) = LegProbe.amountOut(_v(), p.legs[j], amount);
        }
    }

    function executeAndCheck(Plan memory p) internal returns (uint256 gasUsed) {
        return executeAndCheck(p, gasleft());
    }

    function executeAndCheck(Plan memory p, uint256 gasLimit) internal returns (uint256 gasUsed) {
        return executeAndCheck(p, gasLimit, CALLER);
    }

    /// Executes `p` as `caller` and checks the realised profit is the plan's, split exactly: the share to
    /// coinbase, the rest to the plan's recipient (the caller at address(0)) in ETH, nothing kept by the executor.
    function executeAndCheck(Plan memory p, uint256 gasLimit, address caller) internal returns (uint256 gasUsed) {
        uint256 cb = COINBASE.balance;
        uint256 ca = caller.balance;
        uint256 ex = holdings(address(executor));
        uint256 profit = p.amountOut - p.amountIn;
        uint256 tip = profit * p.builderShareBps / 10000;
        vm.expectEmit(true, true, false, true, address(executor));
        emit CycleExecutor.CycleExecuted(Pools.cycleId(p.legs), p.tag, p.amountIn, profit, tip);
        vm.prank(caller);
        uint256 g = gasleft();
        executor.execute{gas: gasLimit}(p);
        gasUsed = g - gasleft();
        assertEq(COINBASE.balance - cb, tip, "coinbase paid the share");
        assertEq(caller.balance - ca, profit - tip, "caller paid the rest in ETH");
        assertEq(holdings(address(executor)), ex, "executor keeps nothing");
    }

    // ---- budget-corner pools ----

    /// Ends on USDT/WETH 1bp like cycleV3V4V3, three more pools in between.
    function cycleFiveFresh() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](5);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V3, USDC, DAI, 100, 1);
        legs[2] = Leg(V3, DAI, USDC, 500, 10);
        legs[3] = Leg(V4, USDC, USDT, 7, 1);
        legs[4] = Leg(V3, USDT, WETH, 100, 1);
    }

    /// The 300 WETH push into USDT/WETH 1bp, then 16 tiny positions on the first 32 uninitialised ticks above
    /// the price (see test_freshTick_cycleBudget_executeUnder2M). Returns those ticks.
    function seedFreshTicks() internal returns (int24[] memory fresh) {
        IUniswapV3Pool pool = IUniswapV3Pool(USDT_WETH_V3_1BP);
        pushV3(USDT_WETH_V3_1BP, true, PUSH);
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 1 ether}();
        (, int24 tick,,,,,) = pool.slot0();
        fresh = new int24[](32);
        for (uint256 n; n < 32;) {
            (,,,,,,, bool init) = pool.ticks(++tick);
            if (!init) fresh[n++] = tick;
        }
        for (uint256 k; k < 32; k += 2) {
            IV3PoolSeed(address(pool)).mint(address(this), fresh[k], fresh[k + 1], 1e9, "");
        }
        for (uint256 k; k < 32; ++k) {
            (,, uint256 f0, uint256 f1,,,,) = pool.ticks(fresh[k]);
            assertEq(f0 | f1, 0, "precondition: minted above the price, fee growth outside is zero");
        }
    }

    /// WETH -> T1 -> ... -> WETH through n fresh full-range 1bp pools (see
    /// test_cycleBudget_emptySteps_executeUnder2M).
    function emptyStepsCycle(uint256 n) internal returns (Leg[] memory legs) {
        vm.deal(address(this), 1_000_000 ether);
        weth.deposit{value: 1_000_000 ether}();
        legs = new Leg[](n);
        address prev = WETH;
        for (uint256 i; i < n; ++i) {
            address next = WETH;
            if (i + 1 < n) {
                next = address(uint160(0x7e51 + i)); // ascending, below WETH
                vm.etch(next, address(new FeeToken()).code);
            }
            legs[i] = Leg(V3, prev, next, 100, 1);
            (address t0, address t1) = prev < next ? (prev, next) : (next, prev);
            IV3PoolSeed pool = IV3PoolSeed(IV3FactoryCreate(_v().v3Factory).createPool(t0, t1, 100));
            // price token1/token0: 6 when selling token0 (every leg but the first), 1/6 for WETH -> T1
            uint160 root6 = 194068571418249185253397768292; // sqrt(6)·2^96
            pool.initialize(i == 0 ? uint160((uint256(1) << 192) / root6) : root6);
            pool.mint(address(this), -887272, 887272, uint128(1e19 * 6 ** i), abi.encode(t0, t1));
            prev = next;
        }
    }

    function payMint(address token, uint256 amount) internal {
        if (token == WETH) IERC20(WETH).transfer(msg.sender, amount);
        else FeeToken(token).mint(msg.sender, amount);
    }

    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata data) external {
        if (data.length == 0) {
            // a mainnet pool whose token0 is WETH, minted above the price: WETH only
            assertEq(owed1, 0);
            IERC20(WETH).transfer(msg.sender, owed0);
            return;
        }
        if (data.length == 64) {
            (address t0, address t1) = abi.decode(data, (address, address));
            payMint(t0, owed0);
            payMint(t1, owed1);
            return;
        }
        address t = abi.decode(data, (address));
        (uint256 owedFot, uint256 owedWeth) = t < WETH ? (owed0, owed1) : (owed1, owed0);
        FeeToken(t).mint(msg.sender, owedFot);
        IERC20(WETH).transfer(msg.sender, owedWeth);
    }
}

contract CycleExecutorTest is ExecutorFork {
    // ---- landing ----

    function test_firstLegV3_landsAndPaysCoinbase() public {
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV3V3(), 0, 0, 9000, address(0), TAG);
        uint256 gasUsed = executeAndCheck(p);
        emit log_named_uint("gas 2-leg V3 (flash V3)", gasUsed);
    }

    function test_firstLegV2_lands() public {
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV2V3(), 0, 0, 10000, address(0), TAG);
        uint256 gasUsed = executeAndCheck(p); // share 10000: the caller gets nothing
        emit log_named_uint("gas 2-leg V2->V3 (flash V2)", gasUsed);
    }

    function test_firstLegV4_lands() public {
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV4V3(), 0, 0, 5000, address(0), TAG);
        uint256 gasUsed = executeAndCheck(p);
        emit log_named_uint("gas 2-leg V4->V3 (flash V4)", gasUsed);
    }

    /// WETH -> USDC on V3, USDC -> ETH on V4: the V3 repayment is wrapped from the V4 ETH output.
    function test_mixedV3V4V3_wrapsPerLeg() public {
        pushV4EthUsdc(30 ether);
        Plan memory p = solver.solve(cycleV3V4(), 0, 0, 5000, address(0), TAG);
        uint256 gasUsed = executeAndCheck(p);
        emit log_named_uint("gas 2-leg V3->V4 (wrap)", gasUsed);
    }

    /// WETH -> USDC (V3) -> USDT (V4, ERC20 settle) -> WETH (V3, pushed).
    function test_mixedV3V4V3_threeLegs() public {
        pushV3(USDT_WETH_V3_1BP, true, PUSH);
        Plan memory p = solver.solve(cycleV3V4V3(), 0, 0, 5000, address(0), TAG);
        uint256 gasUsed = executeAndCheck(p);
        emit log_named_uint("gas 3-leg V3->V4->V3", gasUsed);
    }

    function test_laterLegV2_lands() public {
        pushV2UsdcWeth(100 ether);
        Plan memory p = solver.solve(cycleV3V2(), 0, 0, 9000, address(0), TAG);
        uint256 gasUsed = executeAndCheck(p);
        emit log_named_uint("gas 2-leg V3->V2 (V2 later leg)", gasUsed);
    }

    /// WETH -> USDC (V3) -> ETH (V4) -> [wrap] -> WETH -> USDT (V3) -> WETH (V3).
    function test_ethMidway_wrapsBetweenLegs() public {
        pushV4EthUsdc(PUSH_V4);
        Plan memory p = solver.solve(cycleEthMidway(), 0, 0, 9000, address(0), TAG);
        vm.expectCall(WETH, inputOfLeg(p, 2), abi.encodeCall(IWETH.deposit, ()), 1);
        uint256 gasUsed = executeAndCheck(p);
        emit log_named_uint("gas 4-leg V3->V4->V3->V3 (wrap midway)", gasUsed);
    }

    /// WETH -> USDC (V3) -> ETH (V4) -> USDT (V4, settles native ETH as leg 2) -> WETH (V3).
    function test_laterV4Leg_settlesNativeEth() public {
        pushV4EthUsdc(PUSH_V4);
        Plan memory p = solver.solve(cycleLaterV4Eth(), 0, 0, 9000, address(0), TAG);
        vm.expectCall(POOL_MANAGER, inputOfLeg(p, 2), abi.encodeCall(IPoolManager.settle, ()), 1);
        uint256 gasUsed = executeAndCheck(p);
        emit log_named_uint("gas 4-leg V3->V4->V4->V3 (native settle, leg 2)", gasUsed);
    }

    function test_fiveLegs_underGasCap() public {
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleFive(), 0, 0, 9000, address(0), TAG);
        uint256 gasUsed = executeAndCheck(p);
        emit log_named_uint("gas 5-leg", gasUsed);
        assertLt(gasUsed, 2_000_000);
    }

    /// Pushed far past the cycle budgets, the solver returns the largest input that fits, and `execute`
    /// of that plan fits the builder's 2M gas. The gas is real only when `execute` is its own transaction
    /// (cold slots, SSTORE prices from the state before it); in one test transaction the push and the
    /// solve have warmed everything. So run it isolated, where the gas limit is the transaction's:
    ///   ETH_RPC_URL=<archive rpc> forge test --isolate --match-test test_cycleBudget_executeUnder2M -vv
    /// Without --isolate it still checks that the plans sit at the budget and land.
    function test_cycleBudget_executeUnder2M() public {
        TxProbe t = new TxProbe();
        t.set();
        bool isolated = t.get() == 0;
        emit log_named_string("gas below is", isolated ? "isolated (real)" : "warm (run with --isolate)");

        uint256 snap = vm.snapshotState();
        pushUsdcWeth(3000 ether); // far past the budget: the plan stops at it
        landAtBudget(solver.solve(cycleFive(), 0, 0, 9000, address(0), TAG), "gas 5-leg at the cycle budget");
        vm.revertToState(snap);
        pushV3(USDT_WETH_V3_1BP, true, PUSH); // past the budget too
        landAtBudget(solver.solve(cycleV3V4V3(), 0, 0, 5000, address(0), TAG), "gas 3-leg at the cycle budget");
    }

    /// The cycle budget when the crossings are fresh ticks. A tick initialised while above the price starts with
    /// feeGrowthOutside0/1 = 0, so its first upward crossing writes both slots zero to non-zero (~+34k gas).
    /// After the 300 WETH push into USDT/WETH 1bp (WETH is token0: price down), 16 tiny positions take the first
    /// 32 uninitialised ticks above the price; the backrun's USDT -> WETH leg crosses them going up, before any
    /// other tick. Measure isolated, like test_cycleBudget_executeUnder2M:
    ///   ETH_RPC_URL=<archive rpc> forge test --isolate --match-test test_freshTick -vv
    function test_freshTick_cycleBudget_executeUnder2M() public {
        uint256 snap = vm.snapshotState();
        landFresh(cycleV3V4V3(), "gas 3-leg at the cycle budget, fresh ticks");
        vm.revertToState(snap);
        landFresh(cycleFiveFresh(), "gas 5-leg at the cycle budget, fresh ticks");
    }

    function landFresh(Leg[] memory legs, string memory tag) internal {
        int24[] memory fresh = seedFreshTicks();
        IUniswapV3Pool pool = IUniswapV3Pool(USDT_WETH_V3_1BP);
        Plan memory p = solver.solve(legs, 0, 0, 5000, address(0), TAG);
        (, uint8 crossings,,) = LegSim.tryCycleOut(_v(), p.legs, p.amountIn);
        landAtBudget(p, tag);
        emit log_named_uint("  crossings", crossings);
        uint256 crossedFresh;
        for (uint256 k; k < 32; ++k) {
            (,, uint256 f0, uint256 f1,,,,) = pool.ticks(fresh[k]);
            if (f0 != 0 && f1 != 0) ++crossedFresh;
        }
        emit log_named_uint("  of them fresh (zero -> non-zero writes)", crossedFresh);
        assertGe(crossedFresh * 4, uint256(crossings) * 3, "most crossings are fresh");
    }

    /// The cycle budget spent on empty steps only. WETH -> T1 -> ... -> WETH through fresh 1bp pools
    /// (tick spacing 1) with full-range liquidity alone, so every 256 ticks of price is a step that
    /// reads an empty bitmap word and crosses nothing. Every pool pays 6 out per 1 in, and pool i is
    /// 6^i times deeper, so the steps spread over the legs and the optimum lies far past the budget.
    /// Measure isolated:
    ///   ETH_RPC_URL=<archive rpc> forge test --isolate --match-test test_cycleBudget -vv
    function test_cycleBudget_emptySteps_executeUnder2M() public {
        uint256 snap = vm.snapshotState();
        landEmptySteps(3, "gas 3-leg at the cycle budget, empty steps");
        vm.revertToState(snap);
        landEmptySteps(5, "gas 5-leg at the cycle budget, empty steps");
    }

    function landEmptySteps(uint256 n, string memory tag) internal {
        Leg[] memory legs = emptyStepsCycle(n);
        Plan memory p = solver.solve(legs, 0, 0, 5000, address(0), TAG);
        (, uint8 crossings,,) = LegSim.tryCycleOut(_v(), p.legs, p.amountIn);
        assertEq(crossings, 0, "empty steps only");
        landAtBudget(p, tag);
    }

    function landAtBudget(Plan memory p, string memory tag) internal {
        // The solver's walk stops just before the boundary that would pass the crossing budget. The budget
        // is a cap, not a target, so "at the budget" here means within 10% of it.
        (,,, bool fits) = LegSim.tryCycleOut(_v(), p.legs, p.amountIn * 110 / 100);
        assertFalse(fits, "10% more input is past the cycle budget");
        emit log_named_uint(tag, executeAndCheck(p, 2_000_000));
    }

    // ---- received amounts ----

    /// A leftover intermediate token (e.g. from an earlier partial fill) never funds a leg: the plan's
    /// profit is what the builder gets and the leftover stays put.
    function test_leftoverIntermediateTokenIsNotSpent() public {
        pushUsdcWeth(PUSH);
        vm.prank(USDC_WETH_V2); // a USDC holder off the cycle's path
        IERC20(USDC).transfer(address(executor), 100_000e6);
        Plan memory p = solver.solve(cycleV3V3(), 0, 0, 10000, address(0), TAG);
        executeAndCheck(p);
        assertEq(IERC20(USDC).balanceOf(address(executor)), 100_000e6, "leftover USDC untouched");
    }

    /// WETH -> FOT on a fresh V2 pair whose sends lose 1% in transit, FOT -> WETH on a fresh V3 pool.
    /// Leg 1 runs on what arrived. With a leftover FOT balance present the nominal amount would land
    /// (subsidised by the leftover, inflating the profit); without one it would revert in the token.
    function test_feeOnTransferIntermediate_usesReceivedAmount() public {
        FeeToken fot = new FeeToken();
        address t = address(fot);
        vm.deal(address(this), 300 ether);
        weth.deposit{value: 300 ether}();

        // V2: 1000 FOT per WETH, 100 WETH deep.
        address pair = IV2FactoryCreate(_v().v2Factory).createPair(t, WETH);
        fot.mint(pair, 100_000 ether);
        IERC20(WETH).transfer(pair, 100 ether);
        IV2PairMint(pair).mint(address(this));
        fot.setTaxedSender(pair);

        // V3 0.3%: 900 FOT per WETH, full range, ~100 WETH deep.
        address pool = IV3FactoryCreate(_v().v3Factory).createPool(t, WETH, 3000);
        IV3PoolSeed(pool).initialize(t < WETH ? uint160(uint256(2 ** 96) / 30) : uint160(30 * 2 ** 96));
        IV3PoolSeed(pool).mint(address(this), -887220, 887220, 3000 ether, abi.encode(t));

        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V2, WETH, t, 3000, 0);
        legs[1] = Leg(V3, t, WETH, 3000, 60);
        uint256 amountIn = 1 ether;
        (uint256 sent,) = LegProbe.amountOut(_v(), legs[0], amountIn);
        (uint256 amountOut,) = LegProbe.amountOut(_v(), legs[1], sent - sent / 100);
        assertGt(amountOut, amountIn, "the cycle pays after the 1% tax");

        fot.mint(address(executor), 50_000 ether); // a leftover the chain must not touch
        executeAndCheck(Plan(amountIn, amountOut, amountOut - amountIn, 10000, address(0), TAG, legs));
        assertEq(fot.balanceOf(address(executor)), 50_000 ether, "FOT balance unchanged");
    }

    // ---- failure paths ----

    /// Profit of running `p` at the current state.
    function realized(Plan memory p) internal view returns (uint256) {
        (uint256 out,,, bool ok) = LegSim.tryCycleOut(_v(), p.legs, p.amountIn);
        return ok && out > p.amountIn ? out - p.amountIn : 0;
    }

    /// Someone else runs the same cycle with a fraction of the plan's input: the state moves against `p`.
    function drift(Plan memory p, uint256 num, uint256 den) internal {
        Plan memory q = Plan(p.amountIn * num / den, 0, 1, 10000, address(0), TAG, p.legs);
        new CycleExecutor(_v()).execute(q);
    }

    /// A plan solved at one state still executes after an adverse move while the realized profit
    /// clears the caller's floor, and pays the realized tip; under the floor it reverts.
    function test_execute_profitBetweenFloorAndSolved_paysRealized() public {
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV3V3(), 0, 0, 10000, address(0), TAG);
        uint256 solved = p.amountOut - p.amountIn;
        uint256 floor = solved / 4;
        p = solver.solve(cycleV3V3(), floor, 0, 10000, address(0), TAG);
        assertEq(p.minProfit, floor);
        assertLt(p.minProfit, p.amountOut - p.amountIn, "floor below the solved profit");

        uint256 snap = vm.snapshotState();
        drift(p, 1, 2);
        uint256 profit = realized(p);
        assertLt(profit, solved, "state moved against the plan");
        assertGe(profit, floor, "still above the floor");
        uint256 tip = profit * p.builderShareBps / 10000;
        uint256 cb = COINBASE.balance;
        vm.expectEmit(true, true, false, true, address(executor));
        emit CycleExecutor.CycleExecuted(Pools.cycleId(p.legs), p.tag, p.amountIn, profit, tip);
        executor.execute(p);
        assertEq(COINBASE.balance - cb, tip, "coinbase paid the realized share");

        vm.revertToState(snap);
        drift(p, 1, 1);
        drift(p, 1, 4); // after a full arb the sim calls the input infeasible; a quarter more lands in (0, floor)
        uint256 low = realized(p);
        assertGt(low, 0, "the cycle still pays");
        assertLt(low, floor, "drifted under the floor");
        // the same state, floor 1: it executes, so the floor alone rejects `p`
        uint256 snap2 = vm.snapshotState();
        Plan memory loose = Plan(p.amountIn, p.amountOut, 1, p.builderShareBps, address(0), p.tag, p.legs);
        vm.expectEmit(true, true, false, true, address(executor));
        emit CycleExecutor.CycleExecuted(Pools.cycleId(p.legs), p.tag, p.amountIn, low, low * p.builderShareBps / 10000);
        executor.execute(loose);
        vm.revertToState(snap2);
        vm.expectRevert(ProfitBelowPlan.selector);
        executor.execute(p);
    }

    /// A plan demanding more than the moved state pays reverts and moves no funds.
    function test_belowPlanFloor_revertsAndMovesNothing() public {
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV3V3(), 0, 0, 10000, address(0), TAG);
        new CycleExecutor(_v()).execute(p); // someone else takes the arb
        p.minProfit = p.amountOut - p.amountIn; // the solved profit is gone; the solver's own floor is only 1

        uint256 cb = COINBASE.balance;
        uint256 ex = holdings(address(executor));
        vm.expectRevert(ProfitBelowPlan.selector);
        executor.execute(p);
        assertEq(COINBASE.balance, cb);
        assertEq(holdings(address(executor)), ex);
    }

    /// The cycle still pays, but less than the plan demands: the final balance check rejects it.
    function test_profitBelowMinProfit_reverts() public {
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV3V3(), 0, 0, 10000, address(0), TAG);
        p.minProfit = realized(p) + 1;
        vm.expectRevert(ProfitBelowPlan.selector);
        executor.execute(p);
    }

    function test_strangerCallback_reverts() public {
        vm.expectRevert(UnexpectedCallback.selector);
        executor.uniswapV3SwapCallback(1, -1, "");
        vm.expectRevert(UnexpectedCallback.selector);
        executor.uniswapV2Call(address(this), 1, 0, "");
        vm.expectRevert(UnexpectedCallback.selector);
        executor.unlockCallback("");
        // the pool manager itself cannot call in uninvited either
        vm.prank(POOL_MANAGER);
        vm.expectRevert(UnexpectedCallback.selector);
        executor.unlockCallback("");
    }

    function test_badLeg_revertsBeforeAnyCall() public {
        Leg[] memory legs = cycleV3V3();
        legs[0].fee = 123; // no such V3 fee tier
        Plan memory p = Plan(1 ether, 2 ether, 0, 10000, address(0), TAG, legs);
        vm.expectCall(Pools.v3Pool(_v(), WETH, USDC, 123), "", 0);
        vm.expectCall(USDC_WETH_V3_1BP, "", 0);
        vm.expectRevert(BadLeg.selector);
        executor.execute(p);
    }

    function test_uninitialisedV4Pool_revertsBadLeg() public {
        Leg[] memory legs = cycleV4V3();
        legs[0].fee = 123;
        vm.expectRevert(BadLeg.selector);
        executor.execute(Plan(1 ether, 2 ether, 0, 10000, address(0), TAG, legs));
    }

    function test_shareAbove10000_revertsBadLeg() public {
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV3V3(), 0, 0, 10001, address(0), TAG);
        vm.expectRevert(BadLeg.selector);
        executor.execute(p);
    }

    function test_reentrantExecute_reverts() public {
        address token = address(0xBEEF);
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V2, WETH, token, 3000, 0);
        legs[1] = Leg(V3, token, WETH, 3000, 60); // a distinct pool; it only needs code, leg 0 re-enters first
        vm.etch(token, address(new FeeToken()).code); // `execute` reads the output token's balance
        vm.etch(Pools.v2Pair(_v(), WETH, token), address(new ReenteringPair()).code);
        vm.etch(Pools.v3Pool(_v(), token, WETH, 3000), address(new ReenteringPair()).code);

        vm.expectRevert(
            abi.encodeWithSelector(
                ReenteringPair.Reentered.selector, abi.encodeWithSelector(UnexpectedCallback.selector)
            )
        );
        executor.execute(Plan(1e15, 0, 0, 10000, address(0), TAG, legs));
    }

    // ---- permissionless ----

    /// Any EOA can run a cycle; it gets the profit left after the builder's share, in ETH.
    function test_anyoneCanExecute_callerGetsRemainder() public {
        address stranger = makeAddr("a random EOA");
        vm.deal(stranger, 1 ether);
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV3V3(), 0, 0, 7000, address(0), TAG);
        assertGt(p.amountOut - p.amountIn, 0);
        executeAndCheck(p, gasleft(), stranger);
        assertGt(stranger.balance, 1 ether, "the remainder arrived");
    }

    function test_fullShare_callerGetsNothing() public {
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV3V3(), 0, 0, 10000, address(0), TAG);
        uint256 cb = COINBASE.balance;
        vm.prank(CALLER);
        executor.execute(p);
        assertEq(CALLER.balance, 1 ether, "caller unchanged");
        assertEq(COINBASE.balance - cb, p.amountOut - p.amountIn, "coinbase got the whole profit");
    }

    /// The remainder must reach the caller: a caller that cannot take ETH reverts the whole cycle.
    function test_remainderToNonReceiver_revertsWithoutStateChange() public {
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV3V3(), 0, 0, 9000, address(0), TAG);
        address nr = address(new NoReceive());
        (uint160 sqrtBefore,,,,,,) = IUniswapV3Pool(USDC_WETH_V3_1BP).slot0();
        uint256 cb = COINBASE.balance;
        uint256 ex = holdings(address(executor));
        vm.prank(nr);
        vm.expectRevert(RemainderFailed.selector);
        executor.execute(p);
        (uint160 sqrtAfter,,,,,,) = IUniswapV3Pool(USDC_WETH_V3_1BP).slot0();
        assertEq(sqrtAfter, sqrtBefore, "pool untouched");
        assertEq(COINBASE.balance, cb, "coinbase unpaid");
        assertEq(holdings(address(executor)), ex, "executor unchanged");
        assertEq(nr.balance, 0);
    }

    /// Partial-fill dust (any token, ETH, WETH) goes to whoever builds the block that sweeps it.
    function test_sweep_sendsDustToCoinbase_anyone() public {
        vm.deal(address(executor), 1 ether);
        vm.prank(USDC_WETH_V2); // a USDC holder
        IERC20(USDC).transfer(address(executor), 123e6);
        uint256 cb = COINBASE.balance;
        vm.startPrank(makeAddr("a random EOA"));
        executor.sweep(address(0));
        executor.sweep(USDC);
        executor.sweep(WETH); // nothing there: a no-op
        vm.stopPrank();
        assertEq(COINBASE.balance - cb, 1 ether);
        assertEq(IERC20(USDC).balanceOf(COINBASE), 123e6);
        assertEq(address(executor).balance + IERC20(USDC).balanceOf(address(executor)), 0);
    }

    // ---- tag ----

    /// The caller's tag goes solve -> Plan -> execute -> the event's second indexed topic.
    function test_tag_roundTripsSolveToEvent() public {
        bytes32 tag = keccak256("some sender");
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV3V3(), 0, 0, 9000, address(0), tag);
        assertEq(p.tag, tag, "solve echoes the tag");
        vm.recordLogs();
        executeAndCheck(p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(executor)) continue;
            assertEq(logs[i].topics[0], CycleExecutor.CycleExecuted.selector);
            assertEq(logs[i].topics[1], Pools.cycleId(p.legs));
            assertEq(logs[i].topics[2], tag, "topic 2 is the tag");
            ++found;
        }
        assertEq(found, 1);
    }

    /// The tag is a label only: the same plan under another tag pays exactly the same.
    function test_tag_doesNotAffectFunds() public {
        pushUsdcWeth(PUSH);
        Plan memory p = solver.solve(cycleV3V3(), 0, 0, 7000, address(0), TAG);
        uint256 snap = vm.snapshotState();
        (uint256 cbA, uint256 caA) = (COINBASE.balance, CALLER.balance);
        vm.prank(CALLER);
        executor.execute(p);
        (cbA, caA) = (COINBASE.balance - cbA, CALLER.balance - caA);
        vm.revertToState(snap);
        p.tag = keccak256("someone else's tag");
        (uint256 cbB, uint256 caB) = (COINBASE.balance, CALLER.balance);
        vm.prank(CALLER);
        executor.execute(p);
        assertEq(COINBASE.balance - cbB, cbA, "same coinbase payment");
        assertEq(CALLER.balance - caB, caA, "same caller payment");
        assertGt(caA, 0);
    }

    function test_sweep_midCycle_reverts() public {
        address token = address(0xBEEF);
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V2, WETH, token, 3000, 0);
        legs[1] = Leg(V3, token, WETH, 3000, 60);
        vm.etch(token, address(new FeeToken()).code);
        vm.etch(Pools.v2Pair(_v(), WETH, token), address(new SweepingPair()).code);
        vm.etch(Pools.v3Pool(_v(), token, WETH, 3000), address(new SweepingPair()).code);

        vm.expectRevert(
            abi.encodeWithSelector(SweepingPair.Reentered.selector, abi.encodeWithSelector(UnexpectedCallback.selector))
        );
        executor.execute(Plan(1e15, 0, 0, 10000, address(0), TAG, legs));
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ForkTest, _v, WETH, MAX_COMPUTE_GAS} from "./Fork.t.sol";
import {V2Pusher, V3Pusher, V4Pusher} from "./Push.sol";
import {CycleExecutor} from "../src/CycleExecutor.sol";
import {CycleSolver} from "../src/CycleSolver.sol";
import {Pools} from "../src/lib/Pools.sol";
import {Leg, Plan, V2, V3, V4, NoProfit, TooManyCrossings, BadLeg, ProfitBelowPlan} from "../src/Types.sol";

/// Field order is alphabetical: `vm.parseJson` decodes JSON objects by sorted key.
struct JsonLeg {
    uint24 fee;
    int24 tickSpacing;
    address tokenIn;
    address tokenOut;
    uint8 version;
}

struct JsonCycle {
    JsonLeg[] legs;
    string name;
}

contract EndToEndTest is ForkTest {
    using StateLibrary for IPoolManager;

    address constant USDT_WETH_V3_1BP = 0xc7bBeC68d12a0d1830360F8Ec58fA599bA1b0e9b;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant TRAC = 0xaA7a9CA87d3694B5755f213B5D04094b8d0F0A6F;
    address constant BAT = 0x0D8775F648430679A709E98d2b0Cb6250d2887EF;

    CycleSolver solver;
    CycleExecutor executor;
    address BUILDER = makeAddr("bex-backrun e2e builder");
    /// The key the builder signs the execute with: its `msg.sender`, so the profit after the share (the
    /// plans here have recipient address(0)).
    address OPERATOR = makeAddr("bex-backrun e2e builder operator");
    bytes32 constant TAG = bytes32(uint256(0xaa)); // signer 0x..aa, left-padded

    function setUp() public override {
        super.setUp();
        solver = new CycleSolver(_v());
        executor = new CycleExecutor(_v());
        vm.coinbase(BUILDER);
        assertEq(BUILDER.balance, 0, "fresh builder");
        vm.deal(OPERATOR, 1 ether);
    }

    function cycleV3V3() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USDC, 500, 10);
        legs[1] = Leg(V3, USDC, WETH, 100, 1);
    }

    function cycleFive() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](5);
        legs[0] = Leg(V3, WETH, USDT, 100, 1);
        legs[1] = Leg(V4, USDT, USDC, 7, 1);
        legs[2] = Leg(V3, USDC, DAI, 100, 1);
        legs[3] = Leg(V3, DAI, USDC, 500, 10);
        legs[4] = Leg(V3, USDC, WETH, 100, 1);
    }

    function push(address pool, bool wethIsToken0, uint256 wethIn) internal {
        vm.deal(address(this), wethIn);
        new V3Pusher().push{value: wethIn}(pool, wethIsToken0);
    }

    /// The builder sends `selector || raw compute return`, empty prefixArgs.
    function builderCall(bytes memory ret) internal returns (bool ok, bytes memory out) {
        bytes memory data = bytes.concat(CycleExecutor.execute.selector, ret);
        vm.prank(OPERATOR);
        (ok, out) = address(executor).call(data);
    }

    function assertRoundTrip(Plan memory a, Plan memory b) internal pure {
        assertEq(a.amountIn, b.amountIn);
        assertEq(a.amountOut, b.amountOut);
        assertEq(a.minProfit, b.minProfit);
        assertEq(a.builderShareBps, b.builderShareBps);
        assertEq(a.recipient, b.recipient);
        assertEq(a.tag, b.tag);
        assertEq(a.legs.length, b.legs.length);
        for (uint256 i; i < a.legs.length; ++i) {
            assertEq(a.legs[i].version, b.legs[i].version);
            assertEq(a.legs[i].tokenIn, b.legs[i].tokenIn);
            assertEq(a.legs[i].tokenOut, b.legs[i].tokenOut);
            assertEq(a.legs[i].fee, b.legs[i].fee);
            assertEq(a.legs[i].tickSpacing, b.legs[i].tickSpacing);
        }
    }

    function test_builderCalldata_decodesAsExecute() public {
        push(USDC_WETH_V3_1BP, false, 300 ether);
        (bool ok, bytes memory ret) =
            address(solver).staticcall(abi.encodeCall(solver.solve, (cycleV3V3(), 0, 0, 10000, address(0), TAG)));
        assertTrue(ok);
        bytes memory builderCalldata = bytes.concat(CycleExecutor.execute.selector, ret);
        Plan memory p = abi.decode(ret, (Plan));
        assertEq(p.tag, TAG, "the solver echoes the tag");
        assertEq(builderCalldata, abi.encodeCall(executor.execute, (p)));
        (ok,) = builderCall(ret);
        assertTrue(ok, "executor accepts the raw calldata");
    }

    function test_builderCalldata_fiveLegs_decodes() public {
        Plan memory p = Plan(1 ether, 1.01 ether, 1, 7500, address(0xbeef), TAG, cycleFive());
        bytes memory ret = abi.encode(p);
        assertEq(bytes.concat(CycleExecutor.execute.selector, ret), abi.encodeCall(executor.execute, (p)));
        assertRoundTrip(p, abi.decode(ret, (Plan)));
        (bool ok, bytes memory err) = builderCall(ret); // unfunded market: may revert, only the encoding is under test
        if (!ok) {
            bytes4 sel = bytes4(err);
            assertTrue(
                sel == NoProfit.selector || sel == ProfitBelowPlan.selector || sel == BadLeg.selector, "known error"
            );
        }
    }

    function test_fullFlow_asBuilder() public {
        push(USDC_WETH_V3_1BP, false, 300 ether);
        (bool ok, bytes memory ret) =
            address(solver).staticcall(abi.encodeCall(solver.solve, (cycleV3V3(), 0, 0, 9000, address(0), TAG)));
        assertTrue(ok);
        Plan memory p = abi.decode(ret, (Plan));
        uint256 tip = (p.amountOut - p.amountIn) * 9000 / 10000;
        assertGt(tip, 0);
        (ok,) = builderCall(ret);
        assertTrue(ok);
        assertEq(BUILDER.balance, tip, "builder (coinbase) received exactly the share");
        assertEq(OPERATOR.balance - 1 ether, p.amountOut - p.amountIn - tip, "the sender received the rest");
    }

    // ---- mixed anchor: the cycle starts at native ETH (V4) and ends at WETH (V2/V3), or the reverse ----

    /// Mined cycles from cycles.toml. Solves on the pushed fork, executes as the builder, and checks the realised
    /// profit equals the plan, the coinbase gets its share in ETH, and the executor keeps no ETH or WETH.
    function _executeMined(Leg[] memory legs) internal {
        (bool ok, bytes memory ret) =
            address(solver).staticcall(abi.encodeCall(solver.solve, (legs, 0, 0, 9000, address(0), TAG)));
        assertTrue(ok, "solve finds the pushed profit");
        Plan memory p = abi.decode(ret, (Plan));
        uint256 profit = p.amountOut - p.amountIn;
        uint256 tip = profit * 9000 / 10000;
        assertGt(tip, 0);
        console2.log("amountIn, profit, tip (wei)", p.amountIn, profit, tip);
        uint256 op = OPERATOR.balance;
        uint256 held = _held();
        (ok,) = builderCall(ret);
        assertTrue(ok, "execute");
        assertEq(BUILDER.balance, tip, "coinbase got exactly its share, in ETH");
        assertEq(OPERATOR.balance - op, profit - tip, "realised profit == plan");
        assertEq(_held(), held, "executor keeps none of the profit");
    }

    function _held() internal view returns (uint256) {
        return address(executor).balance + IERC20(WETH).balanceOf(address(executor));
    }

    function _pushV4(Leg memory ethLeg, uint256 ethIn) internal {
        vm.deal(address(this), ethIn);
        new V4Pusher().push{value: ethIn}(Pools.v4Key(ethLeg), ethIn);
    }

    /// `eth_usdc__v4_100_v3_100`: ETH in on a V4 first leg (unlock flash), WETH out of the V3 leg.
    function test_mixedAnchor_v4EthIn_v3WethOut() public {
        push(USDC_WETH_V3_1BP, false, 100 ether);
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V4, address(0), USDC, 100, 1);
        legs[1] = Leg(V3, USDC, WETH, 100, 1);
        _executeMined(legs);
    }

    /// `eth_usdc__v3_100_v4_100`: WETH in on a V3 first leg (swap-callback flash), ETH out of the V4 leg.
    function test_mixedAnchor_v3WethIn_v4EthOut() public {
        _pushV4(Leg(V4, address(0), USDC, 100, 1), 50 ether);
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V4, USDC, address(0), 100, 1);
        _executeMined(legs);
    }

    /// `eth_trac__v4_3000_v2`: ETH in on V4, WETH out of a V2 pair.
    function test_mixedAnchor_v4EthIn_v2WethOut() public {
        vm.deal(address(this), 1 ether);
        new V2Pusher().push{value: 1 ether}(Pools.v2Pair(_v(), WETH, TRAC), WETH < TRAC);
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V4, address(0), TRAC, 3000, 60);
        legs[1] = Leg(V2, TRAC, WETH, 3000, 0);
        _executeMined(legs);
    }

    /// `eth_bat__v2_v4_3000`: WETH in on a V2 first leg (flash swap), ETH out of the V4 leg.
    function test_mixedAnchor_v2WethIn_v4EthOut() public {
        _pushV4(Leg(V4, address(0), BAT, 3000, 60), 1 ether);
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V2, WETH, BAT, 3000, 0);
        legs[1] = Leg(V4, BAT, address(0), 3000, 60);
        _executeMined(legs);
    }

    /// Every fixture token moves exactly: 1% of a leg's pool balance pool -> A -> B -> pool arrives in full
    /// each time. The last hop is how the executor pays V2/V3 pools (sell-side taxes hit only it).
    /// A transfer tax or block list fails here (add the token to `EXCLUDED_TOKENS` in cycles/build.py).
    function test_mainnetCycles_noTransferTax() public {
        JsonCycle[] memory cycles = abi.decode(vm.parseJson(vm.readFile("test/fixtures/cycles.json")), (JsonCycle[]));
        (address a, address b) = (makeAddr("tax probe a"), makeAddr("tax probe b"));
        for (uint256 c; c < cycles.length; ++c) {
            for (uint256 i; i < cycles[c].legs.length; ++i) {
                JsonLeg memory j = cycles[c].legs[i];
                if (j.tokenIn == address(0) || j.tokenIn == WETH) continue;
                address pool = j.version == V2
                    ? Pools.v2Pair(_v(), j.tokenIn, j.tokenOut)
                    : j.version == V3 ? Pools.v3Pool(_v(), j.tokenIn, j.tokenOut, j.fee) : POOL_MANAGER;
                uint256 amt = IERC20(j.tokenIn).balanceOf(pool) / 100;
                if (amt == 0) continue;
                uint256 snap = vm.snapshotState();
                assertEq(_moved(j.tokenIn, pool, a, amt), amt, string.concat("tax pool->wallet: ", cycles[c].name));
                assertEq(_moved(j.tokenIn, a, b, amt), amt, string.concat("tax wallet->wallet: ", cycles[c].name));
                assertEq(_moved(j.tokenIn, b, pool, amt), amt, string.concat("tax wallet->pool: ", cycles[c].name));
                vm.revertToState(snap);
            }
        }
    }

    function _moved(address token, address from, address to, uint256 amt) internal returns (uint256) {
        uint256 before = IERC20(token).balanceOf(to);
        vm.prank(from);
        (bool ok,) = token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amt)); // USDT returns nothing
        return ok ? IERC20(token).balanceOf(to) - before : 0;
    }

    /// Cycles the quiet-market test may skip because a pool did not exist yet at the fork block.
    uint256 constant MAX_NOT_YET_CREATED = 10;

    /// Every fixture cycle either has no profit or executes, and its solve stays under MAX_COMPUTE_GAS.
    function test_quietMarket_everyMinedCycle_eitherNoProfitOrExecutable() public {
        JsonCycle[] memory cycles = abi.decode(vm.parseJson(vm.readFile("test/fixtures/cycles.json")), (JsonCycle[]));
        assertGe(cycles.length, 20);
        uint256 skipped;
        for (uint256 c; c < cycles.length; ++c) {
            Leg[] memory legs = new Leg[](cycles[c].legs.length);
            for (uint256 i; i < legs.length; ++i) {
                JsonLeg memory j = cycles[c].legs[i];
                legs[i] = Leg(j.version, j.tokenIn, j.tokenOut, j.fee, j.tickSpacing);
            }
            if (!_poolsExist(legs)) {
                console2.log(string.concat("PoolNotYetCreated ", cycles[c].name)); // mined after the fork block
                ++skipped;
                continue;
            }
            uint256 g = gasleft();
            (bool ok, bytes memory ret) =
                address(solver).staticcall(abi.encodeCall(solver.solve, (legs, 0, 0, 10000, address(0), TAG)));
            g -= gasleft();
            console2.log(string.concat("COMPUTE_GAS ", cycles[c].name), g);
            assertLe(g, MAX_COMPUTE_GAS, string.concat("solve too expensive: ", cycles[c].name));
            if (ok) {
                uint256 before = BUILDER.balance;
                (bool landed,) = builderCall(ret);
                assertTrue(landed, string.concat("execute reverted: ", cycles[c].name));
                Plan memory p = abi.decode(ret, (Plan));
                console2.log(string.concat("PROFITABLE ", cycles[c].name), p.amountIn, p.amountOut - p.amountIn);
                assertEq(BUILDER.balance - before, p.amountOut - p.amountIn, "full share to builder");
            } else {
                bytes4 sel = bytes4(ret);
                console2.log(
                    string.concat(sel == NoProfit.selector ? "NoProfit " : "TooManyCrossings ", cycles[c].name)
                );
                assertTrue(
                    sel == NoProfit.selector || sel == TooManyCrossings.selector,
                    string.concat("unexpected revert: ", cycles[c].name)
                );
            }
        }
        // A few new pools are expected after a re-mine; many mean FORK_BLOCK is stale and the test checks little.
        assertLe(skipped, MAX_NOT_YET_CREATED, "too many cycles with pools created after the fork block");
    }

    function _poolsExist(Leg[] memory legs) internal view returns (bool) {
        for (uint256 i; i < legs.length; ++i) {
            Leg memory l = legs[i];
            if (l.version == V4) {
                (uint160 sqrtPriceX96,,,) = IPoolManager(POOL_MANAGER).getSlot0(Pools.v4Id(Pools.v4Key(l)));
                if (sqrtPriceX96 == 0) return false;
            } else {
                address pool = l.version == V2
                    ? Pools.v2Pair(_v(), l.tokenIn, l.tokenOut)
                    : Pools.v3Pool(_v(), l.tokenIn, l.tokenOut, l.fee);
                if (pool.code.length == 0) return false;
            }
        }
        return true;
    }
}

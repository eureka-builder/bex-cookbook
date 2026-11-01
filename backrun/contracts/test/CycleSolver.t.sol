// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {ForkTest, _v, WETH, MAX_COMPUTE_GAS} from "./Fork.t.sol";
import {V3Pusher, V4Pusher} from "./Push.sol";
import {CycleSolver} from "../src/CycleSolver.sol";
import {LegSim} from "../src/lib/LegSim.sol";
import {LegProbe} from "./LegProbe.sol";
import {ClosedForm} from "../src/lib/ClosedForm.sol";
import {Pools} from "../src/lib/Pools.sol";
import {RateFilter, Quote} from "../src/lib/RateFilter.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {Leg, Plan, V2, V3, V4, Venues, NoProfit, BadLeg} from "../src/Types.sol";
import {FeeToken, IV2FactoryCreate, IV2PairMint, IV3FactoryCreate, IV3PoolSeed} from "./CycleExecutor.t.sol";

function closedForm(Leg[] memory legs) view returns (uint256 x0, uint256 maxProfit) {
    uint256 n = legs.length;
    uint256[] memory rin = new uint256[](n);
    uint256[] memory rout = new uint256[](n);
    uint256[] memory g = new uint256[](n);
    for (uint256 i; i < n; i++) {
        (rin[i], rout[i], g[i]) = LegProbe.virtualReserves(_v(), legs[i]);
    }
    (x0, maxProfit) = ClosedForm.optimalInput(rin, rout, g);
}

/// Gas of a solve that must revert NoProfit.
function revertGas(CycleSolver solver, Leg[] memory legs, uint256 floor) view returns (uint256 used) {
    bytes memory call = abi.encodeCall(solver.solve, (legs, floor, 0, 10000, address(0), bytes32(0)));
    used = gasleft();
    (bool ok, bytes memory err) = address(solver).staticcall(call);
    used -= gasleft();
    require(!ok && bytes4(err) == NoProfit.selector, "expected NoProfit");
}

/// CycleSolver's execute gas model for V3 legs only: G0 + n * G_V3 + G_STEP * steps + G_CROSS * crossings.
function v3PlanGas(uint256 legs, uint256 steps, uint256 crossings) pure returns (uint256) {
    return 133_000 + 74_500 * legs + 7300 * steps + 20_000 * crossings;
}

/// The plan's floor at weiPerGas 1 (minProfitWei 0) is the model's gas at the plan's input, from the steps and
/// crossings of one exact swap of it.
function assertFloorIsModelAtPlan(Plan memory p) view {
    (, uint8 c, uint8 st, bool ok) = LegSim.tryCycleOut(_v(), p.legs, p.amountIn);
    require(ok, "plan feasible");
    require(p.minProfit == v3PlanGas(p.legs.length, st, c), "floor = the model at the plan's exact swap");
}

/// Exact profit of input x, or the lowest int256 where x is infeasible.
function scanProfit(Leg[] memory legs, uint256 x) view returns (int256) {
    (uint256 out,,, bool ok) = LegSim.tryCycleOut(_v(), legs, x);
    return ok ? int256(out) - int256(x) : type(int256).min;
}

/// Best exact profit over (0, hi]: `steps` evenly spaced inputs, then 40 ternary rounds around the best of them.
function scanBest(Leg[] memory legs, uint256 hi, uint256 steps) view returns (int256 best) {
    uint256 arg;
    best = type(int256).min;
    for (uint256 i = 1; i <= steps; ++i) {
        int256 p = scanProfit(legs, hi * i / steps);
        if (p > best) (best, arg) = (p, hi * i / steps);
    }
    uint256 w = hi / steps;
    (uint256 lo, uint256 up) = (arg > w ? arg - w : 1, arg + w);
    for (uint256 r; r < 40; ++r) {
        uint256 m1 = lo + (up - lo) / 3;
        uint256 m2 = up - (up - lo) / 3;
        int256 p1 = scanProfit(legs, m1);
        int256 p2 = scanProfit(legs, m2);
        if (p1 > best) best = p1;
        if (p2 > best) best = p2;
        if (p1 < p2) lo = m1;
        else up = m2;
    }
}

/// The plan for `legs` (floor 0), its exact output, the gas of the solve and the scan's best on the plan's legs.
function solveAndScan(CycleSolver solver, Leg[] memory legs, uint256 hi, uint256 steps)
    view
    returns (Plan memory p, uint256 exact, uint256 gas, int256 best)
{
    gas = gasleft();
    p = solver.solve(legs, 0, 0, 10000, address(0), bytes32(0));
    gas -= gasleft();
    (exact,) = LegProbe.cycleOut(_v(), p.legs, p.amountIn);
    best = scanBest(p.legs, hi, steps);
}

/// getReserves only: all V2Reader reads.
contract MockPair {
    uint112 r0;
    uint112 r1;

    function set(uint112 a, uint112 b) external {
        (r0, r1) = (a, b);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (r0, r1, 0);
    }
}

/// Adds full-range liquidity to an ETH / FeeToken V4 pool, paying ETH and minting the token.
contract V4FullRangeLp is IUnlockCallback {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    function add(PoolKey memory key, uint128 liquidity) external payable {
        PM.unlock(abi.encode(key, liquidity));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint128 liquidity) = abi.decode(data, (PoolKey, uint128));
        (BalanceDelta d,) =
            PM.modifyLiquidity(key, ModifyLiquidityParams(-887270, 887270, int256(uint256(liquidity)), 0), "");
        PM.settle{value: uint128(-d.amount0())}();
        PM.sync(key.currency1);
        FeeToken(address(uint160(key.currency1.toId()))).mint(address(PM), uint128(-d.amount1()));
        PM.settle();
        return "";
    }
}

/// No fork: V2 pairs mocked at their derived addresses.
contract CycleSolverRoundingTest is Test {
    /// Counterexample, directed reserves in base units: (25, 105) → (279, 86) → (104, 154).
    /// No crossing, and the closed form's x0 = 5 floors to outputs 17, 4, 5: profit 0. Inputs 3, 4, 6, 7
    /// and 8 earn 1 (3 → 11, 3, 4). NoProfit by design: the in-range path takes x0 without a rounding
    /// search. Profit that exists only through per-hop rounding is at most a unit of the thinnest hop;
    /// the validation measured the forgone gain at under 1 gwei on real cycles, far under any floor.
    function test_roundingOnlyProfit_isNoProfit_byDesign() public {
        Leg[] memory legs = new Leg[](3);
        legs[0] = Leg(V2, WETH, address(0xA), 3000, 0);
        legs[1] = Leg(V2, address(0xA), address(0xB), 3000, 0);
        legs[2] = Leg(V2, address(0xB), WETH, 3000, 0);
        uint112[2][3] memory r = [[uint112(25), 105], [uint112(279), 86], [uint112(104), 154]];
        for (uint256 i; i < 3; i++) {
            address pair = Pools.v2Pair(_v(), legs[i].tokenIn, legs[i].tokenOut);
            vm.etch(pair, address(new MockPair()).code);
            bool zfo = legs[i].tokenIn < legs[i].tokenOut;
            MockPair(pair).set(zfo ? r[i][0] : r[i][1], zfo ? r[i][1] : r[i][0]);
        }

        (uint256 x0,) = closedForm(legs);
        assertEq(x0, 5, "precondition: x0");
        (uint256 out,) = LegProbe.cycleOut(_v(), legs, x0);
        assertEq(out, x0, "precondition: x0 earns nothing");
        int256 best;
        for (uint256 x; x <= 20; x++) {
            (out,) = LegProbe.cycleOut(_v(), legs, x);
            if (int256(out) - int256(x) > best) best = int256(out) - int256(x);
        }
        assertEq(best, 1, "precondition: rounding alone earns 1 elsewhere");

        CycleSolver solver = new CycleSolver(_v());
        vm.expectRevert(NoProfit.selector);
        solver.solve(legs, 1, 0, 10000, address(0), bytes32(0));
        vm.expectRevert(NoProfit.selector);
        solver.solve(legs, 0, 0, 10000, address(0), bytes32(0));
    }
}

/// Settable V3 pool at a derived address: everything RateFilter, InRange, V3Reader and LegSim read.
contract SettableV3Pool {
    uint160 public sqrtP;
    int24 public tick_;
    uint128 public liquidity;
    uint24 public fee;
    int24 public tickSpacing;
    mapping(int16 => uint256) public tickBitmap;
    mapping(int24 => int128) net;

    function set(uint160 s, uint128 l, uint24 f, int24 ts) external {
        (sqrtP, liquidity, fee, tickSpacing) = (s, l, f, ts);
        tick_ = TickMath.getTickAtSqrtPrice(s);
    }

    function initTick(int24 t, int128 n) external {
        net[t] = n;
        int24 c = t / tickSpacing;
        if (t < 0 && t % tickSpacing != 0) c--;
        tickBitmap[int16(c >> 8)] |= uint256(1) << uint8(uint24(c % 256));
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtP, tick_, 0, 0, 0, 0, true);
    }

    function ticks(int24 t) external view returns (uint128, int128, uint256, uint256, int56, uint160, uint32, bool) {
        return (0, net[t], 0, 0, 0, 0, 0, true);
    }
}

/// No fork: two settable WETH/USDC V3 pools at their derived addresses.
contract CycleSolverMockTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // token0 (< WETH)
    // sqrt(1e18 / 4000e6) * 2^96: ~4000 USDC per ETH in raw units.
    uint160 constant S = 1252700000000000000000000000000000;
    uint160 constant S18 = S / 1e6;
    /// WETH wei per USDC unit at price S: (S / 2^96)^2, ~2.5e8.
    uint256 constant USDC_UNIT_WEI = (uint256(S) * S) >> 192;

    /// The execute gas model of an in-range plan on 2 V3 legs (CycleSolver: G0 + 2 * (G_V3 + G_STEP)).
    uint256 constant IN_RANGE_V3_V3_GAS = 296_600;
    /// test_gasAware_stopsBeforeCrossing: T's distance below x0 (wei of input) and the gas price.
    uint256 constant GAS_AWARE_LAG = 1e15;
    uint256 constant GAS_AWARE_WEI_PER_GAS = 1e6;
    /// The coarse worst-case fixture: T1's price tick (one T1 unit is about 3e11 wei).
    int24 constant COARSE_TICK = 264270;
    /// test_regionWalk_coarseIntermediate_crossesToTheBudget: crossings the coarse plan may have fewer than the
    /// plain one (measured: 21 and 21).
    uint256 constant COARSE_CROSSING_MARGIN = 1;

    Venues v;
    CycleSolver solver;
    SettableV3Pool a; // 5 bp, spacing 10
    SettableV3Pool b; // 1 bp, spacing 1

    function setUp() public {
        v = _v();
        solver = new CycleSolver(v);
        a = SettableV3Pool(Pools.v3Pool(v, WETH, USDC, 500));
        b = SettableV3Pool(Pools.v3Pool(v, WETH, USDC, 100));
        vm.etch(address(a), address(new SettableV3Pool()).code);
        vm.etch(address(b), address(new SettableV3Pool()).code);
    }

    /// WETH -> USDC on the 1 bp pool, USDC -> WETH on the 5 bp pool.
    function cycleBA() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V3, USDC, WETH, 500, 10);
    }

    /// The other orientation of the same two pools.
    function cycleAB() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USDC, 500, 10);
        legs[1] = Leg(V3, USDC, WETH, 100, 1);
    }

    /// Pool A quotes `bps` more WETH per USDC than pool B.
    function dislocate(uint256 bps) internal {
        // sqrt(1 + bps/1e4) ~ 1 + bps/2e4
        a.set(uint160(uint256(S) * (20000 + bps) / 20000), 5e16, 500, 10);
        b.set(S, 2e16, 100, 1);
    }

    /// dislocate, priced as if USDC had 18 decimals: sqrt price / 1e6 and liquidity x 1e6 keep every WETH amount,
    /// and one unit of the intermediate token is ~2.5e-4 wei instead of ~2.5e8. The exact profit then has no
    /// rounding steps that a smooth optimum would miss (those are StepEdge's, for tokens >= 2^32 wei a unit).
    function dislocateFine(uint256 bps) internal {
        a.set(uint160(uint256(S18) * (20000 + bps) / 20000), 5e22, 500, 10);
        b.set(S18, 2e22, 100, 1);
    }

    function gasOf(Leg[] memory legs, uint256 floor) internal view returns (uint256 used, bool ok, bytes memory ret) {
        return gasOf(legs, floor, 0);
    }

    function gasOf(Leg[] memory legs, uint256 floor, uint256 weiPerGas)
        internal
        view
        returns (uint256 used, bool ok, bytes memory ret)
    {
        bytes memory call = abi.encodeCall(CycleSolver.solve, (legs, floor, weiPerGas, 10000, address(0), bytes32(0)));
        used = gasleft();
        (ok, ret) = address(solver).staticcall(call);
        used -= gasleft();
    }

    function expectNoProfit(Leg[] memory legs, uint256 floor) internal view returns (uint256 used) {
        bool ok;
        bytes memory ret;
        (used, ok, ret) = gasOf(legs, floor);
        assertFalse(ok);
        assertEq(bytes4(ret), NoProfit.selector, "NoProfit, not a panic");
    }

    /// Profit of the best of `n` + 1 evenly spaced inputs on [0, hi] (exact, LegSim).
    function gridBest(Leg[] memory legs, uint256 hi, uint256 n) internal view returns (int256 best) {
        for (uint256 i = 1; i <= n; ++i) {
            uint256 x = hi * i / n;
            (uint256 out,,, bool ok) = LegSim.tryCycleOut(v, legs, x);
            if (ok && int256(out) - int256(x) > best) best = int256(out) - int256(x);
        }
    }

    function test_quiet_revertsNoProfit() public {
        dislocate(0);
        emit log_named_uint("quiet NoProfit gas", expectNoProfit(cycleBA(), 1e14));
        expectNoProfit(cycleAB(), 1e14);
    }

    function test_inRange_profitable_exactAndCheap() public {
        dislocate(40);
        Leg[] memory legs = cycleBA();
        (uint256 g, bool ok, bytes memory ret) = gasOf(legs, 1e14);
        assertTrue(ok, "solves");
        Plan memory p = abi.decode(ret, (Plan));
        (uint256 exact, uint8 crossings) = LegProbe.cycleOut(v, legs, p.amountIn);
        assertEq(crossings, 0, "in range");
        assertEq(p.amountOut, exact, "one-step output == swap loop output, wei for wei");
        (uint256 x0,) = closedForm(legs);
        assertEq(p.amountIn, x0, "the plan is the closed-form input");
        int256 profit = int256(p.amountOut - p.amountIn);
        int256 best = gridBest(legs, 2 * x0, 200);
        assertGe(profit, best - best / 1e6, "no grid point beats the plan beyond rounding");
        assertEq(p.minProfit, 1e14, "minProfit is the floor");
        emit log_named_uint("inrange gas", g);
        emit log_named_int("profit", profit);
    }

    function test_directionPreselect_reversedCycleSolves() public {
        dislocate(40);
        // Sent in the dead orientation: the solver flips the legs and returns the live plan.
        (uint256 g, bool ok, bytes memory ret) = gasOf(cycleAB(), 1e14);
        assertTrue(ok);
        Plan memory p = abi.decode(ret, (Plan));
        assertEq(p.legs[0].tokenIn, WETH);
        assertEq(p.legs[0].fee, 100, "flipped: first leg is now the 1 bp pool");
        assertEq(p.legs[1].fee, 500);
        Plan memory direct = solver.solve(cycleBA(), 1e14, 0, 10000, address(0), bytes32(0));
        assertEq(p.amountIn, direct.amountIn);
        assertEq(p.amountOut, direct.amountOut);
        emit log_named_uint("reversed solve gas", g);
    }

    /// In range below the floor: the exact one-step output decides, no LegSim pass.
    function test_inRange_belowFloor_noSimulation() public {
        dislocate(40);
        uint256 g = expectNoProfit(cycleBA(), 1e18);
        emit log_named_uint("belowfloor gas", g);
        assertLt(g, 70_000, "a LegSim pass alone would add ~30k");
    }

    /// The solver's exact profit is at least the best of a dense exact scan, minus a few wei.
    function _assertBeatsScan(Leg[] memory legs, uint256 hi, uint256 steps) internal returns (Plan memory p) {
        return _assertBeatsScanWithin(legs, hi, steps, 10 * legs.length);
    }

    /// _assertBeatsScan with tolerance `tol` wei.
    function _assertBeatsScanWithin(Leg[] memory legs, uint256 hi, uint256 steps, uint256 tol)
        internal
        returns (Plan memory p)
    {
        uint256 exact;
        uint256 g;
        int256 best;
        (p, exact, g, best) = solveAndScan(solver, legs, hi, steps);
        int256 profit = int256(p.amountOut) - int256(p.amountIn);
        emit log_named_uint("solve gas", g);
        emit log_named_int("profit", profit);
        emit log_named_int("scan best", best);
        assertEq(p.amountOut, exact, "amountOut exact");
        assertGe(profit, best - int256(tol), "beats the scan");
    }

    /// Leg 0 (WETH -> USDC on B) moves B's price up; a tick 3 above takes 3/4 of the liquidity away, so x0
    /// crosses into a thinner range and the closed form is no longer exact. fine: dislocateFine, else dislocate.
    function _thinnerPastTick(bool fine) internal returns (uint256 x0) {
        if (fine) dislocateFine(40);
        else dislocate(40);
        (, int24 t,,,,,) = b.slot0();
        b.initTick(t + 3, fine ? -15e21 : -15e15);
        (x0,) = closedForm(cycleBA());
        (, uint8 c0,,) = LegSim.tryCycleOut(v, cycleBA(), x0);
        assertGt(c0, 0, "precondition: x0 crosses");
    }

    function test_regionWalk_thinnerPastTick_beatsScan() public {
        uint256 x0 = _thinnerPastTick(true);
        _assertBeatsScan(cycleBA(), 2 * x0, 400);
    }

    /// The 6-decimal USDC fixture: the exact profit steps every USDC unit, so the plan may sit up to a few units
    /// below a step edge that the scan finds.
    function test_regionWalk_thinnerPastTick_usdc6_beatsScanWithinUnits() public {
        uint256 x0 = _thinnerPastTick(false);
        _assertBeatsScanWithin(cycleBA(), 2 * x0, 400, 4 * USDC_UNIT_WEI);
    }

    /// The same pools given in their dead orientation: the plan runs the reversed legs and beats a scan of them.
    function test_regionWalk_reversedOrientation() public {
        uint256 x0 = _thinnerPastTick(true);
        Plan memory p = _assertBeatsScan(cycleAB(), 2 * x0, 400);
        assertEq(keccak256(abi.encode(p.legs)), keccak256(abi.encode(cycleBA())), "plan runs the live legs");
    }

    /// B's start price is set so that the leg-0 input that reaches the initialized tick T is 500 wei below the
    /// closed-form x0: the in-region optimum sits on the boundary. Past T the range is deeper.
    function test_regionWalk_optimumAtBoundary() public {
        (Leg[] memory legs, uint256 x0) = _tickBelowX0(500);
        _assertBeatsScan(legs, 2 * x0, 200);
    }

    /// dislocateFine(40), and B's start price set so that the leg-0 input that reaches the initialized tick T is
    /// `lag` wei below the closed-form x0. Past T the range is deeper (liquidity 2e22, then 3e22).
    function _tickBelowX0(uint256 lag) internal returns (Leg[] memory legs, uint256 x0) {
        dislocateFine(40);
        uint128 l = 2e22;
        int24 t = TickMath.getTickAtSqrtPrice(S18) + 1;
        uint160 sqrtT = TickMath.getSqrtPriceAtTick(t);
        b.initTick(t, 1e22);
        legs = cycleBA();
        (x0,) = closedForm(legs);
        // Bisect B's start price: below `lo` reaching T takes more than x0 - lag, above `hi` less.
        uint256 lo = sqrtT - 4 * x0 * (1 << 96) / l;
        uint256 hi = sqrtT;
        uint256 need;
        while (hi - lo > 1) {
            uint256 m = (lo + hi) / 2;
            b.set(uint160(m), l, 100, 1);
            (x0,) = closedForm(legs);
            uint256 amt = SqrtPriceMath.getAmount1Delta(uint160(m), sqrtT, l, true);
            need = amt + FullMath.mulDivRoundingUp(amt, 100, 1e6 - 100);
            if (need + lag > x0) lo = m;
            else hi = m;
        }
        assertLt(need, x0, "precondition: x0 crosses T");
        assertGt(need + 2 * lag, x0, "precondition: by less than 2 lag");
    }

    /// x0 is past the crossing budget: the tick just above B's price is reached at ~x0/300 and leaves almost no
    /// liquidity in front of 40 more initialised ticks. The walk stops at the last region that fits.
    /// fine: dislocateFine, else dislocate.
    function _budgetWall(bool fine) internal returns (uint256 x0) {
        if (fine) dislocateFine(40);
        else dislocate(40);
        (x0,) = closedForm(cycleBA());
        // Leg 0 (WETH -> USDC on B, oneForZero) raises B's price towards tick T.
        uint128 l = fine ? 2e22 : 2e16;
        int24 t = TickMath.getTickAtSqrtPrice(fine ? S18 : S) + 1;
        uint160 sqrtT = TickMath.getSqrtPriceAtTick(t);
        b.set(uint160(sqrtT - (x0 / 300) * (1 << 96) / l), l, 100, 1);
        b.initTick(t, -int128(l - l / 100_000));
        for (int24 i = 1; i <= 40; ++i) {
            b.initTick(t + i, 0);
        }
        (x0,) = closedForm(cycleBA());
        (,,, bool ok) = LegSim.tryCycleOut(v, cycleBA(), x0 / 32);
        assertFalse(ok, "precondition: x0/32 is infeasible");
    }

    function test_regionWalk_budgetStopsAtLastFeasible() public {
        uint256 x0 = _budgetWall(true);
        Plan memory p = _assertBeatsScan(cycleBA(), x0 / 32, 400);
        assertGt(p.amountOut, p.amountIn, "profit > 0");
    }

    /// The 6-decimal USDC fixture, within a few USDC units of the scan (see the thinner-past-tick variant).
    function test_regionWalk_budgetStopsAtLastFeasible_usdc6_withinUnits() public {
        uint256 x0 = _budgetWall(false);
        Plan memory p = _assertBeatsScanWithin(cycleBA(), x0 / 32, 400, 4 * USDC_UNIT_WEI);
        assertGt(p.amountOut, p.amountIn, "profit > 0");
    }

    function test_rho_matchesClosedFormSign() public {
        dislocate(40);
        Quote[] memory q = RateFilter.quotes(v, cycleBA());
        uint256 r = RateFilter.rho(q);
        uint256 rr = RateFilter.rhoReversed(q);
        assertGt(r, 1 << 128);
        assertLt(rr, 1 << 128);
        // rho_fwd * rho_rev == (gamma_a * gamma_b)^2
        uint256 prod = r * rr >> 128; // Q128
        uint256 g2 = uint256(999500) * 999900 / 1e6; // gamma product, 1e6 units
        uint256 expect = (g2 * g2 << 128) / 1e12;
        assertApproxEqRel(prod, expect, 1e12); // 1e-6 relative
        emit log_named_uint("rho_fwd Q128 - 1 (bps)", (r - (1 << 128)) * 10000 >> 128);
    }

    /// An uninitialised pool (sqrtP 0) on one leg: NoProfit, not a division-by-zero panic.
    function test_zeroSqrtPrice_revertsNoProfit_noPanic() public {
        a.set(uint160(uint256(S) * 20040 / 20000), 5e16, 500, 10); // b left all zeros
        expectNoProfit(cycleBA(), 0);
        expectNoProfit(cycleAB(), 0);
    }

    function solveAt(Leg[] memory legs, uint256 floor, uint256 weiPerGas) internal view returns (Plan memory) {
        return solver.solve(legs, floor, weiPerGas, 10000, address(0), bytes32(0));
    }

    /// weiPerGas 0: the plan's floor is the caller's, at least 1, as before gas pricing.
    function test_weiPerGas_zero_matchesOldFloor() public {
        dislocate(40);
        assertEq(solveAt(cycleBA(), 0, 0).minProfit, 1, "floor 0 still demands profit");
        assertEq(solveAt(cycleBA(), 123, 0).minProfit, 123);
    }

    /// The floor is weiPerGas times the plan's modelled execute gas. At weiPerGas 1 the floor is the model
    /// itself: for an in-range plan on 2 V3 legs, G0 + 2 * (G_V3 + G_STEP).
    function test_weiPerGas_raisesFloor() public {
        dislocate(40);
        Plan memory p0 = solveAt(cycleBA(), 0, 0);
        uint256 model = solveAt(cycleBA(), 0, 1).minProfit;
        assertEq(model, IN_RANGE_V3_V3_GAS, "the model of an in-range 2-leg V3 plan");
        Plan memory p = solveAt(cycleBA(), 0, 1 gwei);
        assertEq(p.amountIn, p0.amountIn, "in range: the same plan");
        assertEq(p.minProfit, model * 1 gwei, "floor = weiPerGas * gas");
        assertGt(p.minProfit, solveAt(cycleBA(), 0, 0).minProfit);
        // a caller floor above the gas floor wins
        assertEq(solveAt(cycleBA(), p.minProfit + 1, 1 gwei).minProfit, p.minProfit + 1);
    }

    /// solve at weiPerGas: NoProfit, not a panic.
    function expectGasNoProfit(Leg[] memory legs, uint256 weiPerGas) internal view {
        (, bool ok, bytes memory ret) = gasOf(legs, 0, weiPerGas);
        assertFalse(ok, "gas outweighs the profit");
        assertEq(bytes4(ret), NoProfit.selector, "NoProfit, not a panic");
    }

    /// In range: the plan clears a floor of weiPerGas * gas up to profit / gas, and is NoProfit one wei per
    /// gas above.
    function test_gasFloor_inRange_rejectsPlanWhoseGasOutweighsProfit() public {
        dislocate(40);
        Plan memory p = solveAt(cycleBA(), 0, 0);
        uint256 w = (p.amountOut - p.amountIn) / IN_RANGE_V3_V3_GAS;
        assertGt(w, 0, "precondition: the plan pays for some gas");
        assertEq(solveAt(cycleBA(), 0, w).minProfit, w * IN_RANGE_V3_V3_GAS, "clears at profit / gas");
        expectGasNoProfit(cycleBA(), w + 1);
    }

    /// The walk: no plan of these 2 V3 legs models less gas than the in-range one, and none earns more
    /// than the weiPerGas-0 plan (it beats a dense scan), so above profit / IN_RANGE_V3_V3_GAS every
    /// candidate is below its floor.
    function test_gasFloor_walk_rejectsPlanWhoseGasOutweighsProfit() public {
        (Leg[] memory legs,) = _tickBelowX0(GAS_AWARE_LAG);
        Plan memory p = solveAt(legs, 0, 0);
        (, uint8 c,,) = LegSim.tryCycleOut(v, legs, p.amountIn);
        assertGe(c, 1, "precondition: the walk's plan crosses");
        expectGasNoProfit(legs, (p.amountOut - p.amountIn) / IN_RANGE_V3_V3_GAS + 2);
    }

    /// A weiPerGas past 2^128 is NoProfit, not an overflow panic.
    function test_weiPerGas_huge_noProfitNoPanic() public {
        dislocate(40);
        bool ok;
        bytes memory ret;
        (, ok, ret) = gasOf(cycleBA(), 0, 2 ** 200);
        assertFalse(ok);
        assertEq(bytes4(ret), NoProfit.selector, "2^200: NoProfit, not a panic");
        (, ok, ret) = gasOf(cycleBA(), 0, type(uint256).max);
        assertFalse(ok);
        assertEq(bytes4(ret), NoProfit.selector, "max: NoProfit, not a panic");
    }

    /// A crossing that adds less profit than its gas costs is not taken. The tick T sits GAS_AWARE_LAG wei of
    /// input below x0 and the range past it is deeper: at weiPerGas 0 the plan crosses T, at GAS_AWARE_WEI_PER_GAS
    /// it stops before T, and its net (profit - weiPerGas * gas) beats the crossing plan's net at that price.
    function test_gasAware_stopsBeforeCrossing() public {
        (Leg[] memory legs,) = _tickBelowX0(GAS_AWARE_LAG);
        Plan memory p0 = solveAt(legs, 0, 0);
        (, uint8 c0,,) = LegSim.tryCycleOut(v, legs, p0.amountIn);
        assertGe(c0, 1, "weiPerGas 0: the plan crosses T");
        // At weiPerGas 1 the crossing still pays: the same plan, its floor its modelled gas.
        Plan memory p1 = solveAt(legs, 0, 1);
        assertEq(p1.amountIn, p0.amountIn, "weiPerGas 1: the same plan");
        uint256 gas0 = p1.minProfit;

        uint256 w = GAS_AWARE_WEI_PER_GAS;
        Plan memory p = solveAt(legs, 0, w);
        (uint256 exact, uint8 c,,) = LegSim.tryCycleOut(v, legs, p.amountIn);
        assertEq(p.amountOut, exact, "amountOut exact");
        assertLt(c, c0, "fewer crossings");
        int256 net = int256(p.amountOut - p.amountIn) - int256(p.minProfit); // minProfit = w * its gas
        int256 net0 = int256(p0.amountOut - p0.amountIn) - int256(w * gas0);
        emit log_named_int("net, gas-aware plan", net);
        emit log_named_int("net, weiPerGas-0 plan", net0);
        assertGt(net, net0, "net beats the crossing plan");
    }

    /// A minProfitWei that only the crossing plan clears: the walk ranks its points by the margin over their
    /// own floor, so the gas-aware stop (best net, profit below minProfitWei) loses to the crossing plan,
    /// not NoProfit.
    function test_gasAware_minProfitAboveStop_takesCrossing() public {
        (Leg[] memory legs,) = _tickBelowX0(GAS_AWARE_LAG);
        Plan memory p0 = solveAt(legs, 0, 0);
        uint256 profit0 = p0.amountOut - p0.amountIn;
        uint256 w = GAS_AWARE_WEI_PER_GAS;
        Plan memory p = solveAt(legs, 0, w);
        assertLt(p.amountOut - p.amountIn, profit0, "precondition: the stop earns less than the crossing plan");
        assertLe(solveAt(legs, 0, 1).minProfit * w, profit0, "precondition: the crossing plan clears its gas floor");

        Plan memory pm = solveAt(legs, profit0, w);
        assertEq(pm.amountIn, p0.amountIn, "the crossing plan");
        assertEq(pm.minProfit, profit0, "its floor is minProfitWei");
    }

    /// A pool drained to the end of its price range (no liquidity, price at the swap limit) after a leg that
    /// pays 2^40 per unit: the rate product passes 2^256. RateFilter saturates to its cap instead of reverting
    /// with no data (the mined eth_send cycle at FORK_BLOCK).
    function test_rho_extremePrice_saturates() public pure {
        Quote[] memory q = new Quote[](2);
        (q[0].v2, q[0].fee, q[0].rin, q[0].rout) = (true, 3000, 1, 2 ** 40);
        (q[1].zfo, q[1].fee, q[1].sqrtPriceX96) = (true, 10000, TickMath.MAX_SQRT_PRICE - 1);
        assertEq(RateFilter.rho(q), RateFilter.RHO_CAP, "capped, not a revert");
        assertEq(RateFilter.direction(q), 1);
    }

    /// No liquidity at all on one leg (no initialized tick behind its price): NoProfit in both orientations.
    function test_zeroLiquidity_revertsNoProfit() public {
        dislocate(40);
        b.set(S, 0, 100, 1);
        expectNoProfit(cycleBA(), 0);
        expectNoProfit(cycleAB(), 0);
    }

    /// The worst-case cycle: WETH -> T1 -> T2 -> T3 -> T4 -> WETH on 5 settable V3 pools (1 bp, spacing 1,
    /// liquidity 1e24, price 1). The last leg pays 16 times the price, so x0 is far past the budget. Every
    /// walking leg has 40 initialized ticks (net 0) in its swap direction, `stride` ticks apart: one word holds
    /// 256 ticks, so a stride of 512 leaves an empty bitmap word between two of them. coarse: T1 is worth
    /// 1.0001^COARSE_TICK (about 3e11) wei a unit, like an 8-decimal BTC. Legs 0 and 1 then
    /// stay in range (no initialized tick, liquidity 1e20) and legs 2 to 4 walk.
    function _worstCase(int24 stride, bool coarse) internal returns (Leg[] memory legs) {
        address[6] memory t = [WETH, address(0x1111), address(0x2222), address(0x3333), address(0x4444), WETH];
        legs = new Leg[](5);
        for (uint256 i; i < 5; ++i) {
            legs[i] = Leg(V3, t[i], t[i + 1], 100, 1);
            SettableV3Pool p = SettableV3Pool(Pools.v3Pool(v, t[i], t[i + 1], 100));
            vm.etch(address(p), address(new SettableV3Pool()).code);
            bool zfo = t[i] < t[i + 1];
            bool fixedLeg = coarse && i < 2;
            // out per in is 1.0001^tick (zfo) or 1.0001^-tick: 27726 ticks is a factor of 16
            int24 t0 = fixedLeg ? COARSE_TICK : i < 4 ? int24(0) : zfo ? int24(27726) : -27726;
            p.set(TickMath.getSqrtPriceAtTick(t0), fixedLeg ? 1e20 : 1e24, 100, 1);
            for (int24 k = 1; k <= 40 && !fixedLeg; ++k) {
                p.initTick(zfo ? t0 - k * stride : t0 + k * stride, 0);
            }
            vm.cool(address(p));
        }
        vm.cool(address(solver));
    }

    /// Five pools with no active liquidity, each with its liquidity ~118 empty bitmap words ahead (just under
    /// MAX_STEPS), and a last leg that pays 16x. The gap pass stops at the leg that passes CYCLE_BUDGET, not
    /// after all five: NoProfit, under 2 * (CYCLE_BUDGET + MAX_STEPS) cold bitmap reads' worth of gas.
    function test_gapPass_stopsAtTheBudget() public {
        address[6] memory t = [WETH, address(0x1111), address(0x2222), address(0x3333), address(0x4444), WETH];
        Leg[] memory legs = new Leg[](5);
        for (uint256 i; i < 5; ++i) {
            legs[i] = Leg(V3, t[i], t[i + 1], 100, 1);
            SettableV3Pool p = SettableV3Pool(Pools.v3Pool(v, t[i], t[i + 1], 100));
            vm.etch(address(p), address(new SettableV3Pool()).code);
            bool zfo = t[i] < t[i + 1];
            int24 t0 = i < 4 ? int24(0) : zfo ? int24(27726) : -27726;
            p.set(TickMath.getSqrtPriceAtTick(t0), 0, 100, 1);
            p.initTick(zfo ? t0 - 118 * 256 : t0 + 118 * 256, zfo ? -1e24 : int128(1e24));
            vm.cool(address(p));
        }
        vm.cool(address(solver));
        (uint256 g, bool ok, bytes memory ret) = gasOf(legs, 0);
        emit log_named_uint("gas", g);
        assertFalse(ok);
        assertEq(bytes4(ret), NoProfit.selector);
        assertLt(g, 2 * (uint256(LegSim.CYCLE_BUDGET) + LegSim.MAX_STEPS) * 4000, "stops at the budget");
    }

    /// By construction: a 5-leg cycle where every CL leg walks through initialized ticks separated by empty
    /// bitmap words, up to MAX_REGIONS / CYCLE_BUDGET, solves under MAX_COMPUTE_GAS (6,000,000), all cold.
    /// Strides: 3 (crossings only, one word), 512 (one empty word between ticks), 1536 (five). Each also with
    /// a coarse intermediate in front of the walking legs.
    /// Plain runs: the plan is the last feasible candidate, within 1e-6 of the largest input whose exact swap
    /// fits the budget, so the walk's best candidate passed its exact check with no fallback to an earlier
    /// region (coarse runs: test_regionWalk_coarseIntermediate_crossesToTheBudget).
    /// At weiPerGas 1 the floor is the gas model at the plan's exact swap.
    function test_worstCaseWalk_underComputeCap() public {
        int24[3] memory strides = [int24(3), 512, 1536];
        for (uint256 i; i < 2 * strides.length; ++i) {
            uint256 snap = vm.snapshotState();
            bool coarse = i >= strides.length;
            Leg[] memory legs = _worstCase(strides[i % strides.length], coarse);
            (uint256 g, bool ok, bytes memory ret) = gasOf(legs, 0);
            assertTrue(ok, "solves");
            Plan memory p = abi.decode(ret, (Plan));
            (, uint8 c, uint8 s, bool feasible) = LegSim.tryCycleOut(v, p.legs, p.amountIn);
            assertTrue(feasible);
            uint256 units = uint256(LegSim.W_CROSS) * c + s;
            emit log_named_int(coarse ? "stride, coarse" : "stride", strides[i % strides.length]);
            emit log_named_uint("  crossings", c);
            emit log_named_uint("  budget units", units);
            emit log_named_uint("  solve gas", g);
            emit log_named_uint("  amountIn", p.amountIn);
            emit log_named_uint("  profit", p.amountOut - p.amountIn);
            assertGe(units + 2 * LegSim.W_CROSS, LegSim.CYCLE_BUDGET, "precondition: the walk runs to the budget");
            assertLt(g, MAX_COMPUTE_GAS, "solve under the compute cap");
            if (!coarse) assertGe(p.amountIn + p.amountIn / 1e6, _lastFeasible(p.legs, p.amountIn), "no fallback");
            assertFloorIsModelAtPlan(solveAt(legs, 0, 1));
            vm.revertToState(snap);
        }
    }

    /// The largest input (within 1e-7) whose exact swap fits the budget, above a feasible lo.
    function _lastFeasible(Leg[] memory legs, uint256 lo) internal view returns (uint256) {
        uint256 hi = 2 * lo;
        (,,, bool ok) = LegSim.tryCycleOut(v, legs, hi);
        while (ok) {
            (lo, hi) = (hi, 2 * hi);
            (,,, ok) = LegSim.tryCycleOut(v, legs, hi);
        }
        while (hi - lo > lo / 1e7) {
            uint256 m = (lo + hi) / 2;
            (,,, ok) = LegSim.tryCycleOut(v, legs, m);
            if (ok) lo = m;
            else hi = m;
        }
        return lo;
    }

    /// The coarse fixture at stride 3: leg 0's output moves only every ~3e11 wei of input, so a small cross step
    /// reaches no boundary. The walk still crosses to the budget: about as many crossings as the plain fixture,
    /// and within one region of the exact frontier (at a coarse budget wall the best candidate can fail its
    /// exact check and fall back one region).
    function test_regionWalk_coarseIntermediate_crossesToTheBudget() public {
        uint256 snap = vm.snapshotState();
        Plan memory plain = solveAt(_worstCase(3, false), 0, 0);
        (, uint8 cPlain,,) = LegSim.tryCycleOut(v, plain.legs, plain.amountIn);
        vm.revertToState(snap);
        Plan memory p = solveAt(_worstCase(3, true), 0, 0);
        (, uint8 c,,) = LegSim.tryCycleOut(v, p.legs, p.amountIn);
        (, uint8 cEdge,,) = LegSim.tryCycleOut(v, p.legs, _lastFeasible(p.legs, p.amountIn));
        emit log_named_uint("crossings, plain", cPlain);
        emit log_named_uint("crossings, coarse", c);
        emit log_named_uint("crossings at the frontier", cEdge);
        assertGe(c + COARSE_CROSSING_MARGIN, cPlain, "crosses about as far as the plain fixture");
        assertGe(c + 1, cEdge, "within one region of the frontier");
    }

    /// A walk plan: at weiPerGas 1 the floor is the gas model at the plan's exact swap (the walk's own probe).
    function test_planGas_walkPlan_isModelAtExactSwap() public {
        (Leg[] memory legs,) = _tickBelowX0(GAS_AWARE_LAG);
        Plan memory p = solveAt(legs, 0, 1);
        (, uint8 c,,) = LegSim.tryCycleOut(v, p.legs, p.amountIn);
        assertGe(c, 1, "precondition: a walk plan");
        assertFloorIsModelAtPlan(p);
    }
}

contract CycleSolverTest is ForkTest {
    // At FORK_BLOCK: the backrun of a 10 WETH push crosses no tick (closed form is exact);
    // of a 100 WETH push, 13 ticks (the walk runs).
    uint256 constant PUSH_SMALL = 10 ether;
    uint256 constant PUSH_LARGE = 100 ether;
    uint256 constant PUSH_HUGE = 1000 ether; // the closed-form x0 crosses more than MAX_TICK_CROSSINGS
    uint256 constant PUSH_V4 = 30 ether;
    uint256 constant PUSH_ONE_CROSSING = 16 ether; // x0 crosses one tick (14-18 WETH do)
    uint16 constant V4_PROTOCOL_FEE_1TO0 = 50; // 0.5 bp
    uint256 constant RANK_WEI_PER_GAS = 200 gwei; // test_solveMany_ranksByNetMargin
    uint256 constant GAS_ONLY_WEI_PER_GAS = 2 gwei; // test_solveMany_skipsCycleBelowGasFloor
    address constant USDT_WETH_V3_1BP = 0xc7bBeC68d12a0d1830360F8Ec58fA599bA1b0e9b;

    CycleSolver solver;

    function setUp() public override {
        super.setUp();
        solver = new CycleSolver(_v());
    }

    function stableTriangleV3() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](3);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V3, USDC, USDT, 100, 1);
        legs[2] = Leg(V3, USDT, WETH, 100, 1);
    }

    /// WETH is sold into the 1bp pool by `_pushV3`, so it is cheap there: sell on 5bp, buy back on 1bp.
    function feeTierCycle() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USDC, 500, 10);
        legs[1] = Leg(V3, USDC, WETH, 100, 1);
    }

    function _pushV3(uint256 wethIn) internal {
        vm.deal(address(this), wethIn);
        new V3Pusher().push{value: wethIn}(USDC_WETH_V3_1BP, false); // WETH is token1: oneForZero
    }

    function _solvePushed(uint256 wethIn) internal returns (Plan memory) {
        _pushV3(wethIn);
        return solver.solve(feeTierCycle(), 0, 0, 10000, address(0), bytes32(0));
    }

    /// Exact against LegSim and no worse than 2% either side.
    function _assertExactAndOptimal(Plan memory p) internal view returns (uint8 crossings) {
        uint256 out;
        (out, crossings) = LegProbe.cycleOut(_v(), p.legs, p.amountIn);
        assertEq(out, p.amountOut, "amountOut exact");
        assertGt(p.amountOut, p.amountIn);
        uint256 xLo = p.amountIn * 98 / 100;
        uint256 xHi = p.amountIn * 102 / 100;
        (uint256 lo,) = LegProbe.cycleOut(_v(), p.legs, xLo);
        (uint256 hi,) = LegProbe.cycleOut(_v(), p.legs, xHi);
        assertGe(p.amountOut - p.amountIn, lo - xLo, "beats -2%");
        assertGe(p.amountOut - p.amountIn, hi - xHi, "beats +2%");
        assertGe(p.minProfit, 1);
        assertGe(p.amountOut - p.amountIn, p.minProfit, "profit clears the plan floor");
    }

    function test_quietMarket_revertsNoProfit() public {
        vm.expectRevert(NoProfit.selector);
        solver.solve(stableTriangleV3(), 0.0002 ether, 0, 10000, address(0), bytes32(0));
    }

    function test_pushedPool_findsOptimum() public {
        Plan memory p = _solvePushed(PUSH_SMALL);
        assertEq(_assertExactAndOptimal(p), 0, "closed-form case crosses no tick");
        assertEq(p.builderShareBps, 10000);
        assertEq(keccak256(abi.encode(p.legs)), keccak256(abi.encode(feeTierCycle())));
    }

    function test_pushedPool_amountOutIsExact() public {
        Plan memory p = _solvePushed(PUSH_SMALL);
        (uint256 out,) = LegProbe.cycleOut(_v(), p.legs, p.amountIn);
        assertEq(out, p.amountOut);
    }

    /// Marks the solver and every pool the legs read cold again, so a gas reading after a push or a
    /// precondition probe prices first access, as in the builder's fresh call.
    function _cool(Leg[] memory legs) internal {
        vm.cool(address(solver));
        for (uint256 i; i < legs.length; ++i) {
            Leg memory l = legs[i];
            if (l.version == V2) vm.cool(Pools.v2Pair(_v(), l.tokenIn, l.tokenOut));
            else if (l.version == V3) vm.cool(Pools.v3Pool(_v(), l.tokenIn, l.tokenOut, l.fee));
            else vm.cool(POOL_MANAGER);
        }
    }

    /// Gas of a solve that must return a plan, cold.
    function _planGas(Leg[] memory legs) internal returns (Plan memory p, uint256 used) {
        _cool(legs);
        bytes memory call = abi.encodeCall(solver.solve, (legs, 0, 0, 10000, address(0), bytes32(0)));
        used = gasleft();
        (bool ok, bytes memory ret) = address(solver).staticcall(call);
        used -= gasleft();
        assertTrue(ok, "solves");
        p = abi.decode(ret, (Plan));
        emit log_named_uint("gas", used);
    }

    /// No crossing: the plan is the closed-form input, its output one exact swap step per leg.
    function test_gas_inRangePlan_under150k() public {
        _pushV3(PUSH_SMALL);
        Leg[] memory legs = feeTierCycle();
        (uint256 x0,) = closedForm(legs);
        (Plan memory p, uint256 used) = _planGas(legs);
        assertEq(p.amountIn, x0, "plan is the closed-form input");
        assertEq(_assertExactAndOptimal(p), 0);
        assertLt(used, 150_000);
    }

    /// x0 crosses a tick or two: the region walk runs.
    function test_gas_oneCrossingPlan_under400k() public {
        _pushV3(PUSH_ONE_CROSSING);
        Leg[] memory legs = feeTierCycle();
        (uint256 x0,) = closedForm(legs);
        (, uint8 c0,,) = LegSim.tryCycleOut(_v(), legs, x0);
        assertGe(c0, 1, "precondition: x0 crosses");
        assertLe(c0, 2, "precondition: a tick or two");
        (Plan memory p, uint256 used) = _planGas(legs);
        _assertExactAndOptimal(p);
        assertLt(used, 400_000);
    }

    /// The request names the dead direction: the plan comes back on the reversed legs and equals
    /// the plan of solving the reversed cycle directly.
    function test_deadOrientation_returnsReversedPlan() public {
        _pushV3(PUSH_SMALL); // WETH cheap on the 1bp pool: live = sell on 5bp, buy on 1bp
        Leg[] memory live = feeTierCycle();
        Leg[] memory dead = RateFilter.reverse(live);
        Plan memory direct = solver.solve(live, 0, 0, 10000, address(0), bytes32(0));
        Plan memory flipped = solver.solve(dead, 0, 0, 10000, address(0), bytes32(0));
        assertEq(flipped.amountIn, direct.amountIn);
        assertEq(flipped.amountOut, direct.amountOut);
        assertEq(flipped.legs[0].tokenIn, live[0].tokenIn);
        assertEq(flipped.legs[0].fee, live[0].fee);
        assertEq(keccak256(abi.encode(flipped.legs)), keccak256(abi.encode(live)));
        _assertExactAndOptimal(flipped);
    }

    /// V4 leg flipped, with a protocol fee on the live direction only (slot0.protocolFee packs one
    /// per direction): the reversed quote must take the other direction's fee or the in-range
    /// output is off. Realised output equals the plan wei for wei.
    function test_deadOrientation_v4Leg_exact() public {
        PoolKey memory key = _pushV4();
        // ETH is currency0: the live V4 leg (USDC -> ETH) is oneForZero, the dead one zeroForOne.
        vm.prank(IPoolManager(POOL_MANAGER).protocolFeeController());
        IPoolManager(POOL_MANAGER).setProtocolFee(key, uint24(V4_PROTOCOL_FEE_1TO0) << 12);
        Leg[] memory live = v4Cycle();
        Plan memory p = solver.solve(RateFilter.reverse(live), 0, 0, 10000, address(0), bytes32(0));
        assertEq(keccak256(abi.encode(p.legs)), keccak256(abi.encode(live)), "plan runs the live legs");
        _assertExactAndOptimal(p);
        Plan memory direct = solver.solve(live, 0, 0, 10000, address(0), bytes32(0));
        assertEq(p.amountIn, direct.amountIn);
        assertEq(p.amountOut, direct.amountOut);
    }

    function test_planMinProfit_isCallerFloor() public {
        _pushV3(PUSH_SMALL);
        assertEq(solver.solve(feeTierCycle(), 123, 0, 10000, address(0), bytes32(0)).minProfit, 123);
        assertEq(
            solver.solve(feeTierCycle(), 0, 0, 10000, address(0), bytes32(0)).minProfit,
            1,
            "floor 0 still demands profit"
        );
    }

    function test_profitBelowFloor_revertsNoProfit() public {
        uint256 snap = vm.snapshotState();
        Plan memory p = _solvePushed(PUSH_SMALL);
        vm.revertToState(snap);
        _pushV3(PUSH_SMALL);
        vm.expectRevert(NoProfit.selector);
        solver.solve(feeTierCycle(), p.amountOut - p.amountIn + 1, 0, 10000, address(0), bytes32(0));
        assertEq(
            solver.solve(feeTierCycle(), p.amountOut - p.amountIn, 0, 10000, address(0), bytes32(0)).amountIn,
            p.amountIn
        );
    }

    function _pair(Leg[] memory a, Leg[] memory b) internal pure returns (Leg[][] memory cs) {
        cs = new Leg[][](2);
        (cs[0], cs[1]) = (a, b);
    }

    function _floors(uint256 a, uint256 b) internal pure returns (uint256[] memory f) {
        f = new uint256[](2);
        (f[0], f[1]) = (a, b);
    }

    /// A quiet cycle and a pushed one: the group's plan is the pushed cycle's, as `solve` gives it alone.
    function test_solveMany_picksBestMargin() public {
        _pushV3(PUSH_SMALL);
        Plan memory many = solver.solveMany(
            _pair(stableTriangleV3(), feeTierCycle()), _floors(0.0002 ether, 0), 0, 10000, address(0), bytes32(0)
        );
        Plan memory one = solver.solve(feeTierCycle(), 0, 0, 10000, address(0), bytes32(0));
        assertEq(many.amountIn, one.amountIn);
        assertEq(many.amountOut, one.amountOut);
        assertEq(many.legs[0].fee, one.legs[0].fee);
        assertEq(many.minProfit, one.minProfit);
    }

    /// Ranked by margin over each cycle's own floor, not by gross profit: the same cycle twice, a
    /// higher floor on the first hands the second the plan.
    function test_solveMany_ranksByMarginOverFloor() public {
        _pushV3(PUSH_SMALL);
        Plan memory one = solver.solve(feeTierCycle(), 0, 0, 10000, address(0), bytes32(0));
        uint256 profit = one.amountOut - one.amountIn;
        Plan memory p = solver.solveMany(
            _pair(feeTierCycle(), feeTierCycle()), _floors(profit / 2, profit / 4), 0, 10000, address(0), bytes32(0)
        );
        assertEq(p.minProfit, profit / 4);
    }

    /// Ranked by margin over each plan's own floor, gas included. After a 20 WETH push into USDT/WETH 1bp, the
    /// 3-leg cycle (WETH -> USDC -> USDT on V4 -> WETH) grosses more than the 2-leg one (WETH -> USDT on 5bp ->
    /// WETH) and models more gas. At weiPerGas 0 it wins; at RANK_WEI_PER_GAS the 2-leg cycle nets more and wins.
    function test_solveMany_ranksByNetMargin() public {
        vm.deal(address(this), 20 ether);
        new V3Pusher().push{value: 20 ether}(USDT_WETH_V3_1BP, true); // WETH is token0
        Leg[][] memory g = new Leg[][](2);
        g[0] = new Leg[](3);
        g[0][0] = Leg(V3, WETH, USDC, 100, 1);
        g[0][1] = Leg(V4, USDC, USDT, 7, 1);
        g[0][2] = Leg(V3, USDT, WETH, 100, 1);
        g[1] = new Leg[](2);
        g[1][0] = Leg(V3, WETH, USDT, 500, 10);
        g[1][1] = Leg(V3, USDT, WETH, 100, 1);
        Plan memory three = solver.solve(g[0], 0, RANK_WEI_PER_GAS, 10000, address(0), bytes32(0));
        Plan memory two = solver.solve(g[1], 0, RANK_WEI_PER_GAS, 10000, address(0), bytes32(0));
        assertGt(three.amountOut - three.amountIn, two.amountOut - two.amountIn, "precondition: 3 legs gross more");
        assertGt(three.minProfit, two.minProfit, "precondition: and model more gas");
        assertLt(
            three.amountOut - three.amountIn - three.minProfit,
            two.amountOut - two.amountIn - two.minProfit,
            "precondition: 2 legs net more"
        );
        Plan memory many = solver.solveMany(g, _floors(0, 0), 0, 10000, address(0), bytes32(0));
        assertEq(many.legs.length, 3, "weiPerGas 0: the larger gross wins");
        many = solver.solveMany(g, _floors(0, 0), RANK_WEI_PER_GAS, 10000, address(0), bytes32(0));
        assertEq(many.legs.length, 2, "the larger net wins");
        assertEq(many.amountIn, two.amountIn);
        assertEq(many.minProfit, two.minProfit);
    }

    /// A cycle through a V3 pool that does not exist (fee 1234: no code at the derived address) would
    /// revert its solve; the group still returns the profitable cycle's plan.
    function test_solveMany_skipsRevertingCycle() public {
        _pushV3(PUSH_SMALL);
        Leg[] memory dead = feeTierCycle();
        dead[0].fee = 1234;
        Plan memory one = solver.solve(feeTierCycle(), 0, 0, 10000, address(0), bytes32(0));
        Plan memory many =
            solver.solveMany(_pair(dead, feeTierCycle()), _floors(0, 0), 0, 10000, address(0), bytes32(0));
        assertEq(many.amountIn, one.amountIn);
        assertEq(many.amountOut, one.amountOut);
    }

    /// One cycle of the group fails only on gas: at GAS_ONLY_WEI_PER_GAS the triangle's floor passes its
    /// profit (it pays at weiPerGas 0), the 2-leg cycle clears. The group returns the 2-leg plan.
    function test_solveMany_skipsCycleBelowGasFloor() public {
        _pushV3(PUSH_SMALL);
        Leg[][] memory g = _pair(stableTriangleV3(), feeTierCycle());
        solver.solve(g[0], 0, 0, 10000, address(0), bytes32(0)); // precondition: the triangle pays without gas
        vm.expectRevert(NoProfit.selector);
        solver.solve(g[0], 0, GAS_ONLY_WEI_PER_GAS, 10000, address(0), bytes32(0));
        Plan memory two = solver.solve(g[1], 0, GAS_ONLY_WEI_PER_GAS, 10000, address(0), bytes32(0));
        Plan memory many = solver.solveMany(g, _floors(0, 0), GAS_ONLY_WEI_PER_GAS, 10000, address(0), bytes32(0));
        assertEq(many.legs.length, 2, "the clearing cycle");
        assertEq(many.amountIn, two.amountIn);
        assertEq(many.minProfit, two.minProfit);
    }

    /// A shape error (BadLeg from Pools.validate) in one cycle no longer reverts the group.
    function test_solveMany_skipsBadLegCycle() public {
        _pushV3(PUSH_SMALL);
        Leg[] memory bad = feeTierCycle();
        bad[1].tokenIn = address(0xdead); // breaks the chain
        Plan memory many = solver.solveMany(_pair(bad, feeTierCycle()), _floors(0, 0), 0, 10000, address(0), bytes32(0));
        assertGt(many.amountOut, many.amountIn);
    }

    function test_solveMany_allQuiet_revertsNoProfit() public {
        vm.expectRevert(NoProfit.selector);
        solver.solveMany(
            _pair(stableTriangleV3(), feeTierCycle()),
            _floors(0.0002 ether, 0.0002 ether),
            0,
            10000,
            address(0),
            bytes32(0)
        );
    }

    function test_solveMany_lengthMismatch_revertsBadLeg() public {
        uint256[] memory one = new uint256[](1);
        vm.expectRevert(BadLeg.selector);
        solver.solveMany(_pair(stableTriangleV3(), feeTierCycle()), one, 0, 10000, address(0), bytes32(0));

        vm.expectRevert(BadLeg.selector);
        solver.solveMany(new Leg[][](0), new uint256[](0), 0, 10000, address(0), bytes32(0));

        Leg[][] memory nine = new Leg[][](9);
        for (uint256 i; i < 9; ++i) {
            nine[i] = feeTierCycle();
        }
        vm.expectRevert(BadLeg.selector);
        solver.solveMany(nine, new uint256[](9), 0, 10000, address(0), bytes32(0));
    }

    /// Gas of a call, every pool of both cycles cold.
    function _callGas(bytes memory call) internal returns (uint256 used) {
        _cool(stableTriangleV3());
        _cool(feeTierCycle());
        used = gasleft();
        (bool ok,) = address(solver).staticcall(call);
        used -= gasleft();
        ok; // the quiet solve reverts NoProfit by design
    }

    /// One group call costs no more than its cycles' separate solves (+10%), all cold.
    function test_solveMany_gas_underSumOfParts() public {
        _pushV3(PUSH_SMALL);
        uint256 a = _callGas(
            abi.encodeCall(solver.solve, (stableTriangleV3(), 0.0002 ether, 0, 10000, address(0), bytes32(0)))
        );
        uint256 b = _callGas(abi.encodeCall(solver.solve, (feeTierCycle(), 0, 0, 10000, address(0), bytes32(0))));
        uint256 many = _callGas(
            abi.encodeCall(
                solver.solveMany,
                (_pair(stableTriangleV3(), feeTierCycle()), _floors(0.0002 ether, 0), 0, 10000, address(0), bytes32(0))
            )
        );
        emit log_named_uint("solve quiet gas", a);
        emit log_named_uint("solve pushed gas", b);
        emit log_named_uint("solveMany gas", many);
        assertLe(many, (a + b) * 11 / 10);
    }

    /// A real cycle with no crossing whose profit cannot reach the floor reverts on the exact in-range
    /// output, without a LegSim pass, just above the plan's profit as well as above the bound. The fold
    /// is lossy here (mainnet reserves), so the bound needs the shifts' directed rounding.
    function test_belowFloor_inRange_revertsNoProfitCheaply() public {
        Plan memory p = _solvePushed(PUSH_SMALL);
        Leg[] memory legs = p.legs;
        (, uint256 maxProfit) = closedForm(legs);
        uint256 realised = p.amountOut - p.amountIn;
        emit log_named_uint("realised best", realised);
        emit log_named_uint("maxProfit", maxProfit);
        assertGt(maxProfit, realised, "the bound is above the realised best");
        assertLe(maxProfit - realised, realised / 1000, "and within 0.1% of it");

        _cool(legs);
        uint256 justAbove = revertGas(solver, legs, realised + 1);
        _cool(legs);
        uint256 bounded = revertGas(solver, legs, maxProfit + 1);
        emit log_named_uint("NoProfit gas, floor just above the plan", justAbove);
        emit log_named_uint("NoProfit gas, floor above the bound", bounded);
        assertLt(justAbove, 70_000, "cheap revert just above the plan");
        assertLt(bounded, 70_000, "cheap revert above the bound");
    }

    /// The solver's exact profit is at least the best of a dense exact scan, minus a few wei.
    function _assertBeatsScan(Leg[] memory legs, uint256 hi, uint256 steps) internal returns (Plan memory p) {
        uint256 exact;
        uint256 g;
        int256 best;
        (p, exact, g, best) = solveAndScan(solver, legs, hi, steps);
        int256 profit = int256(p.amountOut) - int256(p.amountIn);
        emit log_named_uint("solve gas", g);
        emit log_named_int("profit", profit);
        emit log_named_int("scan best", best);
        assertEq(p.amountOut, exact, "amountOut exact");
        assertGe(profit, best - int256(10 * legs.length), "beats the scan");
    }

    /// ETH sold into the V4 pool is cheap there: sell WETH on V3, buy ETH back on V4.
    function v4Cycle() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V4, USDC, address(0), 100, 1);
    }

    function _pushV4() internal returns (PoolKey memory key) {
        key = Pools.v4Key(Leg(V4, address(0), USDC, 100, 1));
        V4Pusher pusher = new V4Pusher();
        vm.deal(address(this), PUSH_V4);
        pusher.push{value: PUSH_V4}(key, PUSH_V4);
    }

    function test_v4Leg_cycle() public {
        _pushV4();
        Plan memory p = solver.solve(v4Cycle(), 0, 0, 5000, address(0xbeef), bytes32(0));
        _assertExactAndOptimal(p);
        assertEq(p.builderShareBps, 5000);
        assertEq(p.recipient, address(0xbeef), "solve echoes the recipient");
    }

    function test_gas_threeLegsNoCrossing_under60k() public {
        Leg[] memory legs = stableTriangleV3();
        bytes memory call = abi.encodeCall(solver.solve, (legs, 0.0002 ether, 0, 10000, address(0), bytes32(0)));
        uint256 before = gasleft();
        (bool ok, bytes memory err) = address(solver).staticcall(call);
        uint256 used = before - gasleft();
        assertFalse(ok);
        assertEq(bytes4(err), NoProfit.selector, "quiet market reverts NoProfit, not earlier");
        emit log_named_uint("gas", used);
        assertLt(used, 60_000);
    }

    /// Fresh pools with a plain token T (token0, below WETH): a V3 0.05% pool at 1000 T per WETH with
    /// liquidity 5e20 on [c - 100, c + 10) and 1.5e23 on [c + 20 - gap, c + 5000), and a V2 pair at 950 T per
    /// WETH, 1000 WETH deep. Buy T on V3, sell it on V2. gap = 10 leaves no liquidity on [c + 10, c + 20).
    /// The pool starts at tick c + start.
    function _thinThenDeep(int24 gap, int24 start) internal returns (Leg[] memory legs) {
        address t = address(0x7e57);
        vm.etch(t, address(new FeeToken()).code); // taxedSender unset: a plain token
        vm.deal(address(this), 1100 ether);
        IWETH(WETH).deposit{value: 1100 ether}();

        int24 c = -69080;
        address pool = IV3FactoryCreate(_v().v3Factory).createPool(t, WETH, 500);
        IV3PoolSeed(pool).initialize(TickMath.getSqrtPriceAtTick(c + start));
        IV3PoolSeed(pool).mint(address(this), c - 100, c + 10, 5e20, abi.encode(t));
        IV3PoolSeed(pool).mint(address(this), c + 10 + gap, c + 5000, 1.5e23, abi.encode(t));

        address pair = IV2FactoryCreate(_v().v2Factory).createPair(t, WETH);
        FeeToken(t).mint(pair, 950_000 ether);
        IERC20(WETH).transfer(pair, 1000 ether);
        IV2PairMint(pair).mint(address(this));

        legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, t, 500, 10);
        legs[1] = Leg(V2, t, WETH, 3000, 0);
    }

    /// A thin active range in front of deep liquidity: the closed form sees only the thin range, so x0 is
    /// ~1/100 of the optimum.
    function test_regionWalk_deeperPastTick_beatsScan() public {
        Leg[] memory legs = _thinThenDeep(0, 0);
        (uint256 x0,) = closedForm(legs);
        (, uint8 crossings,,) = LegSim.tryCycleOut(_v(), legs, x0);
        assertGt(crossings, 0, "x0 crosses the thin range");
        Plan memory p = _assertBeatsScan(legs, 60 ether, 300);
        assertGt(p.amountIn, 20 * x0, "the optimum is far past x0");
    }

    /// A zero-liquidity gap between the thin and the deep range: rho is 0 inside it, the walk moves through it.
    function test_regionWalk_gapThenDeep_findsOptimum() public {
        Leg[] memory legs = _thinThenDeep(10, 0);
        Plan memory p = _assertBeatsScan(legs, 60 ether, 300);
        assertGt(p.amountOut, p.amountIn, "profit > 0");
    }

    /// The price starts inside the gap (no active liquidity, as after a push through the last range): the
    /// pool is not dead, the walk first moves through the gap to the deep range.
    function test_regionWalk_startsInGap_findsOptimum() public {
        Leg[] memory legs = _thinThenDeep(10, 15);
        assertEq(IUniswapV3Pool(Pools.v3Pool(_v(), WETH, legs[0].tokenOut, 500)).liquidity(), 0, "no active liquidity");
        Plan memory p = _assertBeatsScan(legs, 60 ether, 300);
        assertGt(p.amountOut, p.amountIn, "profit > 0");
    }

    /// maxProfit bounds the realised best on V3/V4 legs whose out-token is coarse (a few hundred units in
    /// the pool), where flooring the out-side virtual reserve made the bound 5-15% short. Both swap
    /// directions, each a fresh full-range 0.05% pool -> a V2 pair; cases found by brute force
    /// over Uniswap's integer math, then checked here against LegSim.
    function test_maxProfit_boundsRealisedBest_v3InRange() public {
        // WETH is token1: the V3 leg is oneForZero
        _checkBound(_v3Leg(address(0x7e57), 122747874, 76633983545653882868198344592890992), 221, 224489630923149);
        // WETH is token0: the V3 leg is zeroForOne
        uint160 sp = 28888223986542754459229364;
        _checkBound(_v3Leg(address(uint160(type(uint160).max) - 0x7e57), 1049712, sp), 502, 3889218759);
    }

    /// Mainnet-sized: a USDC/WETH-like full-range pool (T has 6 decimals, ~3000 T per WETH, L = 1e17: about
    /// 5.5M T and 1,826 WETH) and a V2 pair
    /// paying 5% more WETH for T. The fold's coefficients pass 2^128, so the shifts round.
    function test_maxProfit_boundsRealisedBest_v3MainnetSized() public {
        uint160 sp = 1446501726624926496477173928747177; // sqrt(1e18 / 3000e6) · 2^96: WETH wei per T unit
        _checkBound(_v3Leg(address(0x7e58), 1e17, sp), 3_000_000e6, 1050 ether);
    }

    /// The zeroForOne case again, on a V4 ETH pool (same swap math, LegSim's V4 reads).
    function test_maxProfit_boundsRealisedBest_v4InRange() public {
        address t = address(0x7e57);
        vm.etch(t, address(new FeeToken()).code);
        Leg memory leg = Leg(V4, address(0), t, 500, 10);
        PoolKey memory key = Pools.v4Key(leg);
        IPoolManager(POOL_MANAGER).initialize(key, 28888223986542754459229364);
        vm.deal(address(this), 1 ether);
        new V4FullRangeLp().add{value: 1 ether}(key, 1049712);
        _checkBound(leg, 502, 3889218759);
    }

    function _v3Leg(address t, uint128 liquidity, uint160 sqrtPrice) internal returns (Leg memory) {
        vm.etch(t, address(new FeeToken()).code);
        vm.deal(address(this), 3000 ether);
        IWETH(WETH).deposit{value: 3000 ether}();
        address pool = IV3FactoryCreate(_v().v3Factory).createPool(t, WETH, 500);
        IV3PoolSeed(pool).initialize(sqrtPrice);
        IV3PoolSeed(pool).mint(address(this), -887270, 887270, liquidity, abi.encode(t));
        return Leg(V3, WETH, t, 500, 10);
    }

    /// leg0 buys a fresh token T on a full-range pool; a fresh V2 pair (rT, rWeth) sells it back.
    function _checkBound(Leg memory leg0, uint256 rT, uint256 rWeth) internal {
        address t = leg0.tokenOut;
        vm.deal(address(this), 1100 ether);
        IWETH(WETH).deposit{value: 1100 ether}();
        address pair = IV2FactoryCreate(_v().v2Factory).createPair(t, WETH);
        FeeToken(t).mint(pair, rT);
        IERC20(WETH).transfer(pair, rWeth);
        IV2PairMint(pair).mint(address(this));

        Leg[] memory legs = new Leg[](2);
        legs[0] = leg0;
        legs[1] = Leg(V2, t, WETH, 3000, 0);
        (uint256 rin, uint256 rout,) = LegProbe.virtualReserves(_v(), legs[0]);
        (, uint256 maxProfit) = closedForm(legs);

        // The best input for k units of T is the least that buys k, so the best profit is a max over
        // k. Every k when the pool holds few units; otherwise a ternary search over k (the profit is
        // concave in k up to a wei of rounding) and every k within 20 of its result.
        int256 best;
        (uint256 kLo, uint256 kHi) = (1, rout / 2);
        if (kHi > 1000) {
            while (kHi - kLo > 40) {
                uint256 k1 = kLo + (kHi - kLo) / 3;
                uint256 k2 = kHi - (kHi - kLo) / 3;
                if (this.profitAt(legs, rin, k1) < this.profitAt(legs, rin, k2)) kLo = k1;
                else kHi = k2;
            }
        }
        for (uint256 k = kLo; k < kHi; ++k) {
            int256 p = this.profitAt(legs, rin, k);
            if (p > best) best = p;
        }
        emit log_named_int("realised best", best);
        emit log_named_uint("maxProfit", maxProfit);
        assertGt(best, 0, "precondition: the cycle pays");
        assertGe(maxProfit, uint256(best), "maxProfit bounds the realised best");
        assertLe(maxProfit - uint256(best), uint256(best) / 4, "and is within 25% of it");
    }

    /// Profit of the least input that buys k units of leg 0's out-token. External, so each call starts
    /// with fresh memory.
    function profitAt(Leg[] memory legs, uint256 rin, uint256 k) external view returns (int256) {
        (uint256 lo, uint256 hi) = (1, 2 * rin + 2);
        while (lo < hi) {
            uint256 m = (lo + hi) / 2;
            (uint256 got,) = LegProbe.amountOut(_v(), legs[0], m);
            if (got >= k) hi = m;
            else lo = m + 1;
        }
        (uint256 back,) = LegProbe.amountOut(_v(), legs[1], k);
        return int256(back) - int256(lo);
    }

    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata data) external {
        address t = abi.decode(data, (address));
        (uint256 owedT, uint256 owedWeth) = t < WETH ? (owed0, owed1) : (owed1, owed0);
        FeeToken(t).mint(msg.sender, owedT);
        IERC20(WETH).transfer(msg.sender, owedWeth);
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ForkTest, _v, WETH} from "./Fork.t.sol";
import {SettableV3Pool, MockPair, closedForm} from "./CycleSolver.t.sol";
import {CycleSolver} from "../src/CycleSolver.sol";
import {CycleExecutor} from "../src/CycleExecutor.sol";
import {LegSim} from "../src/lib/LegSim.sol";
import {LegProbe} from "./LegProbe.sol";
import {Pools} from "../src/lib/Pools.sol";
import {StepEdge} from "../src/lib/StepEdge.sol";
import {InRange} from "../src/lib/InRange.sol";
import {RateFilter, Quote} from "../src/lib/RateFilter.sol";
import {Leg, Plan, V2, V3, V4, Venues} from "../src/Types.sol";

/// Exact brute force over the coarse amount n that leg k outputs: the smallest x whose legs 0..k reach
/// n (bisection on LegSim, independent of StepEdge's inverse) and the cycle profit there.
abstract contract EdgeBrute is Test {
    function _prefixOut(Leg[] memory pre, uint256 x) internal view returns (uint256 o) {
        bool ok;
        (o,,, ok) = LegSim.tryCycleOut(_v(), pre, x);
        if (!ok) o = 0;
    }

    function _edgeX(Leg[] memory pre, uint256 n, uint256 lo, uint256 hi) internal view returns (uint256) {
        require(_prefixOut(pre, lo) < n && _prefixOut(pre, hi) >= n, "bracket");
        while (hi - lo > 1) {
            uint256 m = (lo + hi) / 2;
            if (_prefixOut(pre, m) >= n) hi = m;
            else lo = m;
        }
        return hi;
    }

    /// Best profit over n in [nLo, nHi]; the bracket for every n is [xLo, xHi]. One external call per n:
    /// each gets fresh memory (a few hundred LegSim probes per n would exhaust one frame's).
    function _bestEdge(Leg[] memory legs, uint256 k, uint256 nLo, uint256 nHi, uint256 xLo, uint256 xHi)
        internal
        view
        returns (int256 best, uint256 bestX)
    {
        best = type(int256).min;
        for (uint256 n = nLo; n <= nHi; ++n) {
            (int256 p, uint256 x) = this.edgeAt(legs, k, n, xLo, xHi);
            if (p > best) (best, bestX) = (p, x);
        }
    }

    function edgeAt(Leg[] memory legs, uint256 k, uint256 n, uint256 xLo, uint256 xHi)
        external
        view
        returns (int256, uint256 x)
    {
        Leg[] memory pre = new Leg[](k + 1);
        for (uint256 i; i <= k; ++i) {
            pre[i] = legs[i];
        }
        x = _edgeX(pre, n, xLo, xHi);
        return (_profit(legs, x), x);
    }

    function _profit(Leg[] memory legs, uint256 x) internal view returns (int256) {
        (uint256 out,,,) = LegSim.tryCycleOut(_v(), legs, x);
        return int256(out) - int256(x);
    }
}

/// StepEdge.refine on the start quotes of `legs` at a given x (in range on every leg).
contract RefineHarness {
    function refine(Leg[] memory legs, uint256 x) external view returns (uint256, uint256, uint256 outAtX) {
        Venues memory v = _v();
        Quote[] memory q = RateFilter.quotes(v, legs);
        uint160[] memory lim = InRange.limits(v, q);
        bool ok;
        (outAtX, ok) = InRange.cycleOut(q, lim, x);
        require(ok && outAtX > x, "x in range and profitable");
        (uint256 xr, uint256 outr) = StepEdge.refine(q, lim, x, outAtX);
        return (xr, outr, outAtX);
    }
}

/// No fork: settable V3 pools at their derived addresses, an 8-decimal token worth 2.5e11 wei a unit.
contract StepEdgeMockTest is EdgeBrute {
    address constant CBTC = 0x72df000000000000000000000000000000000001; // token0 against WETH and USD
    address constant USD = 0xA0b8000000000000000000000000000000000002; // 6 decimals, token1 against CBTC
    uint256 constant Q96 = 1 << 96;

    CycleSolver solver;

    function setUp() public {
        solver = new CycleSolver(_v());
    }

    function _pool(address a, address b, uint24 fee, uint256 sqrtP, uint128 l, int24 spacing) internal {
        address p = Pools.v3Pool(_v(), a, b, fee);
        vm.etch(p, address(new SettableV3Pool()).code);
        SettableV3Pool(p).set(uint160(sqrtP), l, fee, spacing);
    }

    /// WETH -> CBTC on a 1 bp pool, CBTC -> WETH on a 30 bp pool quoting 1 % more WETH per CBTC. The coarse
    /// amount is leg 0's output; the 30 bp consumer floors its fee in units of 1e6 / 3000 = 333 CBTC.
    function _twoLeg() internal returns (Leg[] memory legs) {
        uint256 s = 500_000 * Q96; // sqrt(2.5e11 WETH wei per CBTC unit)
        _pool(WETH, CBTC, 100, s, 5e15, 1);
        _pool(WETH, CBTC, 3000, s * 20_100 / 20_000, 2e15, 60);
        legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, CBTC, 100, 1);
        legs[1] = Leg(V3, CBTC, WETH, 3000, 60);
    }

    /// Solves `legs` (in range at the closed form x0): the plan is exact and earns more than x0.
    function _solveRefined(Leg[] memory legs) internal returns (Plan memory p, uint256 x0, int256 gain) {
        (x0,) = closedForm(legs);
        (uint256 out0, uint8 c0) = LegProbe.cycleOut(_v(), legs, x0);
        assertEq(c0, 0, "precondition: in range");
        p = solver.solve(legs, 0, 0, 10000, address(0), bytes32(0));
        (uint256 exact,) = LegProbe.cycleOut(_v(), p.legs, p.amountIn);
        assertEq(p.amountOut, exact, "plan exact");
        gain = int256(p.amountOut - p.amountIn) - (int256(out0) - int256(x0));
        assertGe(gain, 0, "never below the closed-form plan");
        emit log_named_int("gain over the closed form (wei)", gain);
    }

    /// The sawtooth: the plan is the best edge within +-400 units of the closed form's coarse amount (both
    /// neighbouring 333-unit fee units), exact, and above the closed-form input it replaces.
    function test_sawtooth_twoLeg_planIsBestEdge() public {
        Leg[] memory legs = _twoLeg();
        (Plan memory p, uint256 x0, int256 gain) = _solveRefined(legs);
        assertGt(gain, 0, "the edge beats the smooth optimum");
        Leg[] memory pre = new Leg[](1);
        pre[0] = legs[0];
        uint256 n0 = _prefixOut(pre, x0);
        emit log_named_uint("coarse units at x0", n0);
        (int256 best,) = _bestEdge(legs, 0, n0 - 400, n0 + 400, x0 * 95 / 100, x0 * 105 / 100);
        assertGe(int256(p.amountOut - p.amountIn), best, "no edge within two fee units beats the plan");
    }

    /// WETH -> USD (6 decimals) -> CBTC -> WETH, 1 bp each, a mined cycle's shape: the finer USD token
    /// in front of the coarse amount adds +-1 USD unit to every edge, which the scan ranks.
    function _threeLeg() internal returns (Leg[] memory legs) {
        // USD per WETH raw: 4000e6 / 1e18 -> USD is token0 vs WETH? 0xA0B8.. < 0xC02a..: yes, price = WETH per USD.
        _pool(WETH, USD, 100, 15_811_388 * Q96 / 1000, 1.58e17, 1); // sqrt(1e18 / 4000e6) = 15811.388
        _pool(USD, CBTC, 100, 31_622_776 * Q96 / 1_000_000, 3.16e11, 1); // sqrt(1e11 / 1e8) = 31.622776
        _pool(CBTC, WETH, 100, 500_000 * Q96 * 10_008 / 10_000, 5e15, 1); // CBTC 16 bp dearer in WETH here
        legs = new Leg[](3);
        legs[0] = Leg(V3, WETH, USD, 100, 1);
        legs[1] = Leg(V3, USD, CBTC, 100, 1);
        legs[2] = Leg(V3, CBTC, WETH, 100, 1);
    }

    function test_sawtooth_threeLeg_neverLowerAndExact() public {
        Leg[] memory legs = _threeLeg();
        (Plan memory p,, int256 gain) = _solveRefined(legs);
        assertGt(gain, 0, "the edge beats the smooth optimum");
        // Brute force: every amount within 24 units of the plan's own coarse amount.
        Leg[] memory pre = new Leg[](2);
        (pre[0], pre[1]) = (legs[0], legs[1]);
        uint256 n = _prefixOut(pre, p.amountIn);
        (int256 best,) = _bestEdge(legs, 1, n - 24, n + 24, p.amountIn * 99 / 100, p.amountIn * 101 / 100);
        assertGe(int256(p.amountOut - p.amountIn), best, "no nearby edge beats the plan");
    }

    /// The producer swaps zero for one: an 8-decimal token at an address above WETH (WETH is token0).
    function test_sawtooth_zfoProducer_coarseAboveWeth() public {
        address hbtc = 0xd000000000000000000000000000000000000003;
        uint256 s = 2 * Q96 / 1_000_000; // sqrt(1e8 / 25e18) = 2e-6 (HBTC units per WETH wei)
        _pool(WETH, hbtc, 100, s, 5e15, 1);
        _pool(WETH, hbtc, 3000, s * 20_000 / 20_100, 2e15, 60); // more WETH per HBTC here
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, hbtc, 100, 1);
        legs[1] = Leg(V3, hbtc, WETH, 3000, 60);
        assertTrue(Pools.zeroForOne(legs[0]), "precondition: producer is zero for one");
        _solveRefined(legs);
    }

    /// The producer is a V2 pair (exact getAmountOut inverse), the consumer a 1 bp V3 pool.
    function test_sawtooth_v2Producer() public {
        address pair = Pools.v2Pair(_v(), WETH, CBTC);
        vm.etch(pair, address(new MockPair()).code);
        MockPair(pair).set(1e10, 2500e18); // CBTC is token0: 100 CBTC, 2500 WETH
        _pool(WETH, CBTC, 100, 500_000 * Q96 * 20_100 / 20_000, 5e15, 1); // 1 % more WETH per CBTC
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V2, WETH, CBTC, 3000, 0);
        legs[1] = Leg(V3, CBTC, WETH, 100, 1);
        _solveRefined(legs);
    }

    /// The gate passes but refine keeps x: x is already the left edge of a fee-unit end (1e7 CBTC, a
    /// multiple of the 30 bp consumer's 1e6 / 3000 units), so no candidate beats it strictly.
    function test_gatePasses_atFeeUnitEnd_declines() public {
        Leg[] memory legs = _twoLeg();
        (uint256 x0,) = closedForm(legs);
        Leg[] memory pre = new Leg[](1);
        pre[0] = legs[0];
        uint256 n = 10_000_000;
        assertLe(_prefixOut(pre, x0 * 95 / 100), n, "precondition: 1e7 units near x0");
        uint256 x = _edgeX(pre, n, x0 * 95 / 100, x0 * 105 / 100);
        assertLe(_prefixOut(pre, x0) << StepEdge.UNIT_SHIFT, x0, "precondition: the gate passes");
        RefineHarness h = new RefineHarness();
        (uint256 xr, uint256 outr, uint256 outX) = h.refine(legs, x);
        assertEq(xr, x, "declines: keeps x");
        assertEq(outr, outX);
        (uint256 exact,) = LegProbe.cycleOut(_v(), legs, xr);
        assertEq(outr, exact, "exact");
        // 1 gwei above the edge pays the same n for more: refine moves back down to the edge, never lower.
        (xr, outr, outX) = h.refine(legs, x + 1e9);
        assertEq(xr, x, "refines x + 1 gwei to the edge");
        (exact,) = LegProbe.cycleOut(_v(), legs, xr);
        assertEq(outr, exact);
        assertGe(outr - xr, outX - (x + 1e9), "at least the plan it was given");
        // The solver's own plan on this state is at least the closed-form plan.
        Plan memory p = solver.solve(legs, 0, 0, 10000, address(0), bytes32(0));
        assertGe(int256(p.amountOut - p.amountIn), _profit(legs, x0));
    }

    /// A 6-decimal intermediate (a unit ~2.5e8 wei) is below the gate: the plan stays the closed form.
    function test_fineToken_belowGate_planIsClosedForm() public {
        _pool(WETH, USD, 100, 15_811_388 * Q96 / 1000, 1.58e17, 1);
        _pool(WETH, USD, 500, 15_811_388 * Q96 / 1000 * 20_040 / 20_000, 5e17, 10);
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USD, 100, 1);
        legs[1] = Leg(V3, USD, WETH, 500, 10);
        (uint256 x0,) = closedForm(legs);
        Plan memory p = solver.solve(legs, 0, 0, 10000, address(0), bytes32(0));
        assertEq(p.amountIn, x0);
    }
}

/// Mainnet state of block 26294180 before tx index 31, cycle eth_cirbtc_usdc__v3_100_v3_100_v3_100 in its
/// reverse orientation inside a group of 4.
/// Without the step-edge pass the plan pays 37,614,611,872,838 wei at 0.20477 ETH; the true maximum (exact
/// edge search over the cirBTC amount, checked by execute) is 38,003,587,031,869 wei at 0.20325 ETH.
contract StepEdgeReplayForkTest is EdgeBrute {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant CIRBTC = 0x72DFB2E44f59C5AD2bAFE84314E5b99a7cd5075E;
    uint256 constant TRUE_MAX = 38_003_587_031_869;
    uint256 constant OLD_PROFIT = 37_614_611_872_838;

    /// Block 26294180 up to tx index 30: fork at 26294179 and replay the block's type-2 txs 0..30. The four
    /// blob txs (17, 18, 19, 27: rollup inboxes, no pool) are skipped: forge 1.5.1 prices their blob gas
    /// above their cap, which is also why createSelectFork(<tx hash>) fails. The replay is checked below:
    /// the reference plan executes for exactly its profit.
    function setUp() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url, 26_294_179);
        bytes32[27] memory txs = [
            bytes32(0xf3ca23e35049c540d2915ee6ba911329dbc56d0d76a654b13a06aa2add7b6cb7),
            bytes32(0xb64ccfff071719079805032a5212f6b8ff2f5b268b8bbe07e5bbe34566e3345d),
            bytes32(0x52cac7baa70b1ad5fa00e7ee3f76ce1d7b4b7ea7b12e5b076d7a208a07a0c74f),
            bytes32(0xae499478c2469b77df83d523768d5fa34ae0ef2a6f210780d9848865b66b0ccb),
            bytes32(0x6e754c470d2ea822d25afaa70a8f899c684e26a04c34110d62f8c52b33b750d7),
            bytes32(0x84d0b10704936d97b9adf70476c8e17302c0e169090cc4800535d66da0b4d503),
            bytes32(0xefcb042c3ed6d498b266a681f6512970c755dca0d471f788a933d1c7f4f8b44d),
            bytes32(0x459dddbc8e00728bcb8b1ff22b8ea469e45b36d871b14b23526f6f688b8eea59),
            bytes32(0x5cb9afaf20d0380658b76a3f80fa158ff9c899dfac419faf15459dbc7e08a2ba),
            bytes32(0xcac558ad656cd9b5af412603def936772cabaf9f160b58784483b6c5437e1ba1),
            bytes32(0xeae0cbce6f480381a12a84b3349b70a6cbb2be2357c589c7a591a0915bef1e5b),
            bytes32(0x2411f335d3110c00538727c0de635ddea93f83ab2c074c1e74366f249fd27ca3),
            bytes32(0xd71b17fedba370a1323d38a306fabd4f2baab6a0c6d4bf7734705f117c5c98ba),
            bytes32(0xd639700693cdca9d964413304d515042c137c1f2d55fbfc05e41775835177c43),
            bytes32(0x58566ef7419c90b72ea4dbb83c3a07140c9f503f5be4ea66c1bec15ba2ceb57e),
            bytes32(0x1f7e384f9291a81d665765c8934dceba06253507aa0586b813e3f9b643d2ebf6),
            bytes32(0x63c3702c7ca489c8a7f306231b029289582f706a12112ecabf20def493195b4e),
            bytes32(0x40f51858a17a40dabaa655ed35f4e426a5df722f5b356c5def45d72022481530),
            bytes32(0xeb5a7a6cc1d50ced2adaca4d6a3e62e9358c884e0963bcc0f9dbeb7eaffbffa5),
            bytes32(0x07dfa1dbce0e8af4111b481f07dbbb70c75d754037dc4fabef32baa135ea9227),
            bytes32(0x417a12f60d7179447b7a708f8cf17f21042354badf980dae2952664a83d03499),
            bytes32(0xb01b12af713f68f27c27c43f4247b893de83540b56945213c7dd0ad849099b89),
            bytes32(0x998b7bb86651b4b123407dad146e32c50e29d20c966b904c7fec9be93614cbcb),
            bytes32(0xfaacd41ef610bd13f2dc118e86312a3590de09d08c3c71fffb90a31b211fabdb),
            bytes32(0xd271be82fa57bd67e20256121060d8d8d92d67a30e0e0e2c21c6468d637bf400),
            bytes32(0x0e6af90c56f3da53504cb5803e6c1c9df4a1e8256566bd07c28239269be9cdab),
            bytes32(0xc21b9c29da61192e13a687f55da753be33af431db894f4595164b4ffeaf48cdc)
        ];
        for (uint256 i; i < txs.length; ++i) {
            vm.transact(txs[i]);
        }
        vm.roll(26_294_180);
    }

    function _group() internal pure returns (Leg[][] memory g, uint256[] memory floors) {
        g = new Leg[][](4);
        g[0] = new Leg[](3);
        g[0][0] = Leg(V3, WETH, USDC, 100, 1);
        g[0][1] = Leg(V4, USDC, USDT, 7, 1);
        g[0][2] = Leg(V3, USDT, WETH, 100, 1);
        g[1] = new Leg[](2);
        g[1][0] = Leg(V3, WETH, USDC, 100, 1);
        g[1][1] = Leg(V4, USDC, address(0), 100, 1);
        g[2] = new Leg[](2);
        g[2][0] = Leg(V3, WETH, USDT, 100, 1);
        g[2][1] = Leg(V4, USDT, address(0), 100, 1);
        g[3] = new Leg[](3); // as sent: the solver flips it
        g[3][0] = Leg(V3, WETH, CIRBTC, 100, 1);
        g[3][1] = Leg(V3, CIRBTC, USDC, 100, 1);
        g[3][2] = Leg(V3, USDC, WETH, 100, 1);
        floors = new uint256[](4);
        (floors[0], floors[1], floors[2], floors[3]) =
        (20_516_247_602_600, 16_197_037_581_000, 16_197_037_581_000, 20_516_247_602_600);
    }

    /// The replay is exact: the reference plan (made without the step-edge pass) pays exactly OLD_PROFIT.
    function test_replay26294180_replayMatchesReferencePlan() public {
        (Leg[][] memory g,) = _group();
        Leg[] memory legs = new Leg[](3);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V3, USDC, CIRBTC, 100, 1);
        legs[2] = Leg(V3, CIRBTC, WETH, 100, 1);
        assertEq(
            Pools.cycleId(legs),
            Pools.cycleId(new CycleSolver(_v()).solve(g[3], 0, 0, 10000, address(0), bytes32(0)).legs)
        );
        Plan memory ref = Plan(
            204_765_628_118_370_744, 204_803_242_730_243_582, 20_516_247_602_600, 10000, address(0), bytes32(0), legs
        );
        (uint256 out,) = LegProbe.cycleOut(_v(), legs, ref.amountIn);
        assertEq(out, ref.amountOut, "reference amountOut");
        CycleExecutor ex = new CycleExecutor(_v());
        uint256 cb = block.coinbase.balance;
        ex.execute(ref);
        assertEq(block.coinbase.balance - cb, OLD_PROFIT, "reference profit");
    }

    function test_replay26294180_reachesTrueMaximum_andExecutesExactly() public {
        (Leg[][] memory g, uint256[] memory floors) = _group();
        CycleSolver solver = new CycleSolver(_v());
        uint256 g0 = gasleft();
        Plan memory p = solver.solveMany(g, floors, 0, 10000, address(0), bytes32(0));
        emit log_named_uint("solveMany gas", g0 - gasleft());
        assertEq(p.legs[0].tokenOut, USDC, "reverse orientation: WETH -> USDC -> cirBTC -> WETH");
        assertEq(p.legs[1].tokenOut, CIRBTC);
        uint256 profit = p.amountOut - p.amountIn;
        emit log_named_uint("plan amountIn", p.amountIn);
        emit log_named_uint("plan profit", profit);
        assertGe(profit, TRUE_MAX, "reaches the edge-search maximum");
        assertGt(profit, OLD_PROFIT);
        (uint256 exact,) = LegProbe.cycleOut(_v(), p.legs, p.amountIn);
        assertEq(p.amountOut, exact, "plan exact");

        CycleExecutor ex = new CycleExecutor(_v());
        uint256 cb = block.coinbase.balance;
        ex.execute(p);
        assertEq(block.coinbase.balance - cb, profit, "coinbase delta == plan profit");
    }

    /// The plan is the best edge among the 21 amounts at and below the nearest fee-unit end (590,000:
    /// 1e6 / 100 = 10,000 cirBTC units per fee unit) and within 8 of the plan's own amount.
    function test_replay26294180_noNearbyEdgeBeatsPlan() public {
        (Leg[][] memory g,) = _group();
        CycleSolver solver = new CycleSolver(_v());
        Plan memory p = solver.solve(g[3], 0, 0, 10000, address(0), bytes32(0));
        Leg[] memory pre = new Leg[](2);
        (pre[0], pre[1]) = (p.legs[0], p.legs[1]);
        uint256 n = _prefixOut(pre, p.amountIn);
        (int256 best,) = _bestEdge(p.legs, 1, 589_980, 590_000, p.amountIn * 99 / 100, p.amountIn * 101 / 100);
        (int256 near,) = _bestEdge(p.legs, 1, n - 8, n + 8, p.amountIn * 99 / 100, p.amountIn * 101 / 100);
        int256 profit = int256(p.amountOut - p.amountIn);
        assertGe(profit, best);
        assertGe(profit, near);
        assertEq(profit, _profit(p.legs, p.amountIn));
    }
}

/// Block 26296795 before tx index 109: WETH -> cirBTC -> WBTC -> WETH, 1 bp each, two adjacent 8-decimal tokens.
/// The pools hold the exact state before that tx, inverted from its three Swap logs. For every
/// cirBTC amount n in 610,000..729,999 this state gives the same x_min(n), WBTC m(n) and WETH out as the
/// mainnet quoters. Below, "single-coarse" is the step-edge pass without the two-coarse candidate.
/// It plans n = 670,000 (45,791,224,371,910 wei); the maximum is
/// n = 668,893 (46,316,566,087,038 wei), the first n after the last skipped m below leg 3's fee-unit end.
abstract contract TwoCoarseState is EdgeBrute {
    address constant CIRBTC = 0x72DFB2E44f59C5AD2bAFE84314E5b99a7cd5075E;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    uint256 constant TRUE_MAX = 46_316_566_087_038;
    uint256 constant MAX_X = 231_226_940_738_578_246;
    uint256 constant SINGLE_PROFIT = 45_791_224_371_910;
    uint256 constant SINGLE_X = 231_609_651_954_960_753;
    uint256 constant SINGLE_OUT = 231_655_443_179_332_663;
    uint256 constant PREV_X = 231_934_254_358_320_690; // the plan before the step-edge pass

    function _legs() internal pure returns (Leg[] memory legs) {
        legs = new Leg[](3);
        legs[0] = Leg(V3, WETH, CIRBTC, 100, 1);
        legs[1] = Leg(V3, CIRBTC, WBTC, 100, 1);
        legs[2] = Leg(V3, WBTC, WETH, 100, 1);
    }
}

/// StepEdge's single-coarse gate and the two-coarse-leg run start on the start quotes of `legs` at x (0: no candidate).
/// When the run start is 0, refine takes exactly the single-coarse path (the new candidate is the only change).
contract RampHarness {
    function rampStart(Leg[] memory legs, uint256 x) external view returns (uint256) {
        Venues memory v = _v();
        Quote[] memory q = RateFilter.quotes(v, legs);
        uint160[] memory lim = InRange.limits(v, q);
        (uint256 k, uint256 yk,) = StepEdge._coarsest(q, lim, x);
        require(k < legs.length && yk > StepEdge.SCAN && yk <= x >> StepEdge.UNIT_SHIFT, "single-coarse gate passes");
        return StepEdge._rampStart(q, lim, k, yk, x);
    }
}

contract StepEdgeTwoCoarseTest is TwoCoarseState {
    uint160 constant S1 = 46_577_685_036_074_774_333_535_578_048_742_662;
    uint128 constant L1 = 4_093_850_004_285_497;
    uint160 constant S2 = 79_165_803_316_379_939_489_909_917_732;
    uint128 constant L2 = 5_138_566_299_635;
    uint160 constant S3 = 46_557_310_707_649_412_652_011_007_984_328_408;
    uint128 constant L3 = 3_818_858_949_852_316;

    CycleSolver solver;
    RampHarness ramp;

    function setUp() public {
        solver = new CycleSolver(_v());
        ramp = new RampHarness();
        _pool(WETH, CIRBTC, S1, L1);
        _pool(CIRBTC, WBTC, S2, L2);
        _pool(WBTC, WETH, S3, L3);
    }

    function _pool(address a, address b, uint160 sqrtP, uint128 l) internal {
        _pool(a, b, 100, 1, sqrtP, l);
    }

    function _pool(address a, address b, uint24 fee, int24 spacing, uint160 sqrtP, uint128 l) internal {
        address p = Pools.v3Pool(_v(), a, b, fee);
        vm.etch(p, address(new SettableV3Pool()).code);
        SettableV3Pool(p).set(sqrtP, l, fee, spacing);
    }

    function test_twoCoarse_rampStartOnState() public view {
        assertEq(ramp.rampStart(_legs(), PREV_X), 669_880, "first m of the run below m = 670,000");
    }

    /// Leg k + 1 is a V2 pair (cirBTC -> WBTC, 0.7 % more WBTC): skipped.
    function test_twoCoarse_gate_v2Consumer_skipped() public {
        address pair = Pools.v2Pair(_v(), CIRBTC, WBTC);
        vm.etch(pair, address(new MockPair()).code);
        MockPair(pair).set(1.01e12, 1e12); // WBTC is token0
        Leg[] memory legs = _legs();
        legs[1] = Leg(V2, CIRBTC, WBTC, 3000, 0);
        assertEq(ramp.rampStart(legs, PREV_X), 0);
    }

    /// A 2-leg cycle: no leg k + 2 (the coarse amount's consumer pays out WETH): skipped.
    function test_twoCoarse_gate_twoLegCycle_skipped() public {
        _pool(WETH, CIRBTC, 3000, 60, S1 * 10_050 / 10_000, L1);
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, CIRBTC, 100, 1);
        legs[1] = Leg(V3, CIRBTC, WETH, 3000, 60);
        assertEq(ramp.rampStart(legs, PREV_X), 0);
    }

    /// n = 1,000 cirBTC and a 30 bp leg 3 (fee unit 333): E = 1,000 <= 2^12, no span below it: skipped.
    function test_twoCoarse_gate_smallFeeUnitEnd_skipped() public {
        _pool(WBTC, WETH, 3000, 60, S3, L3);
        Leg[] memory legs = _legs();
        legs[2] = Leg(V3, WBTC, WETH, 3000, 60);
        assertEq(ramp.rampStart(legs, 345_652_837_269_914 + 1e9), 0);
    }

    /// Leg 2 at 1 + 2e-5 WBTC per cirBTC less fee: D(T) = 13 over the whole span below E = 670,000 (a run is
    /// ~50,000 amounts), so there is no skipped amount to start from: skipped.
    function test_twoCoarse_gate_noSkipInSpan_skipped() public {
        _pool(CIRBTC, WBTC, 79_227_329_588_885_384_312_751_769_134, L2);
        assertEq(ramp.rampStart(_legs(), PREV_X), 0);
    }

    /// Legs 2 and 3 rescaled (0.72 % more WBTC per cirBTC, 0.72 % less WETH per WBTC) and x on the step of
    /// n = 664,500: the single-coarse edge (n = 660,000) beats the run start (n = 664,212, below m = 670,000), so the
    /// plan is the single-coarse edge.
    function test_twoCoarse_rampLosesToSingleEdge_planIsSingleEdge() public {
        _pool(CIRBTC, WBTC, 78_882_336_231_557_215_633_556_816_168, L2);
        _pool(WBTC, WETH, 46_390_604_066_768_873_251_036_903_784_762_550, L3);
        Leg[] memory legs = _legs();
        (, uint256 x) = this.edgeAt(legs, 0, 664_500, PREV_X * 98 / 100, PREV_X);
        x += 1e9;
        uint256 t = ramp.rampStart(legs, x);
        assertGt(t, 0, "the run start is a candidate");
        (int256 pr,) = this.edgeAt(legs, 0, 664_212, PREV_X * 98 / 100, PREV_X);
        assertEq(pr, 46_068_317_782_103, "run start profit");
        (int256 pSingle, uint256 xSingle) = this.edgeAt(legs, 0, 660_000, PREV_X * 97 / 100, PREV_X);
        assertEq(pSingle, 46_117_104_892_915, "single-coarse edge profit");
        (uint256 xr, uint256 outr,) = new RefineHarness().refine(legs, x);
        assertEq(xr, xSingle, "plan = single-coarse edge");
        assertEq(int256(outr - xr), pSingle);
    }

    /// The mirror: WETH -> WBTC -> cirBTC -> WETH (WBTC 0.4 % cheaper on the WBTC/WETH pool). cirBTC is the
    /// coarsest (leg 1) and a coarse WBTC is in front of it; no leg k + 2, so the plan is the single-coarse plan.
    function test_twoCoarse_mirror_keepsSinglePlan() public {
        _pool(WBTC, WETH, 46_464_102_784_916_575_062_362_413_778_066_753, L3); // S3 * sqrt(0.996)
        Leg[] memory legs = new Leg[](3);
        legs[0] = Leg(V3, WETH, WBTC, 100, 1);
        legs[1] = Leg(V3, WBTC, CIRBTC, 100, 1);
        legs[2] = Leg(V3, CIRBTC, WETH, 100, 1);
        (uint256 x0,) = closedForm(legs);
        assertEq(ramp.rampStart(legs, x0), 0, "no run-start candidate at the closed form");
        Plan memory p = solver.solve(legs, 0, 0, 10000, address(0), bytes32(0));
        assertEq(Pools.cycleId(p.legs), Pools.cycleId(legs), "mirror orientation");
        assertEq(ramp.rampStart(legs, p.amountIn), 0, "nor at the plan");
        (uint256 exact,) = LegProbe.cycleOut(_v(), p.legs, p.amountIn);
        assertEq(p.amountOut, exact, "plan exact");
        assertGe(int256(p.amountOut - p.amountIn), _profit(legs, x0), "never below the closed form");
    }

    /// The mock is the replayed state: the reference plan and the sawtooth around the maximum, from LegSim.
    function test_twoCoarse_mockIsReplayedState() public view {
        Leg[] memory legs = _legs();
        (uint256 out,) = LegProbe.cycleOut(_v(), legs, SINGLE_X);
        assertEq(out, SINGLE_OUT, "reference plan");
        (int256 p, uint256 x) = this.edgeAt(legs, 0, 670_000, PREV_X * 99 / 100, PREV_X);
        assertEq(x, SINGLE_X, "the single-coarse plan is the left edge of n = 670,000");
        assertEq(p, int256(SINGLE_PROFIT));
        (p, x) = this.edgeAt(legs, 0, 668_893, PREV_X * 99 / 100, PREV_X);
        assertEq(x, MAX_X);
        assertEq(p, int256(TRUE_MAX));
        (p,) = this.edgeAt(legs, 0, 668_892, PREV_X * 99 / 100, PREV_X);
        assertEq(p, 45_971_795_785_070, "one WBTC unit less before the skip");
        (p,) = this.edgeAt(legs, 0, 668_894, PREV_X * 99 / 100, PREV_X);
        assertEq(p, 46_316_091_637_275, "the run falls after it");
    }

    /// The solve reaches the exact maximum (single-coarse: 1.134 % short), LegSim-exact.
    function test_twoCoarse_solveReachesTrueMax() public {
        uint256 g0 = gasleft();
        Plan memory p = solver.solve(_legs(), 0, 0, 10000, address(0), bytes32(0));
        emit log_named_uint("solve gas", g0 - gasleft());
        assertEq(p.amountIn, MAX_X, "left edge of n = 668,893");
        assertEq(p.amountOut - p.amountIn, TRUE_MAX);
        (uint256 exact,) = LegProbe.cycleOut(_v(), p.legs, p.amountIn);
        assertEq(p.amountOut, exact, "plan exact");
    }

    /// refine from the earlier plans moves to the maximum; from the maximum it keeps it (never lower).
    function test_twoCoarse_refineFromAnyPlan_neverLower() public {
        RefineHarness h = new RefineHarness();
        uint256[3] memory xs = [PREV_X, SINGLE_X, MAX_X];
        for (uint256 i; i < 3; ++i) {
            (uint256 xr, uint256 outr, uint256 outX) = h.refine(_legs(), xs[i]);
            assertGe(outr - xr, outX - xs[i], "never below the plan it was given");
            assertEq(xr, MAX_X);
            assertEq(outr - xr, TRUE_MAX);
        }
    }
}

/// The same state on mainnet: fork at 26296794 and replay the type 0/2 txs 0..108 of 26296795 (the
/// two blob txs 22 and 23, to the Base inbox, are skipped, as in the 26294180 test).
///   ETH_RPC_URL=<archive rpc> forge test --match-contract StepEdgeTwoCoarseForkTest -vv
contract StepEdgeTwoCoarseForkTest is TwoCoarseState {
    address constant WDOGE = 0x35a532d376FFd9a705d0Bb319532837337A398E7;
    address constant ADS = 0xcfcEcFe2bD2FED07A9145222E8a7ad9Cf1Ccd22A;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    function setUp() public {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url, 26_296_794);
        bytes32[107] memory txs = abi.decode(
            hex"1896be56964d32200ce652272457e212c3950ff57fdd7a3548229e7a43e43940"
            hex"d2ed2029712470f663a9356965ec3e90da3f457db6b94c6f83004821a2a9ab91"
            hex"2a362200ce12c56d637b13f1f4e0dd06825227a302125988d52b72ba4717cd30"
            hex"aa62652649fed6e5015c8d667735f48678981b89efde0bcafcfda96f9aaca110"
            hex"ca2624d4ad697961b237265700cfd529e2cc711b91a8fc306df9087a8d42f0f6"
            hex"4620df9dea53ecb390f5d7e11091377c1136568943967e6c367dcdc583b9f2f4"
            hex"9ff24195c34a69d28580790dcc5c0be24e4a8fca93413bd297f9c459294be6e0"
            hex"f008a82800445c7b4ebea00d047ba8fbd7231a4b6a901de5b96cc0f43a645658"
            hex"fe196e8b7fa5c683adba693a1fa7a893efaee9eabddff32787bef0dacaa8d6f7"
            hex"abcc52a1ced56223a9820429584f3e7e9d7b5241bbc0a2d91e37caaa87c34188"
            hex"17d84b911e6c7ffb1adb970b23eebdaa77f0d2385ca8c6698fe8387b27b8e9b3"
            hex"435d89f458723f4c6c9b51c8bc283367b75f1a36dbb003582598f3b9bb7a72b6"
            hex"fa75978d6721b24457477f4a6926a58b081807f5914b710c14d5869183a83012"
            hex"8f3e88f91017645df528bf76e6c2048f9b5799335aa7f3caaf25c01489039a1e"
            hex"96be8cf30129eb719beafdd6f695b0444c921607751733b76c3dade6e1d28292"
            hex"b999b24c086bc56b6096748cfddfb29bffa278e75dabfa0e25e7ec62c5337e32"
            hex"9bdc6645327ea76da3b8d882dc1a536231ec1f057d7d0c1485036f9f31a2fadd"
            hex"49f6f05d31238f2e3a0dd389053df19fd4fc754af50908d05a1182e1a24a43a1"
            hex"7960f0b65319e2d02006ad38ded6d89b7ff659f28d689ee87617ad4f49a9565f"
            hex"1e02f80cef6c05e901c76c19509ca47e528753313d73415cfc67cdcf4116e48b"
            hex"7a475529062c0355b8b55efb5da0e3a6c5f007e34f7c50e95701a90c4f2c7ee9"
            hex"8bf1c5eb6176648e56530e8102469320aa326420cefe4faaff9b810294d53499"
            hex"76cce917e3a6f721e7ac27fbd83af19407ef13d6721b62c06a9ed02635397d10"
            hex"69b1d7ff96e9e47278baf7be0b625f140d9b01483088efb1d4a57d6f96c3b164"
            hex"102bc30efd8400f7f46ed5e96d09891fb44c9001d7e762620392639df0be30c4"
            hex"69b72bc148fa79c07f028cd4f7ce55dbe0693e05c660c83f9b0a5adc4cf42fea"
            hex"5dbee1891a44d6f9a0cbcb80f4c50432fefef65650cbae1a2fcfea55abee9243"
            hex"dae0408a9c36563a647b276fa44f67eff3c8cd5493345a0f487a0f571491fe36"
            hex"73d9adbf20d43187b9d9fbb14823e85ff715f1a413902056791ccd27cab7aeb3"
            hex"1bf078bd80901de5b6f810c93300da6296929bdd51b925517632ef12d37df7b3"
            hex"8b611299847d55fbfc4b03d3f3477b32ae917e8a85461438d119289a05bf27b3"
            hex"6f00f04e832660f73039fde3ae4a16ecc9654779d4450ab5b97043ee29740615"
            hex"650dcd7ebeed59da9f484c7cdd4314707b2cd05e84833269e35d426c85205cf8"
            hex"550f52b900ed318ee8a8de00e13da5ea24c2bc25d412470caf7dccaa3e43ebf1"
            hex"b140f8f8b3ff658a4e5c6875897545fd2f48e4b2a2d1b1e8125f4b23f2b4c7e0"
            hex"94b556c33ca15d86577d90f6d2041f5fe37bb80c1740db3bde4de834c7ee0125"
            hex"fd674fd3235d653e546691182bf00721c29b7fb8966e130aadbe703fb9e630c5"
            hex"169ed678a52db1adec709127cde78f33f83a8144f22e9068bc0d5316ba28370e"
            hex"9f11a2b95be3c951093b6e4a7f83825fd0d95421f78b93441dfe70b76b12da68"
            hex"760e53fb02e5278f90d599a7c4f18a31c2a5cd67021a716370e3c6a5dcac0d5f"
            hex"67a7676267c41f1415163271e75f2d3ba59dbce47826df79d56d841e818fa4bd"
            hex"e556dd8a7715fe789ef3124ee30eb8e8f53eb442c0b638efac5626bbf4467abc"
            hex"4bb805b6b0fae6f3d41a56eb1ac883f54342a8140c514182ad27382941611c54"
            hex"2bdc63427e08a8d893f74242dc1e76e3e5ec3b0afd657534fe3f1f780161fe99"
            hex"b6a1f5967827a0e4ea7ecb99869e5d6d9719faedf46ad71c13bce534f7b94891"
            hex"c02302faba477bb941421501f4511a141d287ef10b974375ec0fd6ce51e146eb"
            hex"d32578a797a8ba548630ef11d6a71fe10aec625f7481492ad98d8572ae425671"
            hex"41d689680e81f90164f0b0a04c43cb7dfe64cd5745a442a0264becee4df707e3"
            hex"8d5141d0f3cee93eb7c90d443470db32512033471f6183d095771e6ce50df6cc"
            hex"9c4d4dee5d9f14af305a30ccd6fbee7cbfae9a3f08d583b138ab62145b993993"
            hex"d3f2ee336f9d2c8539effca1a9cca67a5e5d4486f4c5cdd8e037a765931e480e"
            hex"98ce5a3cc3a23e86eac3b19f45bff103a1332d943e656f6b8e78a89c28c92c7d"
            hex"47b17ac10e0d8ce574f77b6c2d56bc2d6d40ec2c4ac6dba97e08fb59e92a8d67"
            hex"4b81042ce0232b8aac04b6f9db952fd06cca194acc7cd1c117e3cd9113737ad0"
            hex"35eb1088e23a13c7dcf7aa94f48522d33e9bb771ea89d6ea8ed0bdaa0d44d1b8"
            hex"a526476b30651709c4c9b20030357c0a92d6abd379cbf7582f7e9a5851976f9c"
            hex"e555812368d6f44e6b78ee31b9e8f7f1942634fc4518a7f1435f1b4c70d6cd26"
            hex"85f5af96c39e2dd33e6f351df60109d499b7a91c5943b4ecdbdf5167fc013186"
            hex"bccbee30c4ded06acfeca468dbbc34f7c14377600317fd92db53093d2a85a261"
            hex"050c027533e96ed00da906f51c94a7970739bded38db81e4a9a5f0c7206b02fc"
            hex"f4fce8a722a7347309d418086387aa272e3fbd7f6b579164628374f98a07cba4"
            hex"78b32aac907249778fe5a285dc40a18882e64af780c922c524bc492285736ecc"
            hex"9ab8fe6609f04df0d1fbbe0f69db30548d68371519a55a8552cdcb9b7f495276"
            hex"50035a1bf98960b9e197af19840099818d256d28bd8775e274b6b06447987fee"
            hex"a4c4a171dc740d70e5b1904915a00843d538cb3cd23dd575d897fbec0d9d98dc"
            hex"71684211ea4f492ac6c858292fe6c32fba1908e1a05243469d9e855a56789049"
            hex"6ae888ca9fdbe76ca27b4b15963f09f97997c4af9af35e8e4a93de94e532b341"
            hex"2a2a19da03b5cb0a2ba067f2d9d31dd79c5be362d26ed738a90c60b715dd6437"
            hex"7d0135a47fb35663932e46d8bc6aab40cf28d041faff3119b863abd7d36f406e"
            hex"54a4c05ec20ac3b043cf07605d2bfee0eeca8ecba5be9b1d31810271d891618f"
            hex"726448e3b233058eb6332d6ded0474c93f752a13dc61dd05ae04b8f5a521b86c"
            hex"9f2f83d9b6d857150ddff9b36e4af8071ab942259c5978f7a926edeefef586e8"
            hex"3755a854ac9574df6ba9e0c6d6006d7f25d9501bbc8e88996ed1241fafa2e320"
            hex"4bea157e1986698f016f72b4fd8c9a968806dcac7bdac664bade3df5190ba30d"
            hex"78d683d03f1fe81f85781fca9020e270cc7c5c222ce90050f79c87fd8a6a3381"
            hex"8109ea24778202069fcbb4daa2108a369d6cfcea38d5b2c7cbbeab2445a6cfb7"
            hex"0167ac4001cd02008d3d318a247877c8793057c5adf4979dfcb3d4e7d6e5c82a"
            hex"01c9e497d383b14b5491d96b71cb7fc89d3187979289c1371fcebcc6e1513899"
            hex"151c153acede43a861adbb52b0d7da1af2bae75e1da8c62a47b478c8a987b55b"
            hex"686a3fbbba22e975ce4ca514c2f34d81f2870f1ae046983be414f5325831f80f"
            hex"502e691624eef44ffe711f94c4d2af38f5138eaaebd294138509d9ee6f8dfa17"
            hex"da9c096d1ce170025c79e162f54d016aac49f6ae7e5599119f8773e3d57b7ed5"
            hex"fda5ce0f296c3fedb40a23faa3c46f0d24627c909f6ffed3fcf1a32fdd109c1b"
            hex"935e940d951254762fef715f91ca65c76af4d9946a6ba6c9783800ca29e87ed7"
            hex"3137993e34b5ccbefc970cea39a921eac8e9789f30516da8cabeb693fa40830c"
            hex"5aa083a3ee46fc6e8b07226536adeb03455eac8b186f493423cc3eae5ba53047"
            hex"e249709cf41f07264a1527e090ca8035072d234a5d1b1d26b4ec90f06c844ae1"
            hex"3bd2bff921780253cd23f6b16c5a8ddfa76418f8cf87652d2dc29c8f38f89939"
            hex"baf1988b7e23d9620365ea04e432ef515e5f568963b48a40b0820758bd45bdd8"
            hex"11a17ca1115923239a66fa5584b9e95f450bc23be3c194a0791974623dbb4951"
            hex"324568d7d67b7d7009f73ca7e9e5fea3411b3a15b97c51c21697203cfecc1cc5"
            hex"049bd72bac4acb53a08f85fccdeb7b1a01a3882c1e8ae4a84efb21ac62ef7bda"
            hex"e944d7e527efeaa659b8c56e06e071acc3d726a0ec0c4b46c764c43b9a56377e"
            hex"9cbfda39bc91e89a345e2855bc81bc8a954c07a568a5ffa6b784600b83eae64c"
            hex"a63a05d5b7b9f3907b1155e87e61ea4d12d203772df1592ba993c171dc5cdb44"
            hex"f43b79e5bf0c489acf94cc4b944fe0e239b93219be4b516d745ce1a86a210120"
            hex"6272fd3814f4d92e96199fe76dc11fc094cc76725aa684f9db66db7c2ff5ceb2"
            hex"ae4e6bb7eafb6aa1eb3a29a69a5afae0cf29720f85cfafb219586c3f06792eff"
            hex"7cc5a1950cc18253bafd043a823a37dd3f5373d0dc18274b8157ce03756c79e2"
            hex"c6d6cfd6cd85acd4b811332abf6483be167942a33720804a8a80a3016ba8486a"
            hex"2bdfe9e93db242fc612c91c67f50b653f8b2efe36e360f8d928097255db2eab8"
            hex"ecbc79dd3be164cc0c8404a8975d4c1a9bf1c35451e8b3f8f179ed665c15bc29"
            hex"32d6782c72ddd202eb0db0de87708796c73484186763b8600a7db6f57db52b8a"
            hex"a2004d4d286e3bf81f1fd2afabcdf78dd45157c1b9fcfa872ce42b170c7f0368"
            hex"51b81625438b9574493d00c8647fe1c47393946fe5cc899383e327776793ef96"
            hex"849d9761afb9b8496d115714f403c87800bf8238c14fab90d35ac1536700426b"
            hex"069e4596bd8dbe915f5f9fcd005769aaa903e5eca7b4147aa922f24543029d8e",
            (bytes32[107])
        );
        for (uint256 i; i < txs.length; ++i) {
            vm.transact(txs[i]);
        }
        vm.roll(26_296_795);
    }

    /// The group eth_wbtc__v4_100_v3_100+4 with its floors.
    function _group() internal pure returns (Leg[][] memory g, uint256[] memory floors) {
        g = new Leg[][](4);
        g[0] = new Leg[](2);
        g[0][0] = Leg(V4, address(0), WBTC, 100, 1);
        g[0][1] = Leg(V3, WBTC, WETH, 100, 1);
        g[1] = _legs();
        g[2] = new Leg[](3);
        g[2][0] = Leg(V2, WETH, WDOGE, 3000, 0);
        g[2][1] = Leg(V2, WDOGE, WBTC, 3000, 0);
        g[2][2] = Leg(V3, WBTC, WETH, 100, 1);
        g[3] = new Leg[](4);
        g[3][0] = Leg(V4, address(0), WBTC, 100, 1);
        g[3][1] = Leg(V4, WBTC, ADS, 100, 1);
        g[3][2] = Leg(V4, ADS, USDC, 100, 1);
        g[3][3] = Leg(V4, USDC, address(0), 100, 1);
        floors = new uint256[](4);
        (floors[0], floors[1], floors[2], floors[3]) =
        (13_797_113_823_000, 17_476_344_175_800, 17_476_344_175_800, 20_195_106_287_202);
    }

    /// The replay is exact: the single-coarse plan pays exactly SINGLE_PROFIT.
    function test_replay26296795_replayMatchesReferencePlan() public {
        Plan memory ref = Plan(SINGLE_X, SINGLE_OUT, 17_476_344_175_800, 10000, address(0), bytes32(0), _legs());
        (uint256 out,) = LegProbe.cycleOut(_v(), ref.legs, ref.amountIn);
        assertEq(out, SINGLE_OUT, "reference amountOut");
        CycleExecutor ex = new CycleExecutor(_v());
        uint256 cb = block.coinbase.balance;
        ex.execute(ref);
        assertEq(block.coinbase.balance - cb, SINGLE_PROFIT, "reference profit");
    }

    function test_replay26296795_reachesTrueMaximum_andExecutesExactly() public {
        (Leg[][] memory g, uint256[] memory floors) = _group();
        CycleSolver solver = new CycleSolver(_v());
        uint256 g0 = gasleft();
        Plan memory p = solver.solveMany(g, floors, 0, 10000, address(0), bytes32(0));
        emit log_named_uint("solveMany gas", g0 - gasleft());
        assertEq(Pools.cycleId(p.legs), Pools.cycleId(_legs()), "the cirBTC/WBTC cycle wins");
        uint256 profit = p.amountOut - p.amountIn;
        emit log_named_uint("plan profit", profit);
        assertEq(profit, TRUE_MAX, "the exact maximum of the n scan");
        (uint256 exact,) = LegProbe.cycleOut(_v(), p.legs, p.amountIn);
        assertEq(p.amountOut, exact, "plan exact");

        CycleExecutor ex = new CycleExecutor(_v());
        uint256 cb = block.coinbase.balance;
        ex.execute(p);
        assertEq(block.coinbase.balance - cb, profit, "coinbase delta == plan profit");
    }
}

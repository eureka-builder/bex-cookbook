// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Leg, Plan, Venues, NoProfit, BadLeg, V2, V3} from "./Types.sol";
import {Pools} from "./lib/Pools.sol";
import {LegSim} from "./lib/LegSim.sol";
import {ClosedForm} from "./lib/ClosedForm.sol";
import {Quote, RateFilter} from "./lib/RateFilter.sol";
import {InRange} from "./lib/InRange.sol";
import {StepEdge} from "./lib/StepEdge.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// Finds the input that maximises the net profit of a cycle of at least 2 legs, from pool state alone:
/// the profit less its floor, the larger of minProfitWei and weiPerGas times the modelled execute gas (_gas).
///
/// The builder calls `solve` (or `solveMany`) as the compute step of a BEX request, with a
/// staticcall. The returned Plan is the input of CycleExecutor.execute. The solver reads pool
/// storage and pool immutables only (no balances, no gas), so the builder can cache its result while
/// the pools it read do not change (SolverPurity.t.sol checks this).
///
/// Every pool is read once (RateFilter.quotes) and the reads are reused below. The steps:
///   1. Marginal-rate product rho > 1 in neither orientation (or a dead pool: rho = 0): NoProfit. A CL pool
///      with no active liquidity is not dead: its spot rate bounds rho, and the walk moves through its gap.
///   2. Only the reverse is live: solve the reversed legs and return them in the plan (the executor
///      runs Plan.legs), so a request covers both orientations of its pool set. The reversed legs are
///      quoted again (warm reads).
///   3. The closed form on the in-range virtual reserves gives x0 (ClosedForm). x0 = 0 (a leg with no active
///      liquidity, or a negligible arb): the walk.
///   4. x0 stays inside every leg's active range: its exact output (one swap step per leg, the pool's
///      own arithmetic, InRange) is the plan, with no LegSim pass. Its gas is the same at every input
///      in range, and the in-range profit bounds every input, so a plan below the floor means NoProfit.
///   5. Otherwise the region walk (_walk): from input 0, region by region between initialized ticks,
///      the closed form on the end state is exact inside a region. The candidate with the largest margin
///      over its own floor (step 7), checked with one exact LegSim swap, is the plan.
///   6. An in-range plan that clears the caller's floor moves to the best nearby step edge when an
///      intermediate token is coarse (StepEdge: one unit worth >= 2^32 wei, e.g. 8-decimal BTC), never to a
///      lower profit, and only to an edge where the whole cycle stays in range. A walk plan is not refined.
///   7. The plan's floor is the larger of minProfitWei and weiPerGas times the plan's modelled gas, at
///      least 1. A profit below it: NoProfit. A weiPerGas or minProfitWei of 2^128 or more: NoProfit.
/// The plan's minProfit is that floor, not the solved profit. `builderShareBps`, `recipient` and `tag`
/// are copied into the plan unchanged.
///
/// The solve has no internal gas cap: the builder caches only storage-pure computes, so the solver
/// cannot read the remaining gas. The walk first moves legs with no active liquidity through their gaps
/// (at most CYCLE_BUDGET + MAX_STEPS swap-loop steps). Per region it reads the bitmap words the region passes and
/// runs two resumed swap steps per leg, for at most MAX_REGIONS regions inside CYCLE_BUDGET, then up
/// to 3 exact LegSim swaps (the one that passes also prices the plan's gas). An in-range plan runs no walk
/// and no LegSim swap: StepEdge works on the quotes.
/// So the cost of a solve is bounded by construction: test_worstCaseWalk_underComputeCap measures the
/// worst case, 5 legs that walk to the budget through initialized ticks and empty bitmap words.
///
/// Groups: solveMany runs this solve over up to 8 cycles in one compute and returns the plan with the
/// largest margin over its own floor, so a 3-leg cycle with a higher gas floor does not win on gross
/// profit while it nets less. The plan is the same Plan the executor runs for a single cycle.
/// A cycle that reverts is skipped, not fatal to the group.
/// The compute pays for every cycle in the group: up to MAX_GROUP times the bound of one solve.
contract CycleSolver {
    /// Regions the walk enters (tick crossings it advances through), equal to LegSim.MAX_TICK_CROSSINGS, so
    /// that termination never rests on rounding.
    uint256 internal constant MAX_REGIONS = 32;
    /// Cycles per solveMany call.
    uint256 internal constant MAX_GROUP = 8;
    /// Growth of the least cross step after a step that crosses nothing: a stall through a coarse token
    /// takes about log16(coarse unit / step) regions, and a step overshoots by at most 16 times what it needed.
    uint256 internal constant BACKOFF = 16;

    /// The execute gas model (_gas): G0 + one base per leg + G_STEP per swap-loop step + G_CROSS more per
    /// initialized tick crossed. Fitted at FORK_BLOCK to `execute` as its own transaction (intrinsic gas and
    /// calldata included) plus the operator's 21,000-gas refill, in the order below. Test:
    /// test_gasModel_withinQuarterOfMeasured (GasModel.t.sol, run with --isolate), within 25% of each case.
    /// G_V3 + G_STEP: half the step from the in-range 3-leg to the in-range 5-leg plan (2 more V3 legs).
    uint256 internal constant G_V3 = 74_500;
    /// The rest of the in-range 2-leg V3 V3 plan: intrinsic gas, the refill, the flash and the payouts.
    uint256 internal constant G0 = 133_000;
    /// The empty-step corner (3 fresh V3 legs, 180 steps): the 177 steps past the first one per leg.
    uint256 internal constant G_STEP = 7300;
    /// The in-range 2-leg V3 V2 plan less G0, G_V3 and one step.
    uint256 internal constant G_V2 = 57_000;
    /// The in-range 3-leg V3 V4 V3 plan less G0, 2 * G_V3 and 3 steps.
    uint256 internal constant G_V4 = 95_000;
    /// The mixed corner on 5 legs (15 crossings of ticks with history, 75 steps). A fresh tick (first crossing,
    /// both fee slots written from zero) costs more: the model under-prices it, and the builder's own check of
    /// net > 0 at the real gas covers it.
    uint256 internal constant G_CROSS = 20_000;

    address private immutable V2_FACTORY;
    bytes32 private immutable V2_INIT_HASH;
    address private immutable V3_FACTORY;
    bytes32 private immutable V3_INIT_HASH;
    address private immutable POOL_MANAGER;
    address private immutable WETH;

    constructor(Venues memory v) {
        V2_FACTORY = v.v2Factory;
        V2_INIT_HASH = v.v2InitHash;
        V3_FACTORY = v.v3Factory;
        V3_INIT_HASH = v.v3InitHash;
        POOL_MANAGER = v.poolManager;
        WETH = v.weth;
    }

    function venues() external view returns (Venues memory) {
        return _venues();
    }

    function _venues() private view returns (Venues memory) {
        return Venues(V2_FACTORY, V2_INIT_HASH, V3_FACTORY, V3_INIT_HASH, POOL_MANAGER, WETH);
    }

    /// A point of the walk: its input and its search net, the walk's out - x (off the exact swap by the
    /// sub-swaps' rounding) less its floor there: the larger of minProfitWei and weiPerGas times the modelled
    /// gas. The same margin solveMany ranks plans by.
    struct Candidate {
        uint256 x;
        int256 net;
    }

    /// The caller's floor inputs (step 7), as the walk prices its points.
    struct Floor {
        uint256 minProfitWei;
        uint256 weiPerGas;
    }

    function solve(
        Leg[] calldata legs,
        uint256 minProfitWei,
        uint256 weiPerGas,
        uint16 builderShareBps,
        address recipient,
        bytes32 tag
    ) external view returns (Plan memory) {
        (uint256 x, uint256 out, uint256 floor, Leg[] memory l) = _solveOne(_venues(), legs, minProfitWei, weiPerGas);
        if (out <= x || out - x < floor) revert NoProfit();
        return Plan(x, out, floor, builderShareBps, recipient, tag, l);
    }

    /// The plan of the cycle with the largest margin over its own floor (amountOut - amountIn - minProfit,
    /// the floor of step 7 with minProfitWei[i]; ties: the first); NoProfit if no cycle clears its floor.
    /// 1 to MAX_GROUP cycles, one minProfitWei each, else BadLeg. A cycle that reverts for any reason (shape error, dead pool) is skipped.
    /// `catch {}` also catches out of gas: a cycle that runs out is skipped, so under gas pressure the order matters.
    function solveMany(
        Leg[][] calldata cycles,
        uint256[] calldata minProfitWei,
        uint256 weiPerGas,
        uint16 builderShareBps,
        address recipient,
        bytes32 tag
    ) external view returns (Plan memory best) {
        if (cycles.length == 0 || cycles.length > MAX_GROUP || cycles.length != minProfitWei.length) {
            revert BadLeg();
        }
        uint256 bestMargin;
        for (uint256 i; i < cycles.length; ++i) {
            // Each cycle runs as its own call, so a revert in one (bad shape, dead pool) skips only that cycle.
            try this.solve(cycles[i], minProfitWei[i], weiPerGas, builderShareBps, recipient, tag) returns (
                Plan memory p
            ) {
                uint256 margin = p.amountOut - p.amountIn - p.minProfit; // profit >= floor
                // A found plan always has legs: `best.legs.length == 0` means none yet.
                if (best.legs.length == 0 || margin > bestMargin) (bestMargin, best) = (margin, p);
            } catch {}
        }
        if (best.legs.length == 0) revert NoProfit();
    }

    /// The solve of one cycle: the plan's input, output, floor and legs. out <= x where no plan can clear
    /// the floor; shape errors revert.
    function _solveOne(Venues memory v, Leg[] memory l, uint256 minProfitWei, uint256 weiPerGas)
        private
        view
        returns (uint256 x, uint256 out, uint256 floor, Leg[] memory)
    {
        Pools.validate(v, l);
        // keeps weiPerGas * gas and the walk's int256 nets far from overflow; no profit reaches 2^128
        if (weiPerGas > type(uint128).max || minProfitWei > type(uint128).max) return (x, out, floor, l);
        Quote[] memory q = RateFilter.quotes(v, l);

        int8 dir = RateFilter.direction(q);
        if (dir == 0) return (0, 0, 0, l);
        if (dir < 0) {
            l = RateFilter.reverse(l);
            q = RateFilter.quotes(v, l);
        }

        x = _closedForm(q);
        uint160[] memory lim = InRange.limits(v, q);
        bool inRange;
        // x = 0: a leg with no active liquidity (zero virtual reserves), which only the walk moves through
        if (x != 0) (out, inRange) = InRange.cycleOut(q, lim, x);
        // In range, the constant-product model is the pool's own curve: x is the smooth optimum, and its gas
        // is the same at every input in range.
        // floor holds the walk plan's modelled gas until the floor is set: 0 when there is none yet
        if (!inRange) (x, out, floor) = _walk(v, l, q, Floor(minProfitWei, weiPerGas));
        // StepEdge never lowers the profit: below the caller's floor here, below it after.
        if (out <= x || out - x < minProfitWei) return (0, 0, 0, l);
        // An in-range plan moves to the best nearby step edge of a coarse intermediate token, and is priced
        // here. The walk's exact check priced its plan.
        if (inRange) {
            (x, out) = StepEdge.refine(q, lim, x, out);
            // StepEdge keeps the plan in range: one step per CL leg (counted in floor, 0 here), no crossing
            for (uint256 i; i < q.length; ++i) {
                if (!q[i].v2) ++floor;
            }
            floor = _gas(l, floor, 0);
        }
        // The floor: the caller's, weiPerGas times the plan's gas if more, never 0, so the executor always
        // demands a profit.
        floor *= weiPerGas;
        if (floor < minProfitWei) floor = minProfitWei;
        if (floor == 0) floor = 1;
        return (x, out, floor, l);
    }

    /// gas = G0 + the legs' bases + G_STEP * steps + G_CROSS * crossings (steps: swap-loop steps on the CL
    /// legs, a crossing step included).
    function _gas(Leg[] memory l, uint256 steps, uint256 crossings) private pure returns (uint256 g) {
        g = G0 + G_STEP * steps + G_CROSS * crossings;
        for (uint256 i; i < l.length; ++i) {
            uint8 ver = l[i].version;
            g += ver == V2 ? G_V2 : ver == V3 ? G_V3 : G_V4;
        }
    }

    function _closedForm(Quote[] memory q) private pure returns (uint256 x) {
        (uint256[] memory rin, uint256[] memory rout, uint256[] memory gamma) = _reserves(q);
        (x,) = ClosedForm.optimalInput(rin, rout, gamma);
    }

    function _reserves(Quote[] memory q)
        private
        pure
        returns (uint256[] memory rin, uint256[] memory rout, uint256[] memory gamma)
    {
        uint256 n = q.length;
        rin = new uint256[](n);
        rout = new uint256[](n);
        gamma = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            (rin[i], rout[i], gamma[i]) = RateFilter.virtualReserves(q[i]);
        }
    }

    /// Region walk for the crossing case. A region is an input interval where no CL leg crosses an
    /// initialized tick: every leg is a constant-product curve there, so the closed form on the end-state
    /// quotes is the exact in-region optimum. rho is continuous in x and decreases (profit is concave), so
    /// the walk only moves forward, from x = 0. In each region:
    ///   - dxStar = the closed form on the ends. It is 0 when rho <= 1 or a leg has no liquidity left: the
    ///     walk ends at the region's start.
    ///   - dxB = the added input at which the region ends (_boundary): a CL leg reaches its next
    ///     initialized tick, or the next word end would pass the budget.
    ///   - dxStar <= dxB: the optimum is inside the region. It is the last candidate.
    ///   - else pre, the point just before the boundary, is a candidate, and the walk crosses to post + 1,
    ///     post the same distance past the boundary (_boundary). dxB is approximate, and each sub-swap loses
    ///     up to one unit per leg to rounding, so the step goes past the tick. Crossing a little past it is
    ///     harmless: the next region's closed form takes over. After a step that reaches no boundary
    ///     (rounding through a coarse token ate it), every later step is at least BACKOFF times it.
    /// An advance that would pass CYCLE_BUDGET, MAX_STEPS or MAX_TICK_CROSSINGS (an exhausted leg too)
    /// stops the walk; the point before it stands. At most MAX_REGIONS regions. The plan is the candidate
    /// with the best search net (out - x less its floor, max(minProfitWei, weiPerGas times its gas from its
    /// steps and crossings): gas jumps at each crossing, so a crossing that adds less than it costs is not
    /// taken, and a point below minProfitWei never beats one above it) whose exact swap is
    /// feasible, trying at most 2 earlier candidates after it, and its modelled gas from that exact swap;
    /// (0, 0, 0) if none is.
    /// A leg with no active liquidity at the start first moves through its gap (advance by 0), as the exact
    /// swap of any input does.
    function _walk(Venues memory v, Leg[] memory l, Quote[] memory q, Floor memory f)
        private
        view
        returns (uint256 x, uint256 out, uint256 gas)
    {
        LegSim.Walk memory w = LegSim.startWalk(q);
        if (!LegSim.advance(v, l, w, 0)) return (0, 0, 0);
        // c[k]: region k's start, replaced by its in-region optimum or the point just before its boundary
        Candidate[MAX_REGIONS + 1] memory c;
        // The least cross step: 0 until a step reaches no boundary (rounding through a coarse token ate it),
        // then BACKOFF times that step, and kept after a step that crosses.
        uint256 back;
        uint256 k;
        for (;; ++k) {
            c[k] = _point(w, l, f);
            if (k == MAX_REGIONS) break;
            uint256 pre;
            uint256 post;
            {
                // rho <= 1 (or a leg exhausted) gives dxStar = 0: the walk ends here
                uint256 dxStar = _closedForm(w.ends);
                uint256 dxB;
                // 2k advances so far: each can leave a leg up to a unit of its input behind one exact swap of w.x
                (dxB, pre, post) = _boundary(v, w, dxStar, 2 * k + 1);
                // the optimum is inside the region: the last candidate
                if (dxStar <= dxB) {
                    if (LegSim.advance(v, l, w, dxStar)) c[k] = _point(w, l, f);
                    break;
                }
            }
            if (!LegSim.advance(v, l, w, pre)) break;
            c[k] = _point(w, l, f);
            uint256 u = LegSim.units(w);
            // Post out of reach, or a step past any closed-form input (dxStar < 2^128): the walk ends. The bound
            // keeps post - pre + 1, BACKOFF * step and the int256 of advance's swap amount in range.
            if (post > type(uint128).max) break;
            // + 1: the model's inverse is at most the real input, and post == pre where one input unit buys
            // more than 2 * lag units of the leg's input
            uint256 step = post - pre + 1;
            if (step < back) step = back;
            if (step > type(uint128).max) break;
            if (!LegSim.advance(v, l, w, step)) break;
            if (LegSim.units(w) == u) back = BACKOFF * step;
        }
        return _confirm(v, l, c, k + 1);
    }

    /// The exact check of the first n candidates: the best, else the best before it, at most 2 fallbacks. Its
    /// input, exact output and modelled gas (from the steps and crossings of that swap); (0, 0, 0) if none is
    /// feasible. It checks feasibility, not the net again: the exact swap pays at least the walk's sub-swaps
    /// (they each round down) and _boundary's lag keeps it before the walk's next tick, so its net is at least
    /// the search net (the optimality audit's 50 walk plans: never below).
    function _confirm(Venues memory v, Leg[] memory l, Candidate[MAX_REGIONS + 1] memory c, uint256 n)
        private
        view
        returns (uint256, uint256, uint256)
    {
        for (uint256 tries; tries < 3 && n > 0; ++tries) {
            uint256 i;
            for (uint256 j = 1; j < n; ++j) {
                if (c[j].net > c[i].net) i = j;
            }
            (uint256 out, uint8 crossings, uint8 steps, bool ok) = LegSim.tryCycleOut(v, l, c[i].x);
            if (ok) return (c[i].x, out, _gas(l, steps, crossings));
            n = i;
        }
    }

    /// dxB: the added input at which the walk's region ends, pre: the input `lag` units of leg input plus
    /// y / 1e9 before it, so that one exact swap of the walk's x + pre stays before the boundary, and post:
    /// the input as far past it (type(uint256).max: out of reach).
    /// Every CL leg's boundaries (LegSim.nextBoundary) map to cycle input: the leg input to reach one (InRange.inputTo)
    /// through the inverse of legs 0..j-1 (ClosedForm.fold, ClosedForm.inverse). The legs are scanned
    /// together in that order, so only the words the region passes are read. The region ends at the first
    /// initialized tick, at the word end that would pass the budget (CYCLE_BUDGET over all legs, MAX_STEPS
    /// on one), or at dxStar or beyond (then dxB >= dxStar).
    function _boundary(Venues memory v, LegSim.Walk memory w, uint256 dxStar, uint256 lag)
        private
        view
        returns (uint256 dxB, uint256 pre, uint256 post)
    {
        (uint256[] memory rin, uint256[] memory rout, uint256[] memory g) = _reserves(w.ends);
        Scan[] memory s = new Scan[](rin.length);
        for (uint256 j; j < rin.length; ++j) {
            Scan memory m = s[j];
            m.x = type(uint256).max;
            if (w.ends[j].v2) continue;
            (m.a, m.b, m.c) = ClosedForm.fold(rin, rout, g, j);
            (m.tick, m.steps) = (w.ends[j].tick, w.boundaries[j]);
            _scan(v, w.ends[j], m);
        }
        uint256 rem = LegSim.CYCLE_BUDGET - LegSim.units(w);
        for (;;) {
            uint256 j;
            for (uint256 i = 1; i < s.length; ++i) {
                if (s[i].x < s[j].x) j = i;
            }
            Scan memory m = s[j];
            dxB = m.x;
            if (m.end || dxB >= dxStar || rem == 0 || m.steps >= LegSim.MAX_STEPS - 1) {
                // at large reserves the exact swap of x + pre reaches further than the walk's sub-swaps by more
                // than lag (test_worstCaseWalk_underComputeCap)
                lag += m.y / 1e9;
                pre = ClosedForm.inverse(m.a, m.b, m.c, m.y > lag ? m.y - lag : 0);
                // m.y < 2^213 (the amount delta of a uint128 liquidity, grossed up by the fee): no overflow
                post = ClosedForm.inverse(m.a, m.b, m.c, m.y + lag);
                return (dxB, pre, post);
            }
            // an empty word end before the region's end: one budget unit (rem > 0, steps < MAX_STEPS)
            unchecked {
                --rem;
                ++m.steps;
            }
            _scan(v, w.ends[j], m);
        }
    }

    /// One CL leg's scan: its next boundary, the leg input y and the cycle input x to reach it
    /// (type(uint256).max: out of reach), the fold of the legs before it, its boundaries so far, and end:
    /// the boundary is an initialized tick or the end of the price range, where the region ends.
    struct Scan {
        int24 tick;
        uint256 y;
        uint256 x;
        uint256 a;
        uint256 b;
        uint256 c;
        uint256 steps;
        bool end;
    }

    /// Moves s to the leg's next boundary.
    function _scan(Venues memory v, Quote memory e, Scan memory s) private view {
        int24 next;
        (next, s.end) = LegSim.nextBoundary(v, e, s.tick);
        unchecked {
            s.tick = e.zfo ? next - 1 : next; // next >= MIN_TICK
        }
        s.y = InRange.inputTo(e, TickMath.getSqrtPriceAtTick(next));
        s.x = ClosedForm.inverse(s.a, s.b, s.c, s.y);
    }

    /// The walk's point and its net. units = steps + W_CROSS * crossings (LegSim.units).
    function _point(LegSim.Walk memory w, Leg[] memory l, Floor memory f) private pure returns (Candidate memory) {
        uint256 crossings;
        // uint16 counters, units >= W_CROSS * crossings, weiPerGas and minProfitWei < 2^128 and the gas of a
        // budgeted swap is far below 2^64: no overflow
        unchecked {
            for (uint256 i; i < w.crossings.length; ++i) {
                crossings += w.crossings[i];
            }
            uint256 cost = f.weiPerGas * _gas(l, LegSim.units(w) - LegSim.W_CROSS * crossings, crossings);
            if (cost < f.minProfitWei) cost = f.minProfitWei;
            return Candidate(w.x, int256(w.out) - int256(w.x) - int256(cost));
        }
    }
}

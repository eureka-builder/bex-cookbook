// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Leg, V2, V3, Venues} from "../Types.sol";
import {Pools} from "./Pools.sol";
import {Snapshot, V3Reader} from "./V3Reader.sol";
import {V4Reader} from "./V4Reader.sol";
import {V2Reader} from "./V2Reader.sol";
import {Quote, RateFilter} from "./RateFilter.sol";

/// Exact leg output at current storage: the Uniswap swap loop, wei for wei.
///
/// The solver uses it where the closed form is not exact: the region walk (Walk, advance) when a leg
/// crosses a tick, and the exact check of the walk's result (tryCycleOut). Every probe is bounded by
/// one cycle-wide gas budget (CYCLE_BUDGET), so that `execute` of a plan stays under the builder's 2M
/// gas limit in the measured worst cases.
library LegSim {
    using V4Reader for IPoolManager;

    uint8 internal constant MAX_TICK_CROSSINGS = 32;
    /// Per-leg loop iterations (crossing or not), so empty bitmap words cannot make a probe unbounded.
    uint8 internal constant MAX_STEPS = 128;

    /// One cycle-wide gas budget, in units summed over the legs: one per swap-loop step (crossing or
    /// not), W_CROSS more per initialised tick crossed. A cycle past it is infeasible, so the solver
    /// returns the best input that fits. An empty step still reads a cold bitmap word and runs the swap
    /// math in `execute` (~8k gas); a crossing also reads and writes the tick (~25k, ~59k for a fresh
    /// tick: initialised above the price and never crossed, so both feeGrowthOutside slots go from zero).
    /// Measured, not guaranteed: the worst `execute` found at this budget. Calibrated with
    /// `forge test --isolate` (each call its own transaction: cold slots, real SSTORE prices) at
    /// FORK_BLOCK at optimizer_runs 319, as the gas `execute` uses at the budget (both cost ~7k gas per unit,
    /// hence W_CROSS = 7):
    ///   empty steps only (test_cycleBudget_emptySteps_*, fresh pools, so each first swap also writes its
    ///   fee growth from zero: on the high side): 3 legs 1,647,877, 5 legs 1,834,861
    ///   fresh-tick crossings only (test_freshTick_*): 3 legs, 22 crossings 1,656,951; 5 legs, 21: 1,772,021
    ///   mixed, ticks with history (test_cycleBudget_executeUnder2M): 5 legs 1,353,978, 3 legs 1,238,440
    ///   with an earlier build (optimizer_runs 1000, 0.4% to 0.5% less gas), at 150 the same corners were
    ///   1,424,539 / 1,610,810, 1,418,401 / 1,588,135; at 200 the 5-leg empty-step corner was 1,972,961.
    uint8 internal constant W_CROSS = 7;
    uint16 internal constant CYCLE_BUDGET = 180;

    /// Non-reverting probe: feasible = false when a leg exceeds MAX_TICK_CROSSINGS or MAX_STEPS, or the
    /// legs together exceed CYCLE_BUDGET. `crossings` and `steps` (swap-loop steps) are totals over
    /// all legs; the budget cost of the swap is W_CROSS * crossings + steps.
    function tryCycleOut(Venues memory v, Leg[] memory legs, uint256 amountIn)
        internal
        view
        returns (uint256 out, uint8 crossings, uint8 steps, bool feasible)
    {
        out = amountIn;
        uint256 cost;
        for (uint256 i; i < legs.length; ++i) {
            uint8 c;
            uint8 s;
            (out, c, s, feasible) = legOut(v, legs[i], out);
            crossings += c; // at most CYCLE_BUDGET / W_CROSS + MAX_TICK_CROSSINGS: no overflow
            cost += uint256(W_CROSS) * c + s;
            if (!feasible || cost > CYCLE_BUDGET) return (0, 0, 0, false);
            steps += s; // at most cost <= CYCLE_BUDGET: no overflow
        }
        feasible = true;
    }

    /// Output, initialized ticks crossed and swap-loop steps (crossing or not) of one leg; ok = false past
    /// MAX_TICK_CROSSINGS or MAX_STEPS.
    function legOut(Venues memory v, Leg memory leg, uint256 amountIn)
        internal
        view
        returns (uint256 out, uint8 crossings, uint8 steps, bool ok)
    {
        if (leg.version == V2) {
            // a leg receives what the previous leg sent. Through a transfer-tax token less
            // arrives, so the plan's amountOut is nominal and `execute` (which funds each leg with
            // what arrived) reverts ProfitBelowPlan: no loss, but the cycle never lands. Such
            // cycles are kept out of cycles.toml (EXCLUDED_TOKENS in cycles/build.py); simulating
            // the tax would need the token's rules.
            (uint256 rin, uint256 rout) =
                V2Reader.reserves(Pools.v2Pair(v, leg.tokenIn, leg.tokenOut), Pools.zeroForOne(leg));
            return (V2Reader.amountOut(amountIn, rin, rout), 0, 0, true);
        }
        (Loop memory l, bool clOk) = _clSwap(v, leg, amountIn);
        return (l.out, l.crossings, l.steps, clOk);
    }

    /// A cycle swap grown in pieces: each `advance` adds input and every leg resumes its swap from its
    /// end state, so the work is the boundaries passed, not one full swap per probe. Each sub-swap can
    /// round a leg up to one unit of its token below one swap of the total: `out` is a search value, not
    /// a plan's amountOut.
    struct Walk {
        Quote[] ends; // per leg, the state after the cycle input x (copies, start quotes untouched)
        uint16[] boundaries; // per leg: swap-loop boundaries reached (word ends + initialized ticks)
        uint16[] crossings; // per leg: initialized ticks crossed
        uint256 x; // cycle input so far
        uint256 out; // cycle output so far
    }

    function startWalk(Quote[] memory q) internal pure returns (Walk memory w) {
        w.ends = new Quote[](q.length);
        for (uint256 i; i < q.length; ++i) {
            w.ends[i] = _copy(q[i]);
        }
        w.boundaries = new uint16[](q.length);
        w.crossings = new uint16[](q.length);
    }

    /// Adds dx to the cycle input: every leg continues from its end state. A V2 end keeps the effective
    /// reserves (rin + 0.997 * in, rout - out), so the next sub-swap follows the single-swap curve. A CL
    /// leg whose liquidity is 0 after its input is used up (or at the start, with dx = 0) moves through the
    /// gap to its next initialized tick and crosses it, as the real swap does with any more input. Returns
    /// false (the caller discards w) when a leg would pass MAX_STEPS or MAX_TICK_CROSSINGS or the cycle would
    /// pass CYCLE_BUDGET by `units`, checked after every leg: one advance runs at most CYCLE_BUDGET +
    /// MAX_STEPS swap-loop steps.
    function advance(Venues memory v, Leg[] memory legs, Walk memory w, uint256 dx)
        internal
        view
        returns (bool feasible)
    {
        uint256 legIn = dx;
        uint256 u; // units(w) of the legs advanced so far
        for (uint256 i; i < legs.length; ++i) {
            Quote memory e = w.ends[i];
            if (e.v2) {
                uint256 o = V2Reader.amountOut(legIn, e.rin, e.rout);
                e.rin += legIn * 997 / 1000;
                e.rout -= o;
                legIn = o;
                continue;
            }
            Pool memory p = Pool(legs[i].version == V3, IPoolManager(v.poolManager), e.v3Pool, e.v4Id, e.tickSpacing);
            // a feasible walk keeps boundaries < MAX_STEPS and crossings <= MAX_TICK_CROSSINGS: both fit uint8
            uint8 b = uint8(w.boundaries[i]);
            Loop memory l = Loop(e.sqrtPriceX96, e.tick, e.liquidity, -int256(legIn), 0, uint8(w.crossings[i]), b, b);
            if (!_run(p, l, e.zfo, e.fee, true) || l.boundaries >= MAX_STEPS) return false;
            (e.sqrtPriceX96, e.tick, e.liquidity) = (l.sqrtPrice, l.tick, l.liquidity);
            (w.boundaries[i], w.crossings[i]) = (l.boundaries, l.crossings);
            u += uint256(l.boundaries) + 1 + uint256(W_CROSS) * l.crossings;
            if (u > CYCLE_BUDGET) return false;
            legIn = l.out;
        }
        w.x += dx;
        w.out += legIn;
        return true; // u == units(w) <= CYCLE_BUDGET
    }

    /// An upper bound on the budget cost of one exact swap of w.x: sum over CL legs of boundaries + 1 +
    /// W_CROSS * crossings. More than that swap's cost by 1 on a leg that ends exactly on a boundary, and
    /// by the units of any gap move of `advance`.
    function units(Walk memory w) internal pure returns (uint256 u) {
        for (uint256 i; i < w.ends.length; ++i) {
            // uint16 counters over at most 8 legs: no overflow
            unchecked {
                if (!w.ends[i].v2) u += uint256(w.boundaries[i]) + 1 + uint256(W_CROSS) * w.crossings[i];
            }
        }
    }

    /// One swap-loop boundary of e's pool past `tick` in e's swap direction, as the swap loop finds it (one
    /// bitmap word): the next initialized tick or the end of the word. edge = true at an initialized tick or
    /// at the end of the price range, where a region ends. The loop's tick after it is `zfo ? next - 1 : next`.
    function nextBoundary(Venues memory v, Quote memory e, int24 tick) internal view returns (int24 next, bool edge) {
        Pool memory p = Pool(e.v3Pool != address(0), IPoolManager(v.poolManager), e.v3Pool, e.v4Id, e.tickSpacing);
        (next, edge) = _next(p, tick, e.zfo);
        if (next <= TickMath.MIN_TICK) return (TickMath.MIN_TICK, true);
        if (next >= TickMath.MAX_TICK) return (TickMath.MAX_TICK, true);
    }

    /// Memory structs assign by reference: copy the fields so the start quotes stay intact.
    function _copy(Quote memory q) private pure returns (Quote memory c) {
        // Quote is 12 static fields: 12 words in memory. A new Quote field must change the 384.
        assembly ("memory-safe") {
            c := mload(0x40)
            mstore(0x40, add(c, 384))
            mcopy(c, q, 384)
        }
    }

    /// Resolved once per leg: where to read and the pool's own parameters.
    struct Pool {
        bool v3;
        IPoolManager pm;
        address v3Pool;
        PoolId v4Id;
        int24 spacing;
    }

    function _pool(Venues memory v, Leg memory leg) private pure returns (Pool memory p) {
        if (leg.version == V3) {
            p.v3 = true;
            p.v3Pool = Pools.v3Pool(v, leg.tokenIn, leg.tokenOut, leg.fee);
        } else {
            p.pm = IPoolManager(v.poolManager);
            p.v4Id = Pools.v4Id(Pools.v4Key(leg));
        }
    }

    /// Pool state with the effective swap fee. V3 takes spacing from the pool itself; V4 spacing is in the key.
    function _snapshot(Leg memory leg, Pool memory p) private view returns (Snapshot memory s) {
        if (p.v3) {
            s = V3Reader.snapshot(p.v3Pool);
        } else {
            // V4 swaps at the combined LP + protocol fee for the swap direction (Pool.swap).
            uint24 protocolFee;
            (s.sqrtPriceX96, s.tick, protocolFee,) = p.pm.getSlot0(p.v4Id);
            s.liquidity = p.pm.getLiquidity(p.v4Id);
            s.tickSpacing = leg.tickSpacing;
            uint16 pf = Pools.zeroForOne(leg)
                ? ProtocolFeeLibrary.getZeroForOneFee(protocolFee)
                : ProtocolFeeLibrary.getOneForZeroFee(protocolFee);
            s.fee = RateFilter.v4Fee(pf, leg.fee);
        }
        p.spacing = s.tickSpacing;
    }

    function _next(Pool memory p, int24 tick, bool zfo) private view returns (int24 next, bool init) {
        if (p.v3) return V3Reader.nextInitializedTick(p.v3Pool, tick, p.spacing, zfo);
        return V4Reader.nextInitializedTick(p.pm, p.v4Id, tick, p.spacing, zfo);
    }

    function _net(Pool memory p, int24 tick) private view returns (int128) {
        if (p.v3) return V3Reader.liquidityNet(p.v3Pool, tick);
        return V4Reader.liquidityNet(p.pm, p.v4Id, tick);
    }

    struct Loop {
        uint160 sqrtPrice;
        int24 tick;
        uint128 liquidity;
        int256 remaining;
        uint256 out;
        uint8 crossings;
        uint8 steps; // loop iterations
        uint8 boundaries; // iterations that ended on their next tick (all but a last partial one)
    }

    /// Exact-input V3/V4 swap loop from the pool's current state.
    function _clSwap(Venues memory v, Leg memory leg, uint256 amountIn) private view returns (Loop memory l, bool ok) {
        Pool memory p = _pool(v, leg);
        Snapshot memory s = _snapshot(leg, p);
        l = Loop(s.sqrtPriceX96, s.tick, s.liquidity, -int256(amountIn), 0, 0, 0, 0);
        ok = _run(p, l, Pools.zeroForOne(leg), s.fee, false);
    }

    /// The swap loop from the state in `l`. With `gap`, it goes on after the input is used up while the
    /// liquidity is 0: with no input and no liquidity a step moves the price to its target for free
    /// (fee 0 keeps computeSwapStep away from its exact-output fee division).
    function _run(Pool memory p, Loop memory l, bool zfo, uint24 fee, bool gap) private view returns (bool) {
        uint160 limit = zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        while ((l.remaining != 0 || (gap && l.liquidity == 0)) && l.sqrtPrice != limit) {
            if (l.steps == MAX_STEPS) return false;
            ++l.steps;
            if (!_step(p, l, zfo, limit, l.remaining == 0 ? 0 : fee)) return false;
        }
        return true;
    }

    /// One computeSwapStep; folds the result into the loop state and returns the new price.
    function _compute(Loop memory l, uint160 target, uint24 fee) private pure returns (uint160 price) {
        uint256 stepIn;
        uint256 stepOut;
        uint256 stepFee;
        (price, stepIn, stepOut, stepFee) = SwapMath.computeSwapStep(l.sqrtPrice, target, l.liquidity, l.remaining, fee);
        l.sqrtPrice = price;
        l.remaining += int256(stepIn + stepFee);
        l.out += stepOut;
    }

    function _step(Pool memory p, Loop memory l, bool zfo, uint160 limit, uint24 fee) private view returns (bool) {
        (int24 next, bool init) = _next(p, l.tick, zfo);
        if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
        else if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
        uint160 sqrtNext = TickMath.getSqrtPriceAtTick(next);

        uint160 start = l.sqrtPrice;
        uint160 price = _compute(l, SwapMath.getSqrtPriceTarget(zfo, sqrtNext, limit), fee);

        if (price == sqrtNext) {
            ++l.boundaries;
            if (init) {
                if (l.crossings == MAX_TICK_CROSSINGS) return false;
                ++l.crossings;
                int128 net = _net(p, next);
                if (zfo) net = -net;
                l.liquidity = net < 0 ? l.liquidity - uint128(-net) : l.liquidity + uint128(net);
            }
            l.tick = zfo ? next - 1 : next;
        } else if (price != start) {
            l.tick = TickMath.getTickAtSqrtPrice(price);
        }
        return true;
    }
}

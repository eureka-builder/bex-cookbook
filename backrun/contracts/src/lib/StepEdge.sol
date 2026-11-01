// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {InRange} from "./InRange.sol";
import {Quote} from "./RateFilter.sol";

/// Step-edge refinement of a solved input x: it moves x to the input where the rounding of a
/// coarse token pays the most, as below.
///
/// With a coarse intermediate token (cirBTC, WBTC: 8 decimals, one unit ~3e11 wei) the profit is a
/// sawtooth in x, two roundings of up to one unit each:
///   1. The leg that produces the coarse amount n floors it. For a given n the cheapest input is the
///      smallest x that reaches n (the step's left edge); every x above it pays more for the same n.
///   2. The leg that consumes n floors its fee: lessFee = n - ceil(n * fee / 1e6). Inside one fee unit
///      lessFee rises 1:1 with n, so profit ramps up to the last n of the fee unit and drops one unit after.
/// So the best inputs are the left edges of the fee-unit ends. The smooth optimum x (the closed form: the
/// solver refines in-range plans only) sits between them. This takes the nearer fee-unit end E around the
/// coarse amount at x, ranks E, E-1, .. E-SCAN+1 (a finer token in front, e.g. USDC, adds a +-1 unit noise
/// to each edge), and returns the exact left edge of the best one if its exact profit beats x. Never lower
/// than x.
/// Pure math on the solve's quotes. Edges are inverted with the pool's exact-output formula and checked
/// with the exact-input step (InRange.stepOut), so the plan stays the pool's own arithmetic.
/// A candidate counts only if the whole cycle stays in range at its input (InRange.limits), so the plan
/// is in range and its gas is the in-range gas: inverting or confirming a crossing leg would need LegSim.
///
/// Two adjacent coarse legs: when
/// leg k + 1 turns the coarse amount into another coarse amount m (cirBTC -> WBTC), the profit falls inside
/// each run of m(n + 1) = m(n) + 1 and jumps one m unit where m skips an amount. One more candidate: the
/// first m of that run below the nearer fee-unit end of leg k + 2, found by bisection on the pool's
/// exact-output step (14 pure probes), then the same exact left edge, one leg further.
/// only a coarse token feeding a coarse output (rate >= 1); the mirror (a coarse token in front
/// of the coarsest one) keeps the plan above. It needs the same search for the END of the run.
library StepEdge {
    uint256 internal constant PIPS = 1e6;
    /// Refine only when one unit of the coarsest intermediate is worth >= 2^32 wei: x >= amount << 32.
    /// cirBTC / WBTC (~3e11 wei a unit) pass; USDC / USDT (~2.5e8 wei) and 18-decimal tokens skip, so
    /// their solves pay only the prefix pass.
    uint256 internal constant UNIT_SHIFT = 32;
    /// Coarse amounts ranked below the fee-unit end when a finer token precedes the coarse one.
    uint256 internal constant SCAN = 6;
    /// Amounts above this are not refined (keeps every product below 2^256).
    uint256 internal constant MAX_AMOUNT = 1 << 120;
    /// Two coarse legs: the run start is searched in (E - 2^RAMP_BITS, E]. A run is 1 / (rate - 1) amounts
    /// (about 635 for cirBTC -> WBTC); a longer one is not searched.
    uint256 internal constant RAMP_BITS = 12;

    function refine(Quote[] memory q, uint160[] memory lim, uint256 x, uint256 out)
        internal
        pure
        returns (uint256, uint256)
    {
        (uint256 k, uint256 yk, uint256 e, uint256 t) = _candidates(q, lim, x);
        if (k == q.length) return (x, out);
        (uint256 xc, uint256 oc, bool found) = _edge(q, lim, k, e);
        // The fee-unit end is out of range or loses to x: the left edge of the step x is on (never above x).
        if (!(found && oc > xc && oc - xc > out - x) && e != yk) (xc, oc, found) = _edge(q, lim, k, yk);
        if (found && oc > xc && oc - xc > out - x) (x, out) = (xc, oc);
        // Two adjacent coarse legs: the left edge of the run start if it beats the best so far.
        if (t != 0) {
            (xc, oc, found) = _edge(q, lim, k + 1, t);
            if (found && oc > xc && oc - xc > out - x) return (xc, oc);
        }
        return (x, out);
    }

    /// The gate and the pure targets: coarsest leg k (k = q.length: no refinement), its amount yk at x,
    /// the coarse amount e to try, and t, the run start on leg k + 1's output (0: none).
    function _candidates(Quote[] memory q, uint160[] memory lim, uint256 x)
        private
        pure
        returns (uint256 k, uint256 yk, uint256 e, uint256 t)
    {
        uint256 yin;
        (k, yk, yin) = _coarsest(q, lim, x);
        if (k == q.length || yk <= SCAN || yk > x >> UNIT_SHIFT || x > MAX_AMOUNT) return (q.length, 0, 0, 0);
        e = _target(q, lim, k, yk, x, yin);
        t = _rampStart(q, lim, k, yk, x);
    }

    /// Leg k + 1 (CL, in range) outputs m from the coarse yk, and m is coarse too. E is the nearer fee-unit
    /// end of leg k + 2 around m. With lf(T) the input less fee for output T (the pool's exact-output step),
    /// D(T) = T - lf(T) does not decrease and steps up where m skips an amount. Returns the first T of D's
    /// plateau that holds E: from there up to E every T costs one more input unit for one output unit, so
    /// the profit falls (0: none). lf, not the gross input: leg k + 1's fee floor would make D step down.
    function _rampStart(Quote[] memory q, uint160[] memory lim, uint256 k, uint256 yk, uint256 x)
        internal
        pure
        returns (uint256)
    {
        if (k + 2 >= q.length || q[k + 1].v2) return 0;
        Quote memory c = q[k + 1];
        (uint256 m, bool ok) = InRange.stepOut(c, lim[k + 1], yk);
        // m >= yk > SCAN here (leg k + 1 gives at least one unit out per unit in); the guard keeps
        // _feeUnitEnd and the span arithmetic safe if that changes.
        if (!ok || m <= SCAN || m > x >> UNIT_SHIFT) return 0;
        uint256 hi = _feeUnitEnd(q[k + 2], m);
        if (hi <= 1 << RAMP_BITS || hi >= _maxOut(c, lim[k + 1])) return 0;
        uint256 lf = _lessFeeIn(c, hi);
        if (lf >= hi) return 0; // rate below 1: not this case
        uint256 d = hi - lf;
        uint256 lo = hi - (1 << RAMP_BITS);
        if (lo >= d + _lessFeeIn(c, lo)) return 0; // no skip within the span
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) >> 1;
            if (mid >= d + _lessFeeIn(c, mid)) hi = mid;
            else lo = mid;
        }
        return hi;
    }

    /// The left edge xc of coarse amount e (the smallest input whose leg k outputs e) and its exact output;
    /// found = false unless every leg stays in range at xc.
    function _edge(Quote[] memory q, uint160[] memory lim, uint256 k, uint256 e)
        private
        pure
        returns (uint256 xc, uint256 oc, bool found)
    {
        bool onEdge;
        (xc, found, onEdge) = _minInput(q, lim, k, e);
        if (!found) return (0, 0, false);
        // Legs 0..k at xc output exactly the confirmed amounts: only the tail is left to run.
        (oc, found) = onEdge ? _tail(q, lim, k + 1, e) : InRange.cycleOut(q, lim, xc);
    }

    /// The smallest intermediate amount on the in-range prefix at x: leg k outputs yk from yin.
    /// k = q.length if leg 0 already leaves its range.
    function _coarsest(Quote[] memory q, uint160[] memory lim, uint256 x)
        internal
        pure
        returns (uint256 k, uint256 yk, uint256 yin)
    {
        k = q.length;
        yk = type(uint256).max;
        uint256 y = x;
        for (uint256 i; i + 1 < q.length; ++i) {
            uint256 a = y;
            bool ok;
            (y, ok) = InRange.stepOut(q[i], lim[i], a);
            if (!ok) break;
            if (y < yk) (k, yk, yin) = (i, y, a);
        }
    }

    /// The coarse amount to put the plan's edge at: the consumer's nearer fee-unit end, then (a finer
    /// token in front, the tail in range) the best ranked amount just below it.
    function _target(Quote[] memory q, uint160[] memory lim, uint256 k, uint256 yk, uint256 x, uint256 yin)
        private
        pure
        returns (uint256 e)
    {
        e = _feeUnitEnd(q[k + 1], yk);
        if (k == 0 || e <= SCAN) return e;
        (uint256 he, bool tailIn) = _tail(q, lim, k + 1, e);
        if (tailIn) e = _scan(q[k], lim[k], e, he / e, x, yin);
    }

    /// The nearer end of the consumer's fee unit around n (the last amount before ceil(n * fee / 1e6) steps
    /// up, above or below n); n itself if the consumer has no fee floor (V2, fee 0). For a consumer that
    /// crosses a tick the fee units start elsewhere: still a valid candidate, the exact check decides.
    function _feeUnitEnd(Quote memory c, uint256 n) private pure returns (uint256) {
        if (c.v2 || c.fee == 0) return n;
        uint256 m = (n * c.fee + PIPS - 1) / PIPS;
        uint256 hi = m * PIPS / c.fee;
        uint256 lo = (m - 1) * PIPS / c.fee;
        return (lo < 2 || hi - n <= n - lo) ? hi : lo;
    }

    /// Output of legs from..n-1 for input y, and whether every one stays in range.
    function _tail(Quote[] memory q, uint160[] memory lim, uint256 from, uint256 y)
        private
        pure
        returns (uint256, bool ok)
    {
        for (uint256 i = from; i < q.length; ++i) {
            (y, ok) = InRange.stepOut(q[i], lim[i], y);
            if (!ok) return (0, false);
        }
        return (y, true);
    }

    /// Ranks e - j (j < SCAN) by the cost of leg k's (unchecked) minimal input for it, priced at x / yin
    /// wei per unit, plus j units of the tail at `unit` wei each (the tail is linear in the coarse amount
    /// inside one fee unit). The finer token in front of leg k rounds each edge by up to a unit of its own.
    /// average rates stand in for marginal ones (ranking only: the final edge is exact and must
    /// beat x). Roundings before leg k are not ranked.
    function _scan(Quote memory c, uint160 lim, uint256 e, uint256 unit, uint256 x, uint256 yin)
        private
        pure
        returns (uint256 best)
    {
        best = e;
        if (!c.v2 && e >= _maxOut(c, lim)) return e;
        uint256 bestCost = type(uint256).max;
        for (uint256 j; j < SCAN; ++j) {
            (uint256 a, bool ok) = _legMinIn(c, e - j);
            if (!ok || a > MAX_AMOUNT) continue;
            uint256 cost = FullMath.mulDiv(a, x, yin) + j * unit;
            if (cost < bestCost) (bestCost, best) = (cost, e - j);
        }
    }

    /// The smallest x whose legs 0..k output at least t, every leg in range; (0, false) if none is.
    /// onEdge: each leg outputs exactly the next leg's input (and leg k exactly t), so the forward pass
    /// from x reproduces them.
    function _minInput(Quote[] memory q, uint160[] memory lim, uint256 k, uint256 t)
        private
        pure
        returns (uint256, bool ok, bool onEdge)
    {
        onEdge = true;
        for (uint256 i = k + 1; i > 0; --i) {
            Quote memory c = q[i - 1];
            if (!c.v2 && t >= _maxOut(c, lim[i - 1])) return (0, false, false);
            uint256 a;
            (a, ok) = _legMinIn(c, t);
            if (!ok || a > MAX_AMOUNT) return (0, false, false);
            // Confirm with the exact-input step; the exact-output inverse can sit a unit under it.
            uint256 o;
            (o, ok) = InRange.stepOut(c, lim[i - 1], a);
            for (uint256 j; ok && o < t && j < 3; ++j) {
                (o, ok) = InRange.stepOut(c, lim[i - 1], ++a);
            }
            if (!ok || o < t) return (0, false, false);
            if (o != t) onEdge = false;
            t = a;
        }
        return (t, true, onEdge);
    }

    /// Output of an in-range CL leg that takes its price to lim: every in-range target is below it.
    function _maxOut(Quote memory q, uint160 lim) private pure returns (uint256) {
        return q.zfo
            ? SqrtPriceMath.getAmount1Delta(lim, q.sqrtPriceX96, q.liquidity, false)
            : SqrtPriceMath.getAmount0Delta(q.sqrtPriceX96, lim, q.liquidity, false);
    }

    /// The input of one leg for output >= t. V2: the exact inverse of getAmountOut. CL (t below _maxOut,
    /// so getNextSqrtPriceFromOutput cannot revert): the pool's exact-output step gives the input less fee,
    /// grossed up so that floor(a * (1e6 - fee) / 1e6) reaches it.
    function _legMinIn(Quote memory q, uint256 t) private pure returns (uint256, bool) {
        if (q.v2) {
            if (t >= q.rout || q.rout > MAX_AMOUNT || q.rin > MAX_AMOUNT) return (0, false);
            return (FullMath.mulDivRoundingUp(t * 1000, q.rin, (q.rout - t) * 997), true);
        }
        return (FullMath.mulDivRoundingUp(_lessFeeIn(q, t), PIPS, PIPS - q.fee), true);
    }

    /// The input less fee of an in-range CL leg for output t (t below _maxOut): the pool's exact-output step.
    function _lessFeeIn(Quote memory q, uint256 t) private pure returns (uint256) {
        uint160 sp = q.sqrtPriceX96;
        uint128 liq = q.liquidity;
        uint160 next = SqrtPriceMath.getNextSqrtPriceFromOutput(sp, liq, t, q.zfo);
        return
            q.zfo
                ? SqrtPriceMath.getAmount0Delta(next, sp, liq, true)
                : SqrtPriceMath.getAmount1Delta(sp, next, liq, true);
    }
}

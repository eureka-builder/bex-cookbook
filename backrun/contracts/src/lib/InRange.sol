// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {SwapMath} from "v4-core/libraries/SwapMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Venues} from "../Types.sol";
import {V2Reader} from "./V2Reader.sol";
import {V3Reader} from "./V3Reader.sol";
import {V4Reader} from "./V4Reader.sol";
import {Quote} from "./RateFilter.sol";

/// The closed-form input checked against every leg's active tick range, and the EXACT output of
/// an in-range cycle with one swap step per leg (no bitmap walk, no getTickAtSqrtPrice, no Loop).
///
/// A CL swap that stays inside the active range is one `SwapMath.computeSwapStep` whose target is not
/// reached. That is the pool's own arithmetic, wei for wei (V3 SwapMath and v4-core SwapMath agree), so
/// the result needs no LegSim confirmation, and "in range" is exactly the pool's own test.
library InRange {
    /// sqrt price of the next initialised tick in the swap direction, from one bitmap word per CL leg
    /// (cold SLOAD 2100). Beyond the word the boundary is treated as a tick: conservative (falls to
    /// the walk), never wrong. V2 legs: 0 (never cross).
    function limits(Venues memory v, Quote[] memory q) internal view returns (uint160[] memory lim) {
        lim = new uint160[](q.length);
        for (uint256 i; i < q.length; ++i) {
            Quote memory s = q[i];
            if (s.v2) continue;
            int24 next;
            if (s.v3Pool != address(0)) {
                (next,) = V3Reader.nextInitializedTick(s.v3Pool, s.tick, s.tickSpacing, s.zfo);
            } else {
                (next,) =
                    V4Reader.nextInitializedTick(IPoolManager(v.poolManager), s.v4Id, s.tick, s.tickSpacing, s.zfo);
            }
            if (next < TickMath.MIN_TICK) next = TickMath.MIN_TICK;
            else if (next > TickMath.MAX_TICK) next = TickMath.MAX_TICK;
            lim[i] = TickMath.getSqrtPriceAtTick(next);
        }
    }

    /// Exact output of one leg for `amountIn`, if it stays in range; (0, false) if it would reach `limit`.
    function stepOut(Quote memory q, uint160 limit, uint256 amountIn)
        internal
        pure
        returns (uint256 out, bool inRange)
    {
        if (q.v2) return (V2Reader.amountOut(amountIn, q.rin, q.rout), true); // a V2 leg never crosses
        if (amountIn == 0) return (0, true); // computeSwapStep reads 0 as exact output
        uint160 next;
        (next,, out,) = SwapMath.computeSwapStep(q.sqrtPriceX96, limit, q.liquidity, -int256(amountIn), q.fee);
        if (next == limit) return (0, false); // reaches the tick: the pool would cross
        inRange = true;
    }

    /// Exact cycle output for input `x` if every leg stays in its active range; otherwise (0, false).
    function cycleOut(Quote[] memory q, uint160[] memory lim, uint256 x)
        internal
        pure
        returns (uint256 out, bool inRange)
    {
        out = x;
        for (uint256 i; i < q.length; ++i) {
            (out, inRange) = stepOut(q[i], lim[i], out);
            if (!inRange) return (0, false);
        }
    }

    /// The least gross leg input that moves e's price to sqrtTarget: the amount computeSwapStep needs to
    /// reach its target (rounded up), then the fee on top, rounded up. A V2 leg never crosses:
    /// type(uint256).max.
    function inputTo(Quote memory e, uint160 sqrtTarget) internal pure returns (uint256 legIn) {
        if (e.v2) return type(uint256).max;
        uint256 net = e.zfo
            ? SqrtPriceMath.getAmount0Delta(sqrtTarget, e.sqrtPriceX96, e.liquidity, true)
            : SqrtPriceMath.getAmount1Delta(e.sqrtPriceX96, sqrtTarget, e.liquidity, true);
        legIn = FullMath.mulDivRoundingUp(net, 1e6, 1e6 - e.fee);
    }
}

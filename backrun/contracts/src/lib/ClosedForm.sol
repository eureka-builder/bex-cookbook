// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {BitMath} from "v4-core/libraries/BitMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

/// Optimal input of a cycle of constant-product pools.
///
/// One pool with fee factor γ (gammaE6 / 1e6) gives out(x) = γ·Rout·x / (Rin + γ·x).
/// A chain of such pools is again out(x) = a·x / (b + c·x). Keeping γ in 1e6 units,
/// folding in the next pool (Rin, Rout, g) gives
///     a' = g·Rout·a,   b' = 1e6·Rin·b,   c' = 1e6·Rin·c + g·a,
/// starting from the identity (a, b, c) = (1, 1, 0). Profit out(x) − x peaks where
/// b + c·x = sqrt(a·b), so x* = (sqrt(a·b) − b) / c, and there is an arb only if a > b.
/// The profit there is x*·(sqrt(a/b) − 1) = (sqrt(a·b) − b)² / (b·c): `maxProfit`, rounded up.
/// It bounds the real cycle when no leg crosses a tick: each model leg pays at least what the
/// swap pays (V2: the same formula, unfloored; V3/V4 in range: in-side reserve floored, out-side
/// rounded up, fee unrounded), and outputs grow with inputs, so the model cycle pays at least the
/// real one at every input. The shifts that keep the coefficients in range round in the same
/// direction: a up, b and c down. That only raises a·x / (b + c·x), so the fold is the exact
/// composition of a curve at or above the model's, and `maxProfit` stays an upper bound.
library ClosedForm {
    function optimalInput(uint256[] memory reserveIn, uint256[] memory reserveOut, uint256[] memory gammaE6)
        internal
        pure
        returns (uint256 xStar, uint256 maxProfit)
    {
        (uint256 a, uint256 b, uint256 c) = fold(reserveIn, reserveOut, gammaE6, reserveIn.length);
        if (a <= b) return (0, 0);
        uint256 t = _shift(a, 128); // a > b, so a ≤ 2^128 (rounded up) keeps a·b in range
        (a, b, c) = (_shrUp(a, t), b >> t, c >> t);
        if (c == 0) return (0, 0);
        uint256 d = sqrt(a * b) - b;
        xStar = d / c;
        // d + 1 and the + 1: sqrt and the division floor. d² / b < a < 2^128, and b·c may not fit.
        if (xStar != 0) maxProfit = FullMath.mulDivRoundingUp(d + 1, d + 1, b) / c + 1;
    }

    /// The curve a·x / (b + c·x) of legs 0 .. n-1 (the identity (1, 1, 0) for n = 0).
    function fold(uint256[] memory reserveIn, uint256[] memory reserveOut, uint256[] memory gammaE6, uint256 n)
        internal
        pure
        returns (uint256 a, uint256 b, uint256 c)
    {
        (a, b, c) = (1, 1, 0);
        for (uint256 i; i < n; ++i) {
            uint256 rin = reserveIn[i];
            uint256 rout = reserveOut[i];
            uint256 g = gammaE6[i];
            // Each product is (a, b or c) · R · 1e6, and c' adds two of them: keep a, b, c under
            // 2^(255 − 20 − bits(R)). x* depends on their ratios only, so the shift is common.
            // the shift follows max(a, b, c), so c (much smaller than a and b) loses its
            // low bits first. Once the reserves folded so far reach ~2^235 together, the
            // 1e6·Rin·c term vanishes and x0 is off by up to ~2x: the walk still returns an exact
            // plan, it just earns less. Upgrade path: shift c less aggressively, or fold in 512 bits.
            uint256 s = _shift(a | b | c, 235 - _bits(rin > rout ? rin : rout));
            (a, b, c) = (_shrUp(a, s), b >> s, c >> s);
            (a, b, c) = (g * rout * a, 1e6 * rin * b, 1e6 * rin * c + g * a);
        }
    }

    /// The least x whose output a·x / (b + c·x) reaches y: ceil(b·y / (a − c·y)). type(uint256).max when y
    /// is out of reach: c·y >= a (the curve stays below a / c) or x does not fit 256 bits.
    /// With the fold's rounding (a up, b and c down) the curve is at or above the real legs, so x is at
    /// most the real input.
    function inverse(uint256 a, uint256 b, uint256 c, uint256 y) internal pure returns (uint256) {
        // c·y >= a, tested as y > floor((a - 1) / c) so that c·y cannot overflow
        if (a == 0 || (c != 0 && y > (a - 1) / c)) return type(uint256).max;
        uint256 d = a - c * y;
        unchecked {
            // the high word of b·y (FullMath's prod1) below d: the quotient fits 256 bits
            uint256 mm = mulmod(b, y, type(uint256).max);
            uint256 lo = b * y;
            if (mm - lo - (mm < lo ? 1 : 0) >= d) return type(uint256).max;
        }
        return FullMath.mulDivRoundingUp(b, y, d);
    }

    /// floor(sqrt(x)), Newton's method from an initial guess above the root.
    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = 1 << (BitMath.mostSignificantBit(x) / 2 + 1);
        uint256 y = (z + x / z) >> 1;
        while (y < z) (z, y) = (y, (y + x / y) >> 1);
    }

    /// x >> s, rounded up.
    function _shrUp(uint256 x, uint256 s) private pure returns (uint256) {
        return s != 0 && x << (256 - s) != 0 ? (x >> s) + 1 : x >> s;
    }

    /// Right shift that brings x under 2^bits.
    function _shift(uint256 x, uint256 bits) private pure returns (uint256) {
        uint256 n = _bits(x);
        return n > bits ? n - bits : 0;
    }

    function _bits(uint256 x) private pure returns (uint256) {
        return x == 0 ? 0 : BitMath.mostSignificantBit(x) + 1;
    }
}

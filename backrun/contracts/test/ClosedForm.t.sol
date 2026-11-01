// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ClosedForm} from "../src/lib/ClosedForm.sol";

contract ClosedFormTest is Test {
    function _legs(uint256 n) internal pure returns (uint256[] memory rin, uint256[] memory rout, uint256[] memory g) {
        rin = new uint256[](n);
        rout = new uint256[](n);
        g = new uint256[](n);
        for (uint256 i; i < n; i++) {
            g[i] = 997000;
        }
    }

    /// The leg-by-leg constant-product output, independent of the fold.
    function _out(uint256[] memory rin, uint256[] memory rout, uint256[] memory g, uint256 x)
        internal
        pure
        returns (uint256)
    {
        for (uint256 i; i < rin.length; i++) {
            x = (g[i] * rout[i] * x) / (1e6 * rin[i] + g[i] * x);
        }
        return x;
    }

    function test_twoEqualPools_noArb() public pure {
        (uint256[] memory rin, uint256[] memory rout, uint256[] memory g) = _legs(2);
        rin[0] = rout[0] = rin[1] = rout[1] = 1e21;
        (uint256 xStar, uint256 maxProfit) = ClosedForm.optimalInput(rin, rout, g);
        assertEq(xStar, 0);
        assertEq(maxProfit, 0);
    }

    function test_twoPools_knownOptimum() public pure {
        // sell WETH where it is dear (3100 USDC), buy it back where it is cheap (3000 USDC)
        (uint256[] memory rin, uint256[] memory rout, uint256[] memory g) = _legs(2);
        (rin[0], rout[0]) = (100e18, 310000e6);
        (rin[1], rout[1]) = (300000e6, 100e18);
        (uint256 xStar, uint256 maxProfit) = ClosedForm.optimalInput(rin, rout, g);

        uint256 step = 0.01 ether;
        uint256 argmax;
        int256 best = type(int256).min;
        for (uint256 x; x <= 10 ether; x += step) {
            int256 p = int256(_out(rin, rout, g, x)) - int256(x);
            if (p > best) (best, argmax) = (p, x);
        }
        assertGt(argmax, 0);
        assertApproxEqAbs(xStar, argmax, step);

        // a reaches ~2^145, so the last shift rounds. The realised best, by brute force: for k USDC
        // out of pool 0 the best input is the least that buys k, so maximise over k (ternary search,
        // concave up to a wei of rounding, then every k within 2000).
        (uint256 kLo, uint256 kHi) = (1, rout[0] / 2);
        while (kHi - kLo > 4000) {
            uint256 k1 = kLo + (kHi - kLo) / 3;
            uint256 k2 = kHi - (kHi - kLo) / 3;
            if (_profitAt(rin, rout, k1) < _profitAt(rin, rout, k2)) kLo = k1;
            else kHi = k2;
        }
        int256 realised;
        for (uint256 k = kLo; k < kHi; k++) {
            int256 p = _profitAt(rin, rout, k);
            if (p > realised) realised = p;
        }
        assertGe(realised, best, "at least the grid's best");
        assertGe(maxProfit, uint256(realised), "the bound covers the realised best");
        assertApproxEqRel(maxProfit, uint256(realised), 1e10, "within 1e-8 of it");
    }

    /// Profit of the least input that buys k units of pool 0's out-token (997/1000 V2 formula).
    function _profitAt(uint256[] memory rin, uint256[] memory rout, uint256 k) internal pure returns (int256) {
        uint256 x = (1000 * k * rin[0] + 997 * (rout[0] - k) - 1) / (997 * (rout[0] - k));
        uint256 back = (997 * k * rout[1]) / (1000 * rin[1] + 997 * k);
        return int256(back) - int256(x);
    }

    function test_fiveLegs_noOverflow() public pure {
        (uint256[] memory rin, uint256[] memory rout, uint256[] memory g) = _legs(5);
        for (uint256 i; i < 5; i++) {
            rin[i] = rout[i] = (1 << 112) - 1 - i;
        }
        rin[2] = 1 << 111; // leg 3 pays two for one: an arb exists
        (uint256 xStar,) = ClosedForm.optimalInput(rin, rout, g);
        assertGt(xStar, 0);
        assertLt(xStar, 1 << 112);
        // a step either side of xStar is no better
        uint256 d = xStar / 100;
        uint256 p = _out(rin, rout, g, xStar) - xStar;
        assertGe(p, _out(rin, rout, g, xStar - d) - (xStar - d));
        assertGe(p, _out(rin, rout, g, xStar + d) - (xStar + d));
    }

    /// optimalInput is the fold over every leg, then the optimum of a·x / (b + c·x). A prefix fold is the fold
    /// of the first legs alone, and the empty fold is the identity.
    function test_fold_matchesOptimalInputCoefficients() public pure {
        (uint256[] memory rin, uint256[] memory rout, uint256[] memory g) = _legs(5);
        for (uint256 i; i < 5; i++) {
            rin[i] = rout[i] = (1 << 112) - 1 - i;
        }
        rin[2] = 1 << 111;
        (uint256 a, uint256 b, uint256 c) = ClosedForm.fold(rin, rout, g, 5);
        (uint256 xStar,) = ClosedForm.optimalInput(rin, rout, g);
        assertGt(xStar, 0);
        assertEq(xStar, _optimum(a, b, c));

        _assertPrefixFold(rin, rout, g);
        (a, b, c) = ClosedForm.fold(rin, rout, g, 0);
        assertEq(a, 1);
        assertEq(b, 1);
        assertEq(c, 0);
    }

    /// fold(..., 2) of five legs is the fold of the first two legs alone.
    function _assertPrefixFold(uint256[] memory rin, uint256[] memory rout, uint256[] memory g) internal pure {
        (uint256[] memory rin2, uint256[] memory rout2, uint256[] memory g2) = _legs(2);
        (rin2[0], rout2[0], rin2[1], rout2[1]) = (rin[0], rout[0], rin[1], rout[1]);
        (uint256 a2, uint256 b2, uint256 c2) = ClosedForm.fold(rin2, rout2, g2, 2);
        (uint256 a, uint256 b, uint256 c) = ClosedForm.fold(rin, rout, g, 2);
        assertEq(a, a2);
        assertEq(b, b2);
        assertEq(c, c2);
    }

    /// The last step of optimalInput, written out.
    function _optimum(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        if (a <= b) return 0;
        uint256 n = 256 - _lz(a);
        uint256 t = n > 128 ? n - 128 : 0;
        a = (a >> t) + (t != 0 && a << (256 - t) != 0 ? 1 : 0);
        (b, c) = (b >> t, c >> t);
        return (ClosedForm.sqrt(a * b) - b) / c;
    }

    function _lz(uint256 x) internal pure returns (uint256 n) {
        while (n < 256 && x >> (255 - n) == 0) n++;
    }

    /// inverse(y) is the least input whose model output reaches y, so at most any x with output y.
    function test_inverse_roundTrips(uint256 a, uint256 b, uint256 c, uint256 x) public pure {
        a = bound(a, 1, 1 << 60);
        b = bound(b, 1, 1 << 60);
        c = bound(c, 0, 1 << 60);
        x = bound(x, 0, 1 << 60);
        uint256 y = a * x / (b + c * x);
        uint256 x2 = ClosedForm.inverse(a, b, c, y);
        assertLt(x2, type(uint256).max, "reachable");
        assertLe(x2, x, "x reaches y, so the least input is at most x");
        assertGe(a * x2, y * (b + c * x2), "x2 reaches y");
        if (x2 > 0) assertLt(a * (x2 - 1), y * (b + c * (x2 - 1)), "x2 - 1 does not");
        if (c > 0) {
            // the curve stays below a / c: y = ceil(a / c) is out of reach, one less is not
            uint256 lim = (a + c - 1) / c;
            assertEq(ClosedForm.inverse(a, b, c, lim), type(uint256).max, "ceil(a / c) unreachable");
            if (lim > 0) {
                assertLt(ClosedForm.inverse(a, b, c, lim - 1), type(uint256).max, "ceil(a / c) - 1 reachable");
            }
        }
    }
}

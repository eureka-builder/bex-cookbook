// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {ProtocolFeeLibrary} from "v4-core/libraries/ProtocolFeeLibrary.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Leg, V2, V3, V4, Venues} from "../Types.sol";
import {Pools} from "./Pools.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";
import {V2Reader} from "./V2Reader.sol";
import {V4Reader} from "./V4Reader.sol";

/// One pool, read once per solve and reused by the rate filter, the closed form and the in-range
/// check. `rin`/`rout` are directed (in-side, out-side) for the leg as given.
struct Quote {
    bool v2;
    bool zfo; // tokenIn is token0 / currency0
    uint160 sqrtPriceX96; // CL only
    uint128 liquidity; // CL only
    uint24 fee; // hundredths of a bip (1e6 = 100 %); V4: LP fee + protocol fee for this direction
    uint24 feeReversed; // the same pool's fee for the opposite direction (differs only for a V4 protocol fee)
    int24 tick; // CL only
    int24 tickSpacing; // CL only
    uint256 rin; // V2 only (reserves); CL: see virtualReserves
    uint256 rout;
    address v3Pool; // CL: where the bitmap / ticks are read from
    PoolId v4Id;
}

/// Marginal-rate product and direction pre-selection from slot0 / reserves alone.
///
/// rho = prod_i gamma_i * p_i, with p_i the spot out-per-in of leg i and gamma_i = 1 - fee_i. An
/// arb exists in this orientation iff rho > 1: profit'(0) = rho - 1 and profit is concave in the
/// input. Reversing a cycle inverts every spot price and takes each pool's fee for the other
/// direction (gamma'_i; differs from gamma_i only for a V4 protocol fee), so
/// rho_fwd * rho_rev = prod_i gamma_i * gamma'_i < 1: at most ONE orientation of any cycle is live.
/// One request therefore covers both directions at zero extra storage reads.
///
/// Fixed point: Q128 (2^128 = 1.0). Spot of a CL leg is (sqrtP / 2^96)^2 token1 per token0, so
/// zeroForOne multiplies by sqrtP/2^96 twice and oneForZero divides twice, each a 512-bit mulDiv.
/// After each leg rho is capped at 2^200: a cycle starting and ending in WETH keeps rho near 2^128,
/// the cap only matters for a broken pool. A product past 2^256 (a pool at an extreme price, such as one
/// drained to the end of its range) saturates instead of reverting (_mulDiv), and the cap takes it.
library RateFilter {
    using V4Reader for IPoolManager;

    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant RHO_CAP = 1 << 200;
    uint256 internal constant PIPS = 1e6;

    /// Every pool's state up to the range check, one read per slot. Cold cost per leg: V3 account 2600 + slot0 2100 +
    /// liquidity 2100 (+ fee/tickSpacing are immutables: no SLOAD) ~ 8k; V4 getSlot0 2100 + getLiquidity 2100
    /// (+ PoolManager account 2600 once) ~ 5-7k; V2 account 2600 + reserves slot 2100 ~ 5k.
    function quotes(Venues memory v, Leg[] memory legs) internal view returns (Quote[] memory q) {
        q = new Quote[](legs.length);
        for (uint256 i; i < legs.length; ++i) {
            q[i] = quote(v, legs[i]);
        }
    }

    function quote(Venues memory v, Leg memory leg) internal view returns (Quote memory q) {
        q.zfo = Pools.zeroForOne(leg);
        if (leg.version == V2) {
            q.v2 = true;
            q.fee = 3000;
            q.feeReversed = 3000;
            (q.rin, q.rout) = V2Reader.reserves(Pools.v2Pair(v, leg.tokenIn, leg.tokenOut), q.zfo);
            return q;
        }
        if (leg.version == V3) {
            q.v3Pool = Pools.v3Pool(v, leg.tokenIn, leg.tokenOut, leg.fee);
            IUniswapV3Pool p = IUniswapV3Pool(q.v3Pool);
            (q.sqrtPriceX96, q.tick,,,,,) = p.slot0();
            q.liquidity = p.liquidity();
            q.fee = p.fee(); // V3's protocol fee is carved out of the LP fee: same in both directions
            q.feeReversed = q.fee;
            q.tickSpacing = p.tickSpacing();
            return q;
        }
        IPoolManager pm = IPoolManager(v.poolManager);
        q.v4Id = Pools.v4Id(Pools.v4Key(leg));
        uint24 protocolFee;
        (q.sqrtPriceX96, q.tick, protocolFee,) = pm.getSlot0(q.v4Id);
        q.liquidity = pm.getLiquidity(q.v4Id);
        q.tickSpacing = leg.tickSpacing;
        // hookless key: never the dynamic-fee flag (initialize rejects it without a hook)
        // slot0.protocolFee packs both directions (low 12 bits 0->1, high 12 bits 1->0).
        uint24 f01 = v4Fee(ProtocolFeeLibrary.getZeroForOneFee(protocolFee), leg.fee);
        uint24 f10 = v4Fee(ProtocolFeeLibrary.getOneForZeroFee(protocolFee), leg.fee);
        (q.fee, q.feeReversed) = q.zfo ? (f01, f10) : (f10, f01);
    }

    /// V4 swap fee for one direction: LP fee plus that direction's protocol fee (Pool.swap).
    function v4Fee(uint16 pf, uint24 lpFee) internal pure returns (uint24) {
        return pf == 0 ? lpFee : ProtocolFeeLibrary.calculateSwapFee(pf, lpFee);
    }

    /// prod gamma_i * p_i in Q128 for the legs as given. 0 when a CL pool is uninitialised (sqrtP == 0)
    /// or a V2 pair is empty: no arb through a dead pool. A CL pool with no active liquidity is not dead:
    /// its spot price is the best rate a swap can get (the price only moves against it), so rho stays an
    /// upper bound, and the solver's walk moves through the gap to the liquidity behind it.
    function rho(Quote[] memory q) internal pure returns (uint256 r) {
        r = Q128;
        for (uint256 i; i < q.length; ++i) {
            r = _legRate(q[i], r, false);
            if (r == 0) return 0;
        }
    }

    /// rho of the reversed cycle, from the same quotes (no reads): every leg flips direction.
    function rhoReversed(Quote[] memory q) internal pure returns (uint256 r) {
        r = Q128;
        for (uint256 i = q.length; i > 0; --i) {
            r = _legRate(q[i - 1], r, true);
            if (r == 0) return 0;
        }
    }

    /// +1: the cycle as given is live; -1: only its reverse is; 0: neither (quiet market).
    /// Costs no storage beyond `quotes`.
    function direction(Quote[] memory q) internal pure returns (int8) {
        if (rho(q) > Q128) return 1;
        if (rhoReversed(q) > Q128) return -1;
        return 0;
    }

    function _legRate(Quote memory q, uint256 r, bool flip) private pure returns (uint256) {
        bool zfo = flip ? !q.zfo : q.zfo;
        if (q.v2) {
            (uint256 rin, uint256 rout) = flip ? (q.rout, q.rin) : (q.rin, q.rout);
            if (rin == 0 || rout == 0) return 0;
            r = _mulDiv(r, rout, rin);
        } else {
            uint256 s = q.sqrtPriceX96;
            if (s == 0) return 0;
            // out per in: token1/token0 = (s/2^96)^2 when zeroForOne, its inverse otherwise.
            r = zfo ? _mulDiv(_mulDiv(r, s, Q96), s, Q96) : _mulDiv(_mulDiv(r, Q96, s), Q96, s);
        }
        r = FullMath.mulDiv(r, PIPS - (flip ? q.feeReversed : q.fee), PIPS); // fee on input
        return r > RHO_CAP ? RHO_CAP : r;
    }

    /// a * b / d, or type(uint256).max where the quotient does not fit 256 bits (FullMath.mulDiv reverts there).
    function _mulDiv(uint256 a, uint256 b, uint256 d) private pure returns (uint256) {
        uint256 hi;
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            let lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
        return hi >= d ? type(uint256).max : FullMath.mulDiv(a, b, d);
    }

    /// The cycle run backwards: legs reversed, each leg's tokens swapped. Same pools, so the Plan's
    /// `legs` and `Pools.cycleId` change with the direction (stats key on cycleId; keep both names).
    function reverse(Leg[] memory legs) internal pure returns (Leg[] memory r) {
        uint256 n = legs.length;
        r = new Leg[](n);
        for (uint256 i; i < n; ++i) {
            Leg memory l = legs[n - 1 - i];
            r[i] = Leg(l.version, l.tokenOut, l.tokenIn, l.fee, l.tickSpacing);
        }
    }

    /// In-range virtual reserves of a CL quote (V2: the reserves themselves). In-side floored, out-side
    /// rounded up: the model never pays less than the pool, so ClosedForm's maxProfit stays an upper bound
    /// on the in-range curve.
    function virtualReserves(Quote memory q) internal pure returns (uint256 rin, uint256 rout, uint256 gammaE6) {
        if (q.v2) return (q.rin, q.rout, PIPS - q.fee);
        uint256 l = q.liquidity;
        (rin, rout) = q.zfo
            ? (FullMath.mulDiv(l, Q96, q.sqrtPriceX96), FullMath.mulDivRoundingUp(l, q.sqrtPriceX96, Q96))
            : (FullMath.mulDiv(l, q.sqrtPriceX96, Q96), FullMath.mulDivRoundingUp(l, Q96, q.sqrtPriceX96));
        gammaE6 = PIPS - q.fee;
    }
}

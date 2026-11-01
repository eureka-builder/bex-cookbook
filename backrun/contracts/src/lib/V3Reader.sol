// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BitMath} from "v4-core/libraries/BitMath.sol";
import {TickBitmap} from "v4-core/libraries/TickBitmap.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3Pool.sol";

struct Snapshot {
    uint160 sqrtPriceX96;
    int24 tick;
    uint128 liquidity;
    uint24 fee;
    int24 tickSpacing;
}

/// V3 pool state reads, plus the bitmap-word math V4Reader shares.
library V3Reader {
    function snapshot(address pool) internal view returns (Snapshot memory s) {
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        (s.sqrtPriceX96, s.tick,,,,,) = p.slot0();
        s.liquidity = p.liquidity();
        s.fee = p.fee();
        s.tickSpacing = p.tickSpacing();
    }

    function nextInitializedTick(address pool, int24 tick, int24 spacing, bool lte)
        internal
        view
        returns (int24 next, bool initialized)
    {
        int16 wordPos = wordPosition(tick, spacing, lte);
        return resolve(IUniswapV3Pool(pool).tickBitmap(wordPos), tick, spacing, lte);
    }

    function liquidityNet(address pool, int24 tick) internal view returns (int128 net) {
        (, net,,,,,,) = IUniswapV3Pool(pool).ticks(tick);
    }

    /// Which bitmap word nextInitializedTickWithinOneWord reads.
    function wordPosition(int24 tick, int24 spacing, bool lte) internal pure returns (int16) {
        int24 compressed = TickBitmap.compress(tick, spacing);
        return int16((lte ? compressed : compressed + 1) >> 8);
    }

    /// TickBitmap.nextInitializedTickWithinOneWord, given the word from `wordPosition`.
    function resolve(uint256 word, int24 tick, int24 spacing, bool lte)
        internal
        pure
        returns (int24 next, bool initialized)
    {
        int24 compressed = TickBitmap.compress(tick, spacing);
        if (lte) {
            uint8 bitPos = uint8(uint24(compressed) % 256);
            uint256 masked = word & ((1 << bitPos) - 1 + (1 << bitPos));
            initialized = masked != 0;
            next = initialized
                ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * spacing
                : (compressed - int24(uint24(bitPos))) * spacing;
        } else {
            compressed += 1;
            uint8 bitPos = uint8(uint24(compressed) % 256);
            uint256 masked = word & ~((1 << bitPos) - 1);
            initialized = masked != 0;
            next = initialized
                ? (compressed + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * spacing
                : (compressed + int24(uint24(type(uint8).max - bitPos))) * spacing;
        }
    }
}

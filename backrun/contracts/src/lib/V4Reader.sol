// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Snapshot, V3Reader} from "./V3Reader.sol";

/// V4 pool state reads via extsload. fee/tickSpacing come from the pool key, not storage.
/// The bitmap math is V3Reader's: V4 keeps the same tick bitmap layout. `snapshot` is used by the tests.
/// The getters read the PoolManager storage layout that v4-core's StateLibrary reads (MIT); they live here
/// so that no BUSL-1.1 source (StateLibrary imports Position.sol) enters the build.
library V4Reader {
    using V4Reader for IPoolManager;

    /// `pools` mapping slot in the PoolManager. pools[id] is a Pool.State: slot0, then 2 fee-growth words,
    /// then liquidity (+3), ticks (+4) and tickBitmap (+5).
    uint256 private constant POOLS_SLOT = 6;
    uint256 private constant LIQUIDITY_OFFSET = 3;
    uint256 private constant TICKS_OFFSET = 4;
    uint256 private constant TICK_BITMAP_OFFSET = 5;

    /// slot0 packs lpFee (24 bits) | protocolFee (24) | tick (24) | sqrtPriceX96 (160).
    function getSlot0(IPoolManager pm, PoolId id)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        uint256 w = uint256(pm.extsload(bytes32(_state(id))));
        sqrtPriceX96 = uint160(w);
        tick = int24(uint24(w >> 160));
        protocolFee = uint24(w >> 184);
        lpFee = uint24(w >> 208);
    }

    function getLiquidity(IPoolManager pm, PoolId id) internal view returns (uint128) {
        return uint128(uint256(pm.extsload(bytes32(_state(id) + LIQUIDITY_OFFSET))));
    }

    function getTickBitmap(IPoolManager pm, PoolId id, int16 wordPos) internal view returns (uint256) {
        return uint256(pm.extsload(keccak256(abi.encode(int256(wordPos), _state(id) + TICK_BITMAP_OFFSET))));
    }

    /// The first word of ticks[tick] packs liquidityNet (high 128 bits) | liquidityGross (low 128).
    function liquidityNet(IPoolManager pm, PoolId id, int24 tick) internal view returns (int128) {
        bytes32 w = pm.extsload(keccak256(abi.encode(int256(tick), _state(id) + TICKS_OFFSET)));
        return int128(int256(uint256(w)) >> 128);
    }

    /// Storage slot of pools[id].
    function _state(PoolId id) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(PoolId.unwrap(id), POOLS_SLOT)));
    }

    function snapshot(IPoolManager pm, PoolId id, uint24 fee, int24 tickSpacing)
        internal
        view
        returns (Snapshot memory s)
    {
        (s.sqrtPriceX96, s.tick,,) = pm.getSlot0(id);
        s.liquidity = pm.getLiquidity(id);
        s.fee = fee;
        s.tickSpacing = tickSpacing;
    }

    function nextInitializedTick(IPoolManager pm, PoolId id, int24 tick, int24 spacing, bool lte)
        internal
        view
        returns (int24 next, bool initialized)
    {
        int16 wordPos = V3Reader.wordPosition(tick, spacing, lte);
        return V3Reader.resolve(pm.getTickBitmap(id, wordPos), tick, spacing, lte);
    }
}

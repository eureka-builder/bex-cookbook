// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Leg, V2, V3, V4, Venues, BadLeg} from "../Types.sol";

/// Pool address / id derivation and cycle validation. Everything is pure.
library Pools {
    function v2Pair(Venues memory v, address a, address b) internal pure returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return _create2(v.v2Factory, keccak256(abi.encodePacked(t0, t1)), v.v2InitHash);
    }

    function v3Pool(Venues memory v, address a, address b, uint24 fee) internal pure returns (address) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        return _create2(v.v3Factory, keccak256(abi.encode(t0, t1, fee)), v.v3InitHash);
    }

    function v4Key(Leg memory leg) internal pure returns (PoolKey memory) {
        (address lo, address hi) =
            leg.tokenIn < leg.tokenOut ? (leg.tokenIn, leg.tokenOut) : (leg.tokenOut, leg.tokenIn);
        return PoolKey(Currency.wrap(lo), Currency.wrap(hi), leg.fee, leg.tickSpacing, IHooks(address(0)));
    }

    function v4Id(PoolKey memory key) internal pure returns (PoolId) {
        return PoolIdLibrary.toId(key);
    }

    /// tokenIn is token0 / currency0.
    function zeroForOne(Leg memory leg) internal pure returns (bool) {
        return leg.tokenIn < leg.tokenOut;
    }

    function cycleId(Leg[] memory legs) internal pure returns (bytes32) {
        return keccak256(abi.encode(legs));
    }

    /// ETH (address(0)) and the venues' WETH are one asset. Every leg is a distinct pool: a repeated
    /// pool would be simulated at its old state while `execute` meets it moved.
    function validate(Venues memory v, Leg[] memory legs) internal pure {
        uint256 n = legs.length;
        if (n < 2) revert BadLeg();
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            Leg memory l = legs[i];
            ids[i] = _poolId(v, l);
            for (uint256 j; j < i; ++j) {
                if (ids[j] == ids[i]) revert BadLeg();
            }
            if (i > 0 && _norm(v, legs[i - 1].tokenOut) != _norm(v, l.tokenIn)) revert BadLeg();
        }
        if (_norm(v, legs[0].tokenIn) != v.weth || _norm(v, legs[n - 1].tokenOut) != v.weth) revert BadLeg();
    }

    /// The leg's pool (V2/V3 address, V4 id) after the per-version checks.
    function _poolId(Venues memory v, Leg memory l) private pure returns (bytes32) {
        if (l.version == V4) {
            if (l.tokenIn == v.weth || l.tokenOut == v.weth) revert BadLeg();
            return PoolId.unwrap(v4Id(v4Key(l)));
        }
        if (l.tokenIn == address(0) || l.tokenOut == address(0)) revert BadLeg(); // no native ETH on V2/V3
        if (l.version == V2) {
            if (l.fee != 3000 || l.tickSpacing != 0) revert BadLeg();
            return bytes32(uint256(uint160(v2Pair(v, l.tokenIn, l.tokenOut))));
        }
        if (l.version != V3) revert BadLeg();
        return bytes32(uint256(uint160(v3Pool(v, l.tokenIn, l.tokenOut, l.fee))));
    }

    function _norm(Venues memory v, address t) private pure returns (address) {
        return t == address(0) ? v.weth : t;
    }

    function _create2(address factory, bytes32 salt, bytes32 initHash) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initHash)))));
    }
}

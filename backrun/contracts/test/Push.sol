// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {IUniswapV2Pair} from "../src/interfaces/IUniswapV2Pair.sol";
import {WETH} from "./Fork.t.sol";

/// Wraps the ETH it is sent and swaps it straight into a V3 pool, paying the callback in WETH.
contract V3Pusher {
    function push(address pool, bool zeroForOne) external payable {
        uint256 amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        IUniswapV3Pool(pool).swap(address(this), zeroForOne, int256(amountIn), limit, "");
    }

    function uniswapV3SwapCallback(int256 d0, int256 d1, bytes calldata) external {
        IERC20(WETH).transfer(msg.sender, uint256(d0 > 0 ? d0 : d1));
    }
}

/// Wraps the ETH it is sent and sells it into a V2 pair (router formula on getReserves).
contract V2Pusher {
    function push(address pair, bool wethIsToken0) external payable {
        uint256 amountIn = msg.value;
        IWETH(WETH).deposit{value: amountIn}();
        IERC20(WETH).transfer(pair, amountIn);
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        (uint256 rIn, uint256 rOut) = wethIsToken0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 out = amountIn * 997 * rOut / (rIn * 1000 + amountIn * 997);
        (uint256 o0, uint256 o1) = wethIsToken0 ? (uint256(0), out) : (out, uint256(0));
        IUniswapV2Pair(pair).swap(o0, o1, address(this), "");
    }
}

/// Sells native ETH into a V4 pool (currency0 = ETH).
contract V4Pusher is IUnlockCallback {
    IPoolManager constant PM = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    function push(PoolKey memory key, uint256 amountIn) external payable {
        PM.unlock(abi.encode(key, amountIn));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory key, uint256 amountIn) = abi.decode(data, (PoolKey, uint256));
        BalanceDelta d = PM.swap(key, SwapParams(true, -int256(amountIn), TickMath.MIN_SQRT_PRICE + 1), "");
        PM.settle{value: amountIn}();
        PM.take(key.currency1, address(this), uint128(d.amount1()));
        return "";
    }
}

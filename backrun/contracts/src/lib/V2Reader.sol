// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IUniswapV2Pair} from "../interfaces/IUniswapV2Pair.sol";

/// V2 reserves from getReserves (never from token balances), and the pair's output formula.
library V2Reader {
    function reserves(address pair, bool zeroForOne) internal view returns (uint256 reserveIn, uint256 reserveOut) {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        return zeroForOne ? (r0, r1) : (r1, r0);
    }

    /// Uniswap V2 getAmountOut: the 0.3% fee off the input, then x * y = k.
    function amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 inFee = amountIn * 997;
        return inFee * reserveOut / (reserveIn * 1000 + inFee);
    }
}

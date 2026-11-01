// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {FORK_BLOCK} from "./ForkBlock.sol";
import {Venues, MainnetVenues} from "../src/Types.sol";

address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

// The compute cap of one solve, in gas. A bound by construction: test_worstCaseWalk_underComputeCap
// (CycleSolver.t.sol) measures at most 5,819,961 for 5 legs that walk to the budget. On real cycles the
// quiet-market census (EndToEnd.t.sol) measures at most 1,324,727 (eth_usdc_chex__v4_100_v4_100_v4_10000 at
// FORK_BLOCK).
uint256 constant MAX_COMPUTE_GAS = 6_000_000;

function _v() pure returns (Venues memory) {
    return MainnetVenues.get();
}

/// Shared base for mainnet-fork tests. Skipped (not failed) when ETH_RPC_URL is unset.
abstract contract ForkTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant GTC = 0xDe30da39c46104798bB5aA3fe8B9e0e1F348163F;
    address constant USDC_WETH_V3_1BP = 0xE0554a476A092703abdB3Ef35c80e0D76d32939F;
    address constant WETH_GTC_V2 = 0xa3509A16BbfC5992eb01Cc861B615cCd8e937da8;
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    bytes32 constant ETH_USDC_V4_ID = 0x00b9edc1583bf6ef09ff3a09f6c23ecb57fd7d0bb75625717ec81eed181e22d7;

    function setUp() public virtual {
        string memory url = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true);
        vm.createSelectFork(url, vm.envOr("FORK_BLOCK", FORK_BLOCK));
    }
}

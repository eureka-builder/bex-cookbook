// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {ForkTest} from "./Fork.t.sol";
import {Snapshot, V3Reader} from "../src/lib/V3Reader.sol";
import {V4Reader} from "../src/lib/V4Reader.sol";
import {V2Reader} from "../src/lib/V2Reader.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {IUniswapV2Pair} from "../src/interfaces/IUniswapV2Pair.sol";

contract ReadersTest is ForkTest {
    using StateLibrary for IPoolManager;

    IPoolManager constant PM = IPoolManager(POOL_MANAGER);
    PoolId constant V4_ID = PoolId.wrap(ETH_USDC_V4_ID);

    function test_v3Snapshot_matchesSlot0() public view {
        Snapshot memory s = V3Reader.snapshot(USDC_WETH_V3_1BP);
        (uint160 p, int24 t,,,,,) = IUniswapV3Pool(USDC_WETH_V3_1BP).slot0();
        assertEq(s.sqrtPriceX96, p);
        assertEq(s.tick, t);
        assertEq(s.fee, 100);
        assertEq(s.tickSpacing, 1);
        assertEq(s.liquidity, IUniswapV3Pool(USDC_WETH_V3_1BP).liquidity());
    }

    function test_v3NextTick_isInitialized() public view {
        Snapshot memory s = V3Reader.snapshot(USDC_WETH_V3_1BP);
        (int24 next, bool init) = V3Reader.nextInitializedTick(USDC_WETH_V3_1BP, s.tick, 1, true);
        assertLe(next, s.tick);
        assertEq(_v3Initialized(next), init);
        if (init) {
            (, int128 net,,,,,,) = IUniswapV3Pool(USDC_WETH_V3_1BP).ticks(next);
            assertEq(V3Reader.liquidityNet(USDC_WETH_V3_1BP, next), net);
        }
    }

    function test_v3NextTick_gtIsInitialized() public view {
        Snapshot memory s = V3Reader.snapshot(USDC_WETH_V3_1BP);
        (int24 next, bool init) = V3Reader.nextInitializedTick(USDC_WETH_V3_1BP, s.tick, 1, false);
        assertGt(next, s.tick);
        if (init) assertTrue(_v3Initialized(next));
    }

    function _v3Initialized(int24 tick) internal view returns (bool ok) {
        (,,,,,,, ok) = IUniswapV3Pool(USDC_WETH_V3_1BP).ticks(tick);
    }

    function test_v4Snapshot_matchesStateLibrary() public view {
        Snapshot memory s = V4Reader.snapshot(PM, V4_ID, 100, 1);
        (uint160 p, int24 t,,) = PM.getSlot0(V4_ID);
        assertEq(s.sqrtPriceX96, p);
        assertEq(s.tick, t);
        assertEq(s.liquidity, PM.getLiquidity(V4_ID));
        assertEq(s.fee, 100);
        assertEq(s.tickSpacing, 1);
        assertGt(s.liquidity, 0);
    }

    function test_v4NextTick_isInitialized() public view {
        Snapshot memory s = V4Reader.snapshot(PM, V4_ID, 100, 1);
        (int24 next, bool init) = V4Reader.nextInitializedTick(PM, V4_ID, s.tick, 1, true);
        assertLe(next, s.tick);
        if (init) {
            (uint128 gross,) = PM.getTickLiquidity(V4_ID, next);
            assertGt(gross, 0);
            (, int128 net) = PM.getTickLiquidity(V4_ID, next);
            assertEq(V4Reader.liquidityNet(PM, V4_ID, next), net);
        }
    }

    function test_v2Reserves_orientation() public view {
        (uint256 rin, uint256 rout) = V2Reader.reserves(WETH_GTC_V2, true);
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(WETH_GTC_V2).getReserves();
        assertEq(rin, r0);
        assertEq(rout, r1);
        (rin, rout) = V2Reader.reserves(WETH_GTC_V2, false);
        assertEq(rin, r1);
        assertEq(rout, r0);
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Pools} from "../src/lib/Pools.sol";
import {CycleSolver} from "../src/CycleSolver.sol";
import {CycleExecutor} from "../src/CycleExecutor.sol";
import {Leg, V3, BadLeg, Venues, MainnetVenues} from "../src/Types.sol";

contract VenuesTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant CAFE = address(0xCAFE);

    function validate(Venues memory v, Leg[] memory legs) external pure {
        Pools.validate(v, legs);
    }

    function _cycle(address weth) internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = Leg(V3, weth, USDC, 500, 10);
        legs[1] = Leg(V3, USDC, weth, 100, 1);
    }

    function test_mainnetDefaults_matchConstants() public pure {
        Venues memory v = MainnetVenues.get();
        assertEq(v.v2Factory, 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
        assertEq(v.v2InitHash, 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f);
        assertEq(v.v3Factory, 0x1F98431c8aD98523631AE4a59f267346ea31F984);
        assertEq(v.v3InitHash, 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54);
        assertEq(v.poolManager, 0x000000000004444c5dc75cB358380D2e3dE08A90);
        assertEq(v.weth, 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    }

    function test_customVenues_deriveWithCustomFactory() public pure {
        Venues memory v = MainnetVenues.get();
        address mainnetPool = Pools.v3Pool(v, USDC, v.weth, 100);
        v.v3Factory = address(0xBEEF);
        assertTrue(Pools.v3Pool(v, USDC, v.weth, 100) != mainnetPool);
        v = MainnetVenues.get();
        v.v2Factory = address(0xBEEF);
        assertTrue(Pools.v2Pair(v, USDC, v.weth) != Pools.v2Pair(MainnetVenues.get(), USDC, v.weth));
    }

    function test_validate_anchorsOnConfiguredWeth() public {
        Venues memory v = MainnetVenues.get();
        v.weth = CAFE;
        this.validate(v, _cycle(CAFE));
        vm.expectRevert(BadLeg.selector);
        this.validate(v, _cycle(MainnetVenues.get().weth));
    }

    function test_solverAndExecutor_exposeVenues() public {
        Venues memory v = MainnetVenues.get();
        v.v2Factory = address(0x1);
        v.v2InitHash = bytes32(uint256(2));
        v.v3Factory = address(0x3);
        v.v3InitHash = bytes32(uint256(4));
        v.poolManager = address(0x5);
        v.weth = CAFE;
        Venues memory s = new CycleSolver(v).venues();
        Venues memory e = new CycleExecutor(v).venues();
        assertEq(abi.encode(s), abi.encode(v));
        assertEq(abi.encode(e), abi.encode(v));
    }
}

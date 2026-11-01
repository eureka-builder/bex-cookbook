// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {_v, WETH} from "./Fork.t.sol";
import {Pools} from "../src/lib/Pools.sol";
import {Leg, V2, V3, V4, BadLeg} from "../src/Types.sol";

contract PoolsTest is Test {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant GTC = 0xDe30da39c46104798bB5aA3fe8B9e0e1F348163F;

    function validate(Leg[] memory legs) external pure {
        Pools.validate(_v(), legs);
    }

    function _two(Leg memory a, Leg memory b) internal pure returns (Leg[] memory legs) {
        legs = new Leg[](2);
        legs[0] = a;
        legs[1] = b;
    }

    function test_v3Pool_usdcWeth_1bp() public pure {
        assertEq(Pools.v3Pool(_v(), USDC, WETH, 100), 0xE0554a476A092703abdB3Ef35c80e0D76d32939F);
    }

    function test_v3Pool_orderIndependent() public pure {
        assertEq(Pools.v3Pool(_v(), WETH, USDC, 100), Pools.v3Pool(_v(), USDC, WETH, 100));
    }

    function test_v2Pair_wethGtc() public pure {
        assertEq(Pools.v2Pair(_v(), WETH, GTC), 0xa3509A16BbfC5992eb01Cc861B615cCd8e937da8);
    }

    function test_v4Id_ethUsdc_1bp() public pure {
        Leg memory leg = Leg(V4, address(0), USDC, 100, 1);
        assertEq(
            PoolId.unwrap(Pools.v4Id(Pools.v4Key(leg))),
            0x00b9edc1583bf6ef09ff3a09f6c23ecb57fd7d0bb75625717ec81eed181e22d7
        );
    }

    function test_v4Key_reversedTokens_sameId() public pure {
        Leg memory a = Leg(V4, address(0), USDC, 100, 1);
        Leg memory b = Leg(V4, USDC, address(0), 100, 1);
        assertEq(PoolId.unwrap(Pools.v4Id(Pools.v4Key(a))), PoolId.unwrap(Pools.v4Id(Pools.v4Key(b))));
        assertTrue(Pools.zeroForOne(a));
        assertFalse(Pools.zeroForOne(b));
    }

    function test_validate_rejectsBrokenChain() public {
        Leg[] memory legs = _two(Leg(V3, WETH, USDC, 500, 10), Leg(V3, USDT, WETH, 500, 10));
        vm.expectRevert(BadLeg.selector);
        this.validate(legs);
    }

    function test_validate_rejectsNotEthAnchored() public {
        Leg[] memory legs = _two(Leg(V3, USDC, USDT, 100, 1), Leg(V3, USDT, USDC, 100, 1));
        vm.expectRevert(BadLeg.selector);
        this.validate(legs);
    }

    function test_validate_acceptsEthWethMix() public pure {
        Leg[] memory legs = _two(Leg(V3, WETH, USDC, 500, 10), Leg(V4, USDC, address(0), 100, 1));
        Pools.validate(_v(), legs);
    }

    /// No upper bound on the leg count: the gas budget is the ceiling, not `validate`.
    function test_validate_acceptsSixDistinctLegs() public pure {
        Leg[] memory legs = new Leg[](6);
        legs[0] = Leg(V3, WETH, USDC, 500, 10);
        legs[1] = Leg(V3, USDC, USDT, 100, 1);
        legs[2] = Leg(V3, USDT, WETH, 500, 10);
        legs[3] = Leg(V3, WETH, USDC, 3000, 60);
        legs[4] = Leg(V3, USDC, USDT, 500, 10);
        legs[5] = Leg(V3, USDT, WETH, 100, 1);
        Pools.validate(_v(), legs);
    }

    function test_validate_rejectsBadVersionV2FeeAndV4Weth() public {
        Leg[] memory legs = _two(Leg(V3, WETH, USDC, 500, 10), Leg(5, USDC, WETH, 500, 10));
        vm.expectRevert(BadLeg.selector);
        this.validate(legs);
        legs = _two(Leg(V2, WETH, USDC, 2500, 0), Leg(V3, USDC, WETH, 500, 10));
        vm.expectRevert(BadLeg.selector);
        this.validate(legs);
        legs = _two(Leg(V3, WETH, USDC, 500, 10), Leg(V4, USDC, WETH, 100, 1));
        vm.expectRevert(BadLeg.selector);
        this.validate(legs);
    }

    function test_validate_rejectsRepeatedPool() public {
        // V3: the 5bp pool both ways
        Leg[] memory legs = _two(Leg(V3, WETH, USDC, 500, 10), Leg(V3, USDC, WETH, 500, 10));
        vm.expectRevert(BadLeg.selector);
        this.validate(legs);
        // V2: the pair both ways
        legs = _two(Leg(V2, WETH, USDC, 3000, 0), Leg(V2, USDC, WETH, 3000, 0));
        vm.expectRevert(BadLeg.selector);
        this.validate(legs);
        // V4: the same id on legs 0 and 2
        legs = new Leg[](4);
        legs[0] = Leg(V4, address(0), USDC, 100, 1);
        legs[1] = Leg(V3, USDC, WETH, 100, 1);
        legs[2] = Leg(V4, address(0), USDC, 500, 10);
        legs[3] = Leg(V3, USDC, WETH, 500, 10);
        Pools.validate(_v(), legs); // distinct ids: fine
        legs[2] = Leg(V4, address(0), USDC, 100, 1);
        vm.expectRevert(BadLeg.selector);
        this.validate(legs);
    }

    /// Same tokens, another fee tier or version: a different pool.
    function test_validate_acceptsSamePairOnOtherPools() public pure {
        Pools.validate(_v(), _two(Leg(V3, WETH, USDC, 500, 10), Leg(V3, USDC, WETH, 100, 1)));
        Pools.validate(_v(), _two(Leg(V2, WETH, USDC, 3000, 0), Leg(V3, USDC, WETH, 3000, 60)));
    }

    function test_validate_rejectsNativeEthOnV2V3() public {
        Leg[] memory legs = _two(Leg(V3, address(0), USDC, 500, 10), Leg(V3, USDC, WETH, 100, 1));
        vm.expectRevert(BadLeg.selector);
        this.validate(legs);
        legs = _two(Leg(V3, WETH, USDC, 500, 10), Leg(V2, USDC, address(0), 3000, 0));
        vm.expectRevert(BadLeg.selector);
        this.validate(legs);
    }

    function test_validate_rejectsV2TickSpacing() public {
        Leg[] memory legs = _two(Leg(V2, WETH, USDC, 3000, 1), Leg(V3, USDC, WETH, 100, 1));
        vm.expectRevert(BadLeg.selector);
        this.validate(legs);
    }

    function test_cycleId_isKeccakOfLegs() public pure {
        Leg[] memory legs = _two(Leg(V3, WETH, USDC, 500, 10), Leg(V2, USDC, WETH, 3000, 0));
        assertEq(Pools.cycleId(legs), keccak256(abi.encode(legs)));
    }
}

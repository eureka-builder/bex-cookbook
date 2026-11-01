// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ForkTest, _v} from "./Fork.t.sol";
import {V3Pusher} from "./Push.sol";
import {JsonCycle, JsonLeg} from "./EndToEnd.t.sol";
import {CycleSolver} from "../src/CycleSolver.sol";
import {CycleExecutor} from "../src/CycleExecutor.sol";
import {Leg, Venues} from "../src/Types.sol";

/// `bex.compute.code` carries the solver's runtime code. It must come from a constructed
/// instance (immutables filled), so etched code behaves exactly like the deployed contract.
contract RuntimeCodeForkTest is ForkTest {
    address constant ETCHED = address(0xC0DE);
    address constant USDC_WETH_V3_1BP_POOL = 0xE0554a476A092703abdB3Ef35c80e0D76d32939F;

    function test_etchedSolver_matchesDeployed() public {
        CycleSolver s = new CycleSolver(_v());
        vm.etch(ETCHED, address(s).code);
        // Move one pool so at least one cycle returns a plan, not only reverts.
        vm.deal(address(this), 300 ether);
        new V3Pusher().push{value: 300 ether}(USDC_WETH_V3_1BP_POOL, false);

        JsonCycle[] memory cycles = abi.decode(vm.parseJson(vm.readFile("test/fixtures/cycles.json")), (JsonCycle[]));
        // V2+V3, V4 only, V3 on the pushed pool: every reader's immutables are used.
        uint256[3] memory pick = [uint256(0), 1, 9];
        uint256 plans;
        for (uint256 k; k < pick.length; ++k) {
            JsonCycle memory c = cycles[pick[k]];
            Leg[] memory legs = new Leg[](c.legs.length);
            for (uint256 i; i < legs.length; ++i) {
                JsonLeg memory j = c.legs[i];
                legs[i] = Leg(j.version, j.tokenIn, j.tokenOut, j.fee, j.tickSpacing);
            }
            bytes memory call_ = abi.encodeCall(CycleSolver.solve, (legs, 0, 0, 10000, address(0), bytes32(0)));
            (bool okD, bytes memory retD) = address(s).staticcall(call_);
            (bool okE, bytes memory retE) = ETCHED.staticcall(call_);
            assertEq(okE, okD, string.concat("ok differs: ", c.name));
            assertEq(retE, retD, string.concat("return differs: ", c.name));
            if (okD) ++plans;
        }
        assertGt(plans, 0, "no cycle returned a plan");
    }
}

contract RuntimeCodeSizeTest is Test {
    address constant ETCHED = address(0xC0DE);

    /// forge's `deployedBytecode` has zero placeholders where the immutables go: never send it.
    function test_forgeDeployedBytecode_hasZeroVenues() public {
        vm.etch(ETCHED, vm.getDeployedCode("CycleSolver.sol:CycleSolver"));
        Venues memory v = CycleSolver(ETCHED).venues();
        assertEq(v.weth, address(0));
        assertEq(v.v3Factory, address(0));
    }

    function test_runtimeCode_underEip170() public {
        CycleSolver s = new CycleSolver(_v());
        CycleExecutor e = new CycleExecutor(_v());
        assertLe(address(s).code.length, 24576, "solver");
        assertLe(address(e).code.length, 24576, "executor");
    }
}

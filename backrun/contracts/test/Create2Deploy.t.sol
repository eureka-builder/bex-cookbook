// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ForkTest, _v} from "./Fork.t.sol";
import {V3Pusher} from "./Push.sol";
import {JsonCycle, JsonLeg} from "./EndToEnd.t.sol";
import {
    CREATE2_DEPLOYER,
    SALT,
    SOLVER_SALT,
    create2Address,
    executorInitCode,
    solverInitCode
} from "../script/Create2Deploy.s.sol";
import {RuntimeCode} from "../script/RuntimeCode.s.sol";
import {CycleExecutor} from "../src/CycleExecutor.sol";
import {CycleSolver} from "../src/CycleSolver.sol";
import {Leg, Plan} from "../src/Types.sol";

// The pinned CREATE2 deploys. These three values per contract are the record of what the tree builds;
// the table in README.md repeats them. The deploy transaction itself is generated (deploy/out/, not committed).
bytes32 constant EXECUTOR_INIT_CODE_HASH = 0xd19e4522c43d12c81b4dfd1cba8ac04ad2ec13dc946c0442a40c4d3443f4361c;
address constant EXECUTOR = 0x12EAe402fA25B6B656c65fdff06990f29298449B;
bytes32 constant SOLVER_INIT_CODE_HASH = 0x7879770c40f889cb97c1f627779e0f6826b75a66c5105c1815b8fecada29e784;
address constant SOLVER = 0xc6125fD7BCC649103c8453912122cDf6Fe2E9696;

/// The build must produce the pinned init code hash and address. Any change under src/ (a comment too: it
/// changes the metadata hash) changes them: re-run Create2Deploy.s.sol and update the pins and the README table.
contract Create2DeployPinTest is Test {
    function test_executorInitCode_matchesPinned() public pure {
        assertEq(SALT, keccak256("bex-backrun CycleExecutor"), "salt preimage");
        bytes32 initHash = keccak256(executorInitCode());
        assertEq(
            initHash,
            EXECUTOR_INIT_CODE_HASH,
            "stale: re-run Create2Deploy.s.sol:Create2Deploy and update the pinned hash and README table"
        );
        assertEq(create2Address(SALT, initHash), EXECUTOR, "address");
    }

    function test_solverInitCode_matchesPinned() public pure {
        assertEq(SOLVER_SALT, keccak256("bex-backrun CycleSolver"), "salt preimage");
        bytes32 initHash = keccak256(solverInitCode());
        assertEq(
            initHash,
            SOLVER_INIT_CODE_HASH,
            "stale: re-run Create2Deploy.s.sol:Create2DeploySolver and update the pinned hash and README table"
        );
        assertEq(create2Address(SOLVER_SALT, initHash), SOLVER, "address");
    }
}

/// The deploy transaction, built from source, on mainnet state: the canonical deployer creates the executor at
/// the pinned address, with exactly the runtime code RuntimeCode.s.sol exports, and a mined cycle lands there.
contract Create2DeployForkTest is ForkTest {
    bytes32 constant TAG = bytes32(uint256(1));
    address constant USDC_WETH_V3_1BP_POOL = 0xE0554a476A092703abdB3Ef35c80e0D76d32939F;

    function test_canonicalDeployer_deploysExecutorThatLands() public {
        address predicted = EXECUTOR;
        assertGt(CREATE2_DEPLOYER.code.length, 0, "the deployer exists on mainnet");
        assertEq(predicted.code.length, 0, "not deployed yet at the fork block");

        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(bytes.concat(SALT, executorInitCode()));
        assertTrue(ok, "deploy reverted");
        assertEq(address(bytes20(ret)), predicted, "deployer returned the predicted address");

        new RuntimeCode().run();
        assertEq(predicted.code, vm.parseBytes(vm.readFile("out-runtime/executor.hex")), "runtime differs");

        // The mined cycle eth_usdc__v3_500_v3_100, after a 300 WETH push into the USDC/WETH 1bp pool.
        vm.deal(address(this), 300 ether);
        new V3Pusher().push{value: 300 ether}(USDC_WETH_V3_1BP_POOL, false);
        JsonCycle[] memory cycles = abi.decode(vm.parseJson(vm.readFile("test/fixtures/cycles.json")), (JsonCycle[]));
        uint256 k;
        while (keccak256(bytes(cycles[k].name)) != keccak256("eth_usdc__v3_500_v3_100")) ++k; // file order is rank: find it
        JsonCycle memory c = cycles[k];
        Leg[] memory legs = new Leg[](c.legs.length);
        for (uint256 i; i < legs.length; ++i) {
            JsonLeg memory l = c.legs[i];
            legs[i] = Leg(l.version, l.tokenIn, l.tokenOut, l.fee, l.tickSpacing);
        }
        address searcher = makeAddr("create2 test searcher");
        Plan memory p = new CycleSolver(_v()).solve(legs, 0, 0, 9000, searcher, TAG);
        address builder = makeAddr("create2 test coinbase");
        address sender = makeAddr("create2 test sender");
        vm.deal(sender, 1 ether);
        vm.coinbase(builder);
        vm.prank(sender);
        CycleExecutor(payable(predicted)).execute(p);
        uint256 profit = p.amountOut - p.amountIn;
        assertGt(profit, 0);
        assertEq(builder.balance, profit * 9000 / 10000, "coinbase got the share");
        assertEq(searcher.balance, profit - profit * 9000 / 10000, "the recipient got the rest");
        assertEq(sender.balance, 1 ether, "the sender got nothing");
    }
}

/// The solver deploy, built from source, through the real CREATE2 deployer: runtime equals RuntimeCode's solver output and
/// `solve` at the predicted address equals a locally constructed solver's, for 3 mined cycles.
contract Create2DeploySolverForkTest is ForkTest {
    address constant USDC_WETH_V3_1BP_POOL = 0xE0554a476A092703abdB3Ef35c80e0D76d32939F;

    function test_canonicalDeployer_deploysSolverThatSolves() public {
        address predicted = SOLVER;
        assertEq(predicted.code.length, 0, "not deployed yet at the fork block");

        (bool ok, bytes memory ret) = CREATE2_DEPLOYER.call(bytes.concat(SOLVER_SALT, solverInitCode()));
        assertTrue(ok, "deploy reverted");
        assertEq(address(bytes20(ret)), predicted, "deployer returned the predicted address");

        new RuntimeCode().run();
        assertEq(predicted.code, vm.parseBytes(vm.readFile("out-runtime/solver.hex")), "runtime differs");

        CycleSolver local = new CycleSolver(_v());
        vm.deal(address(this), 300 ether);
        new V3Pusher().push{value: 300 ether}(USDC_WETH_V3_1BP_POOL, false);
        JsonCycle[] memory cycles = abi.decode(vm.parseJson(vm.readFile("test/fixtures/cycles.json")), (JsonCycle[]));
        uint256[3] memory pick = [uint256(0), 1, 9];
        uint256 plans;
        for (uint256 k; k < pick.length; ++k) {
            JsonCycle memory c = cycles[pick[k]];
            Leg[] memory legs = new Leg[](c.legs.length);
            for (uint256 i; i < legs.length; ++i) {
                JsonLeg memory l = c.legs[i];
                legs[i] = Leg(l.version, l.tokenIn, l.tokenOut, l.fee, l.tickSpacing);
            }
            bytes memory call_ = abi.encodeCall(CycleSolver.solve, (legs, 0, 0, 10000, address(0), bytes32(0)));
            (bool okL, bytes memory retL) = address(local).staticcall(call_);
            (bool okD, bytes memory retD) = predicted.staticcall(call_);
            assertEq(okD, okL, string.concat("ok differs: ", c.name));
            assertEq(retD, retL, string.concat("return differs: ", c.name));
            if (okL) ++plans;
        }
        assertGt(plans, 0, "no cycle returned a plan");
    }
}

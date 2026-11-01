// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

/// The solver must depend on pool storage and pool immutables alone, so its answer is the same wherever it runs and the
/// builder's caches (which do not track balances, code or the transaction) stay valid for it.
/// Solver side only: CycleExecutor reads balances and code by design and is not scanned.
contract SolverPurityTest is Test {
    function test_solverSourceReadsStorageOnly() public view {
        string[11] memory files = [
            "src/CycleSolver.sol",
            "src/lib/RateFilter.sol",
            "src/lib/InRange.sol",
            "src/Types.sol",
            "src/lib/ClosedForm.sol",
            "src/lib/Pools.sol",
            "src/lib/LegSim.sol",
            "src/lib/V2Reader.sol",
            "src/lib/V3Reader.sol",
            "src/lib/V4Reader.sol",
            "src/lib/StepEdge.sol"
        ];
        string[8] memory banned = ["balanceOf", "gasleft", "block.", "msg.", ".balance", "tx.", ".code", "extcodesize"];
        for (uint256 i; i < files.length; i++) {
            string memory src = vm.readFile(files[i]);
            for (uint256 j; j < banned.length; j++) {
                assertFalse(vm.contains(src, banned[j]), string.concat(files[i], ": ", banned[j]));
            }
        }
    }
}

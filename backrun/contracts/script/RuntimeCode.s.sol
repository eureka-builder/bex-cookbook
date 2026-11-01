// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CycleSolver} from "../src/CycleSolver.sol";
import {CycleExecutor} from "../src/CycleExecutor.sol";
import {Venues} from "../src/Types.sol";
import {venuesFromEnv} from "./Deploy.s.sol";

/// Writes the RUNTIME code of a constructed solver and executor (immutables filled) to
/// out-runtime/{solver,executor}.hex. No broadcast: the contracts exist only in the script's EVM.
/// Same env as Deploy.s.sol. Both depend only on the venues: no owner, no deployer address.
///   forge script script/RuntimeCode.s.sol
contract RuntimeCode is Script {
    function run() external {
        Venues memory v = venuesFromEnv(vm);
        _write("solver", address(new CycleSolver(v)).code);
        _write("executor", address(new CycleExecutor(v)).code);
    }

    function _write(string memory name, bytes memory code) internal {
        string memory path = string.concat("out-runtime/", name, ".hex");
        vm.createDir("out-runtime", true);
        vm.writeFile(path, vm.toString(code));
        console.log("%s: %s bytes, keccak %s", path, code.length, vm.toString(keccak256(code)));
    }
}

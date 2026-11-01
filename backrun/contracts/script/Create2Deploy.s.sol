// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {CycleExecutor} from "../src/CycleExecutor.sol";
import {CycleSolver} from "../src/CycleSolver.sol";
import {MainnetVenues} from "../src/Types.sol";

// Fixed salts, so each contract's address depends only on its init code.
bytes32 constant SALT = keccak256("bex-backrun CycleExecutor");
bytes32 constant SOLVER_SALT = keccak256("bex-backrun CycleSolver");

// The canonical CREATE2 deployer. Same as forge-std's CREATE2_FACTORY, which a free function cannot use.
address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

/// Creation code ++ abi.encode(mainnet venues): the executor's constructor takes only the venues.
function executorInitCode() pure returns (bytes memory) {
    return bytes.concat(type(CycleExecutor).creationCode, abi.encode(MainnetVenues.get()));
}

/// Same for the solver.
function solverInitCode() pure returns (bytes memory) {
    return bytes.concat(type(CycleSolver).creationCode, abi.encode(MainnetVenues.get()));
}

/// Where the canonical deployer puts a contract: keccak256(0xff ++ deployer ++ salt ++ initHash)[12:].
function create2Address(bytes32 salt, bytes32 initHash) pure returns (address) {
    return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initHash)))));
}

/// A deploy through the canonical CREATE2 deployer: a plain transaction to it with data = salt ++ init code
/// creates the contract at create2Address(salt, keccak256(init code)). Anyone can send it, from any account;
/// the address is the same. Prints the transaction and writes it to deploy/out/<file> (not committed) for
/// deploy/metamask.html. Broadcasts nothing.
abstract contract Create2DeployBase is Script {
    function _emit(string memory name, bytes32 salt, bytes memory init, string memory file) internal {
        bytes32 initHash = keccak256(init);
        address predicted = create2Address(salt, initHash);
        bytes memory data = bytes.concat(salt, init);

        console.log("DEPLOYER=%s", CREATE2_DEPLOYER);
        console.log("SALT=%s", vm.toString(salt));
        console.log("INIT_CODE_HASH=%s", vm.toString(initHash));
        console.log("TX_DATA_BYTES=%s", data.length);
        console.log("%s=%s", name, predicted);

        string memory k = file;
        vm.serializeUint(k, "chainId", 1);
        vm.serializeAddress(k, "to", CREATE2_DEPLOYER);
        vm.serializeBytes32(k, "salt", salt);
        vm.serializeBytes32(k, "initCodeHash", initHash);
        vm.serializeAddress(k, "address", predicted);
        vm.serializeBytes(k, "constructorArgs", abi.encode(MainnetVenues.get()));
        vm.createDir("deploy/out", true);
        string memory path = string.concat("deploy/out/", file);
        vm.writeJson(vm.serializeBytes(k, "data", data), path);
        console.log("wrote %s", path);
    }
}

/// The mainnet executor: forge script script/Create2Deploy.s.sol:Create2Deploy
contract Create2Deploy is Create2DeployBase {
    function run() external {
        _emit("EXECUTOR", SALT, executorInitCode(), "deploy-tx.json");
    }
}

/// The mainnet solver (optional: code mode needs no deployed solver).
///   forge script script/Create2Deploy.s.sol:Create2DeploySolver
contract Create2DeploySolver is Create2DeployBase {
    function run() external {
        _emit("SOLVER", SOLVER_SALT, solverInitCode(), "deploy-solver-tx.json");
    }
}

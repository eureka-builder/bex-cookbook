// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {CycleSolver} from "../src/CycleSolver.sol";
import {CycleExecutor} from "../src/CycleExecutor.sol";
import {Venues, MainnetVenues} from "../src/Types.sol";

/// Mainnet venues, each field replaced by its env var when set (another chain's Uniswap deployment).
/// Logs the six values it uses.
function venuesFromEnv(Vm vm) view returns (Venues memory v) {
    v = MainnetVenues.get();
    v.v2Factory = vm.envOr("V2_FACTORY", v.v2Factory);
    v.v2InitHash = vm.envOr("V2_INIT_HASH", v.v2InitHash);
    v.v3Factory = vm.envOr("V3_FACTORY", v.v3Factory);
    v.v3InitHash = vm.envOr("V3_INIT_HASH", v.v3InitHash);
    v.poolManager = vm.envOr("POOL_MANAGER", v.poolManager);
    v.weth = vm.envOr("WETH", v.weth);
    console.log("V2_FACTORY=%s", v.v2Factory);
    console.log("V2_INIT_HASH=%s", vm.toString(v.v2InitHash));
    console.log("V3_FACTORY=%s", v.v3Factory);
    console.log("V3_INIT_HASH=%s", vm.toString(v.v3InitHash));
    console.log("POOL_MANAGER=%s", v.poolManager);
    console.log("WETH=%s", v.weth);
}

/// Deploys both contracts with CREATE from the broadcasting account (the address depends on its
/// nonce). For the one shared mainnet executor, use Create2Deploy.s.sol instead.
///   forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore> --broadcast
contract Deploy is Script {
    function run() external {
        Venues memory v = venuesFromEnv(vm);
        require(v.weth.code.length > 0, "WETH has no code on this chain");
        require(v.poolManager.code.length > 0, "POOL_MANAGER has no code on this chain");
        vm.startBroadcast();
        CycleSolver solver = new CycleSolver(v);
        CycleExecutor executor = new CycleExecutor(v);
        vm.stopBroadcast();
        console.log("SOLVER=%s", address(solver));
        console.log("EXECUTOR=%s", address(executor));
    }
}

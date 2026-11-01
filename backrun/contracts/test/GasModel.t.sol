// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {ExecutorFork, TxProbe} from "./CycleExecutor.t.sol";
import {LegSim} from "../src/lib/LegSim.sol";
import {_v} from "./Fork.t.sol";
import {Leg, Plan} from "../src/Types.sol";

/// The solver's execute gas model against measured execute gas, at FORK_BLOCK. The model's gas is the plan's
/// floor at weiPerGas = 1 (minProfitWei 0). The measured gas is one `execute` as its own transaction (intrinsic
/// gas and calldata included) plus the operator's 21,000-gas refill. Only real with each call its own
/// transaction (cold slots, real SSTORE prices), so the test skips without --isolate:
///   ETH_RPC_URL=<archive rpc> forge test --isolate --match-path test/GasModel.t.sol -vv
contract GasModelTest is ExecutorFork {
    uint256 constant REFILL = 21_000;
    /// The model's tolerance: within 25% of the measured gas.
    uint256 constant TOLERANCE = 0.25e18;

    /// The plan of `legs` at weiPerGas 1, its modelled gas and its measured gas.
    function _measure(Leg[] memory legs, string memory name) internal returns (uint256 model, uint256 measured) {
        Plan memory p = solver.solve(legs, 0, 1, 9000, address(0), TAG);
        model = p.minProfit;
        (, uint8 crossings, uint8 steps,) = LegSim.tryCycleOut(_v(), p.legs, p.amountIn);
        measured = executeAndCheck(p, 2_000_000) + REFILL;
        emit log_string(name);
        emit log_named_uint("  steps", steps);
        emit log_named_uint("  crossings", crossings);
        emit log_named_uint("  measured", measured);
        emit log_named_uint("  model", model);
        emit log_named_int("  error (bp)", (int256(model) - int256(measured)) * 10000 / int256(measured));
    }

    function _check(Leg[] memory legs, string memory name) internal {
        (uint256 model, uint256 measured) = _measure(legs, name);
        assertApproxEqRel(model, measured, TOLERANCE, name);
    }

    /// _check of a plan that crosses no initialized tick.
    function _inRange(Leg[] memory legs, string memory name) internal {
        Plan memory p = solver.solve(legs, 0, 0, 9000, address(0), TAG);
        (, uint8 crossings,,) = LegSim.tryCycleOut(_v(), p.legs, p.amountIn);
        assertEq(crossings, 0, string.concat("precondition: in range, ", name));
        _check(legs, name);
    }

    /// In-range 2-, 3- and 5-leg plans, a plan that crosses one tick, and the CYCLE_BUDGET corners of LegSim
    /// (mixed crossings of ticks with history, empty steps only). G_CROSS is calibrated on ticks with history: a
    /// fresh tick (first crossing writes two fee slots from zero) is under-priced, by design. The builder checks
    /// net > 0 at the real gas.
    function test_gasModel_withinQuarterOfMeasured() public {
        TxProbe t = new TxProbe();
        t.set();
        if (t.get() != 0) vm.skip(true); // not isolated: the gas is warm

        uint256 snap = vm.snapshotState();
        pushUsdcWeth(10 ether);
        _inRange(cycleV3V3(), "in range, 2 legs V3 V3");
        vm.revertToState(snap);
        pushV2UsdcWeth(10 ether);
        _inRange(cycleV3V2(), "in range, 2 legs V3 V2");
        vm.revertToState(snap);
        pushV3(USDT_WETH_V3_1BP, true, 2 ether);
        _inRange(cycleV3V4V3(), "in range, 3 legs V3 V4 V3");
        vm.revertToState(snap);
        pushUsdcWeth(4 ether);
        _inRange(cycleFive(), "in range, 5 legs");
        vm.revertToState(snap);
        pushUsdcWeth(16 ether);
        _check(cycleV3V3(), "one crossing, 2 legs V3 V3");
        vm.revertToState(snap);
        pushUsdcWeth(10 ether);
        _check(cycleV4V3(), "one crossing, 2 legs V4 V3");
        vm.revertToState(snap);
        pushUsdcWeth(3000 ether);
        _check(cycleFive(), "budget corner, mixed crossings, 5 legs");
        vm.revertToState(snap);
        pushV3(USDT_WETH_V3_1BP, true, PUSH);
        _check(cycleV3V4V3(), "budget corner, mixed crossings, 3 legs");
        vm.revertToState(snap);
        _check(emptyStepsCycle(3), "budget corner, empty steps, 3 legs");
        vm.revertToState(snap);
        _check(emptyStepsCycle(5), "budget corner, empty steps, 5 legs");
        vm.revertToState(snap);
        seedFreshTicks();
        (uint256 model, uint256 measured) = _measure(cycleFiveFresh(), "budget corner, fresh ticks, 5 legs");
        assertLt(model, measured, "fresh ticks: under-priced");
    }
}

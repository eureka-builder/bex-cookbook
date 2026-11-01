// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Leg, Venues, TooManyCrossings} from "../src/Types.sol";
import {LegSim} from "../src/lib/LegSim.sol";
import {RateFilter} from "../src/lib/RateFilter.sol";

/// Exact probes the tests use and the solver does not.
library LegProbe {
    /// One leg on its own. Reverts TooManyCrossings past MAX_TICK_CROSSINGS or MAX_STEPS.
    function amountOut(Venues memory v, Leg memory leg, uint256 amountIn)
        internal
        view
        returns (uint256 out, uint8 crossings)
    {
        bool ok;
        (out, crossings,, ok) = LegSim.legOut(v, leg, amountIn);
        if (!ok) revert TooManyCrossings();
    }

    /// Reverts TooManyCrossings where LegSim.tryCycleOut is infeasible.
    function cycleOut(Venues memory v, Leg[] memory legs, uint256 amountIn)
        internal
        view
        returns (uint256 out, uint8 crossings)
    {
        bool ok;
        (out, crossings,, ok) = LegSim.tryCycleOut(v, legs, amountIn);
        if (!ok) revert TooManyCrossings();
    }

    /// The leg's in-range virtual reserves and fee factor (RateFilter.virtualReserves on its quote).
    function virtualReserves(Venues memory v, Leg memory leg)
        internal
        view
        returns (uint256 reserveIn, uint256 reserveOut, uint256 gammaE6)
    {
        return RateFilter.virtualReserves(RateFilter.quote(v, leg));
    }
}

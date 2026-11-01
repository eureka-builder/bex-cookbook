//! The contract ABI the bot uses: `Leg`, `Plan` and `Venues` of `contracts/src/Types.sol`, and the
//! `CycleSolver` and `CycleExecutor` functions and event, and the custom errors the bot names.
use alloy::sol;

sol! {
    struct Leg { uint8 version; address tokenIn; address tokenOut; uint24 fee; int24 tickSpacing; }
    struct Venues { address v2Factory; bytes32 v2InitHash; address v3Factory; bytes32 v3InitHash; address poolManager; address weth; }
    error NoProfit();
    error TooManyCrossings();
    error BadLeg();

    struct Plan { uint256 amountIn; uint256 amountOut; uint256 minProfit; uint16 builderShareBps; address recipient; bytes32 tag; Leg[] legs; }

    interface ICycleSolver {
        function solve(Leg[] legs, uint256 minProfitWei, uint256 weiPerGas, uint16 builderShareBps, address recipient, bytes32 tag) external view returns (Plan memory);
        function solveMany(Leg[][] cycles, uint256[] minProfitWei, uint256 weiPerGas, uint16 builderShareBps, address recipient, bytes32 tag) external view returns (Plan memory);
    }

    interface ICycleExecutor {
        function execute(Plan plan) external;
        /// Also on `CycleSolver`, same selector.
        function venues() external view returns (Venues memory);
        /// `tag`: the sender's self-declared label (`request::tag`), not authenticated.
        event CycleExecuted(bytes32 indexed cycleId, bytes32 indexed tag, uint256 amountIn, uint256 profit, uint256 paidToCoinbase);
    }
}

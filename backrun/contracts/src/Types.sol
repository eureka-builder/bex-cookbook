// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

struct Leg {
    uint8 version;
    address tokenIn;
    address tokenOut;
    uint24 fee;
    int24 tickSpacing;
}

struct Plan {
    uint256 amountIn;
    /// The solver's expected output. Informational: the executor never reads it.
    uint256 amountOut;
    uint256 minProfit;
    uint16 builderShareBps;
    /// Who gets the profit after the builder's share. address(0): the caller of `execute`. Under BEX
    /// the caller is the builder's operator key, so a searcher names itself here. A recipient that
    /// refuses ETH reverts the whole `execute`.
    address recipient;
    /// The caller's label, echoed by `solve` and emitted by `execute`. Not authenticated: anyone can
    /// send any tag. It attributes landings in stats; it never moves funds.
    bytes32 tag;
    Leg[] legs;
}

error NoProfit();
error TooManyCrossings();
error BadLeg();
error ProfitBelowPlan();
error UnexpectedCallback();

uint8 constant V2 = 2;
uint8 constant V3 = 3;
uint8 constant V4 = 4;

/// The chain-specific addresses everything is derived from.
struct Venues {
    address v2Factory;
    bytes32 v2InitHash;
    address v3Factory;
    bytes32 v3InitHash;
    address poolManager;
    address weth;
}

/// Ethereum mainnet: the default.
library MainnetVenues {
    function get() internal pure returns (Venues memory) {
        return Venues({
            v2Factory: 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f,
            v2InitHash: 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f,
            v3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
            v3InitHash: 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54,
            poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2
        });
    }
}

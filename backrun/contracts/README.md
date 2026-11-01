# bex-backrun contracts

> Unaudited, experimental demo. Use at your own risk.

Two contracts, no shared state. In a BEX request, the builder `staticcall`s `CycleSolver` as the compute step,
then sends `CycleExecutor.execute(plan)` as the execute step, signed with its own key.

| File | What |
|---|---|
| `src/CycleSolver.sol` | `solve` and `solveMany`: the best input for a cycle, from pool state alone. |
| `src/CycleExecutor.sol` | `execute(Plan)`: runs the cycle as a flash chain and pays the profit. `sweep(token)`. |
| `src/Types.sol` | `Leg`, `Plan`, `Venues`, the errors, the mainnet venues. |
| `src/lib/Pools.sol` | Pool addresses and ids, and `validate`, the cycle rules both contracts use. |
| `src/lib/RateFilter.sol` | One read per pool (`Quote`), the marginal-rate product rho, the orientation flip. |
| `src/lib/ClosedForm.sol` | The optimal input of a chain of constant-product pools. |
| `src/lib/InRange.sol` | The exact output of a cycle that stays inside every active tick range. |
| `src/lib/LegSim.sol` | The exact Uniswap swap loop, with the cycle-wide gas budget. |
| `src/lib/StepEdge.sol` | The step-edge refinement for coarse tokens. |
| `src/lib/V2Reader.sol`, `V3Reader.sol`, `V4Reader.sol` | Pool state reads and the tick bitmap math. |
| `script/` | `RuntimeCode.s.sol` (runtime code for code mode), `Create2Deploy.s.sol`, `Deploy.s.sol`. |
| `deploy/` | The MetaMask page for the CREATE2 deploys. `deploy/out/` holds the generated transactions (not committed). |

`CycleExecutor.sol`, `Types.sol`, `lib/Pools.sol`, `lib/V2Reader.sol` and `interfaces/` are the sources of the
deployed executor. A change to any of them, a comment too, changes the executor's metadata hash, its init code
and its CREATE2 address. Then this repo no longer builds the deployed code. Document the executor here instead.

## The solver interface

- `solve(Leg[] legs, uint256 minProfitWei, uint256 weiPerGas, uint16 builderShareBps, address recipient, bytes32 tag) view returns (Plan)`:
  reads pool storage and pool immutables only and returns the best input for one cycle: the most profit over the
  plan's floor, the larger of `minProfitWei` and `weiPerGas` times the plan's modelled execute gas (see
  [Gas model](#gas-model)). It copies `builderShareBps`, `recipient` and
  `tag` into the plan unchanged (see [Recipient](#recipient) and [Tag](#tag)). The plan's `minProfit` is its floor: the larger
  of `minProfitWei` and `weiPerGas` times the plan's modelled gas, at least 1. Send as `weiPerGas` the profit that
  each unit of execute gas must earn (0: no gas pricing, the floor is `minProfitWei`). It returns a plan or reverts:
  - `BadLeg`: the cycle is malformed (at least 2 legs, a known version, a connected chain from and back to ETH/WETH,
    every leg a distinct pool, no native ETH on V2/V3, no WETH on V4, V2 fee 3000 with tick spacing 0).
  - `NoProfit`: no input within the gas budgets clears the floor, or `weiPerGas` or `minProfitWei` is 2^128 or more. Inputs that cross
    too many ticks are not an error: the search skips them and returns the best input that fits (`TooManyCrossings`
    never leaves `solve`).
  - A leg whose pool does not exist reverts with empty data (V2/V3). A V4 pool that does not exist gives
    `NoProfit`. The executor checks pools first and reverts `BadLeg`.
  - Transfer-tax tokens: the solver assumes each leg receives what the previous leg sent. When an intermediate
    token takes a tax on transfer, `Plan.amountOut` is nominal: `execute` funds each leg with what arrived, gets
    less out, and reverts `ProfitBelowPlan`. Nothing is lost, but the cycle never lands. `cycles/build.py` keeps
    such tokens out through `EXCLUDED_TOKENS`, and `test_mainnetCycles_noTransferTax` (`EndToEnd.t.sol`) finds new
    ones after a re-mine.
- `solveMany(Leg[][] cycles, uint256[] minProfitWei, uint256 weiPerGas, uint16 builderShareBps, address recipient, bytes32 tag) view returns (Plan)`: the
  same solve for 1 to 8 cycles, one `minProfitWei` each and one `weiPerGas` for all. It returns the plan with the
  largest margin over its own floor, `amountOut - amountIn - minProfit` (ties: the first), or `NoProfit`. So a cycle
  with more gas wins only if it nets more. A cycle whose solve reverts (a shape error, a dead pool) is skipped. No
  cycles, more than 8, or a floor count that differs from the cycle count: `BadLeg`.
- `venues() view returns (Venues)`: the factories, init code hashes, PoolManager and WETH it was built with.

## How CycleSolver works

The steps are in the comment above `contract CycleSolver`:

1. Validate the cycle (`Pools.validate`) and read each pool once (`RateFilter.quotes`).
2. Compute rho, the product of the marginal rates (spot price times fee factor) around the cycle. The profit is
   concave in the input, so an arbitrage exists only if rho is above 1. At most one orientation can be live,
   because `rho_forward * rho_reverse` is the product of the fee factors, below 1. If only the reverse is live, the
   solver quotes the reversed legs again (warm reads), solves them and returns them in the plan. Neither: `NoProfit`.
   A pool with no active liquidity (its price in a gap between ranges) is not dead: its spot rate is the best a
   swap can get, and the walk (step 5) moves through the gap to the liquidity behind it.
3. Fold the in-range virtual reserves into one curve `a·x / (b + c·x)` and take its optimum in closed form
   (`ClosedForm`). The fold rounds so that the model never pays less than the pools.
4. If that input is above 0 and stays inside every pool's active tick range (one bitmap word per pool, `InRange.limits`), compute
   the exact output with the pool's own swap step (`InRange.stepOut`) and return that plan.
5. Else walk forward from input 0, region by region (`_walk`). A pool with no active liquidity first moves through
   its gap, as the exact swap of any input does. A region ends where a pool reaches its next
   initialized tick. Inside a region every pool is a constant-product curve, so the closed form on the walk's end
   state is the exact optimum there. If that optimum is inside the region, the walk stops at it. Else the walk keeps
   the point just before the boundary as a candidate and crosses the tick with resumed swaps (`LegSim.advance`).
   The pools' boundaries are scanned together in input order, so the walk also stops before the word end that
   would pass the crossing budget. At most 32 regions (`MAX_REGIONS`). Each candidate's net is its profit less
   its floor: the larger of `minProfitWei` and `weiPerGas` times its modelled gas, the margin `solveMany` ranks
   plans by. Gas jumps at each crossing, so a crossing that adds less profit than it costs is not taken, and a
   candidate below `minProfitWei` never beats one above it. The plan is the candidate with the best net that one exact simulation
   (`LegSim.tryCycleOut`) confirms, after at most 2 earlier ones. Its output is that simulation's, and so are the
   steps and crossings that price its gas. Through a coarse token a small cross step can move nothing (the leg
   floors its output to whole units). Then every later step is at least 16 times that step (`BACKOFF`).
6. If an in-range plan clears `minProfitWei` and an intermediate token is coarse (one unit worth 2^32 wei or more,
   such as an 8-decimal BTC), `StepEdge.refine` moves the input to the best nearby step edge, never to a lower
   profit, and only to an edge where the whole cycle stays in range. So the plan stays in range and its gas is the
   in-range gas. A walk plan is not refined.
7. The plan's floor is the larger of `minProfitWei` and `weiPerGas` times the gas of the final input, at least 1. A
   profit below it: `NoProfit`.

Solve gas by path, from the tests:

| Path | Gas |
|---|---|
| Neither orientation live | under 60k (`test_gas_threeLegsNoCrossing_under60k`) |
| In range, below the floor | under 70k |
| In-range plan | under 150k (`test_gas_inRangePlan_under150k`) |
| Walk with one or two crossings | under 400k (`test_gas_oneCrossingPlan_under400k`) |
| Walk up to the crossing budget, 22 crossings | about 2.4M (`test_regionWalk_budgetStopsAtLastFeasible`) |
| Worst case by construction: 5 legs walk to the budget through initialized ticks and empty bitmap words | 5,378,631; with a coarse token in front, 5,819,961 (`test_worstCaseWalk_underComputeCap`) |
| Largest mined cycle in a quiet market | 1,324,727 on `eth_usdc_chex__v4_100_v4_100_v4_10000` (`test_quietMarket_everyMinedCycle_eitherNoProfitOrExecutable`) |
| `solveMany` | at most 1.1 times the sum of separate solves (`test_solveMany_gas_underSumOfParts`) |

The cost of one solve is bounded by construction. A walk plan takes at most `MAX_REGIONS` regions inside
`CYCLE_BUDGET`, then at most 3 exact simulations. An in-range plan runs no walk and no exact simulation: StepEdge
works on the pool reads. The tests hold every solve under `MAX_COMPUTE_GAS` = 6,000,000 gas (`test/Fork.t.sol`): the
worst case above, built from settable pools, and every mined cycle at `FORK_BLOCK`. A `solveMany` group costs up
to the sum of its cycles' solves, at most 8 cycles.

Known limit: when the walk stops at the budget behind a coarse token, its best candidate can fail the exact check
and the plan falls back one region. The walk's sub-swaps through the coarse leg each lose up to one unit (about
3e11 wei for an 8-decimal BTC), so the exact swap reaches a little further than the walk. In
`test_regionWalk_coarseIntermediate_crossesToTheBudget` that costs about 6% of the profit. On the mined cycles at
`FORK_BLOCK` no solve reverts `TooManyCrossings`.

The solver reads pool storage and pool immutables only (V3 `fee()` and `tickSpacing()`): no balances, no block context, no gas. The builder caches computes
that read storage only, so the same calldata on the same pool state gives the same bytes. `SolverPurity.t.sol`
scans the solver sources for the words that would break this: a text check, not a proof.

### Gas model

The solver models the gas of `execute` (as its own transaction) plus the operator's 21,000-gas refill:

```
gas = G0 + one base per leg (G_V2, G_V3 or G_V4) + G_STEP * steps + G_CROSS * crossings
```

`steps` are the swap-loop steps on the V3 and V4 legs (a crossing step included) and `crossings` the initialized
ticks crossed. In range that is one step per V3 or V4 leg and no crossing. Otherwise the solver takes both from
the exact simulation of the plan's input. The constants are fitted at `FORK_BLOCK` (next to them in
`CycleSolver.sol`):

| Constant | Gas | Fitted on |
|---|---|---|
| `G0` | 133,000 | the in-range 2-leg V3 plan: intrinsic gas, calldata, the refill, the flash and the payouts |
| `G_V2` | 57,000 | the in-range 2-leg V3 V2 plan |
| `G_V3` | 74,500 | the in-range 3-leg and 5-leg plans (2 more V3 legs) |
| `G_V4` | 95,000 | the in-range 3-leg V3 V4 V3 plan |
| `G_STEP` | 7,300 | the empty-step corner: 3 legs, 180 steps |
| `G_CROSS` | 20,000 | the mixed corner: 5 legs, 15 crossings of ticks with history |

`test_gasModel_withinQuarterOfMeasured` (`GasModel.t.sol`) checks the model against the measured gas, within 25%:

| Case | Measured | Model | Error |
|---|---|---|---|
| In range, 2 legs V3 V3 | 297,082 | 296,600 | -0.2% |
| In range, 2 legs V3 V2 | 272,610 | 271,800 | -0.3% |
| In range, 3 legs V3 V4 V3 | 399,313 | 398,900 | -0.1% |
| In range, 5 legs | 563,023 | 562,500 | -0.1% |
| One crossing, 2 legs V3 V3 | 326,669 | 323,900 | -0.8% |
| One crossing, 2 legs V4 V3 | 322,099 | 344,400 | +6.9% |
| Budget corner, mixed crossings, 5 legs | 1,375,287 | 1,373,500 | -0.1% |
| Budget corner, mixed crossings, 3 legs | 1,259,644 | 1,288,600 | +2.3% |
| Budget corner, empty steps, 3 legs | 1,669,154 | 1,670,500 | +0.1% |
| Budget corner, empty steps, 5 legs | 1,856,204 | 1,819,500 | -2.0% |
| Budget corner, fresh ticks, 5 legs (not checked) | 1,793,356 | 1,135,800 | -36.7% |

A fresh tick (initialized above the price and never crossed) costs more to cross, because its first crossing
writes two fee slots from zero. The model prices every crossing as one with history, so it under-prices fresh
ticks. The builder signs `execute` only when the coinbase gains more than the real gas, so such a plan is not
placed at a loss. The measurement is real only with each call its own transaction:

```sh
ETH_RPC_URL=<archive rpc> forge test --isolate --match-path test/GasModel.t.sol -vv
```

Without `--isolate` the test skips.

## How CycleExecutor works

`execute(Plan)`:

1. Refuse re-entry, validate the legs (`Pools.validate`), refuse `builderShareBps > 10000` and
   `amountIn >= 2^128`, and check that every pool exists (`BadLeg`).
2. Record the ETH + WETH holdings. Run the chain:
   - Leg 0 is a flash swap: the pool sends its output first. A V2 pair calls `uniswapV2Call`, a V3 pool calls
     `uniswapV3SwapCallback`, the V4 PoolManager calls `unlockCallback`.
   - Inside that callback, legs 1 to n-1 run, each funded with what the previous leg actually delivered (the
     balance increase, not the nominal amount). V2 legs get the input sent first. V3 legs pay in their callback.
     V4 legs swap, `take` the output and `settle` the input inside one `unlock`.
   - The last leg's output repays leg 0. If it is less than leg 0 owes: `ProfitBelowPlan`.
   - Between a V4 leg (native ETH) and a V2/V3 leg (WETH), the executor wraps or unwraps.
3. If the holdings grew by less than `plan.minProfit`: `ProfitBelowPlan`. Else the profit is the growth. Unwrap
   WETH as needed, pay `profit * builderShareBps / 10000` to `block.coinbase` and the rest to `plan.recipient`, or
   to `msg.sender` when the recipient is `address(0)`, in ETH. A payee that refuses ETH reverts the call
   (`TipFailed`, `RemainderFailed`).
4. Emit `CycleExecuted(cycleId, tag, amountIn, profit, paidToCoinbase)`. `cycleId` is
   `keccak256(abi.encode(legs))` of the legs that ran (the reversed legs if the solver flipped the cycle).

Callbacks are authenticated with transient storage (EIP-1153). Before each call that must call back, the executor
stores the one pool it expects and the leg index. A callback from any other address, or for another leg, reverts
`UnexpectedCallback`, and each expectation is used once. Pool addresses come only from the canonical factories
(CREATE2) and the fixed PoolManager. `execute` and `sweep` revert while a cycle runs, also during the payouts.

The executor never reads `plan.amountOut`. The only economic check is `minProfit`. A stale plan that still clears
it executes and pays the realised profit. A partial fill (a V3 or V4 leg that stops at the price limit) can leave
an intermediate token in the contract. `sweep(token)` sends it to `block.coinbase`.

| Revert | When |
|---|---|
| `BadLeg` | A shape rule fails, `builderShareBps > 10000`, `amountIn >= 2^128`, or a pool does not exist. |
| `UnexpectedCallback` | Re-entry into `execute` or `sweep`, or a callback from an address or for a leg the executor does not expect. |
| `ProfitBelowPlan` | The chain returns less than leg 0 owes, or the profit is under `minProfit`. |
| `TipFailed`, `RemainderFailed` | `block.coinbase` or the recipient (`msg.sender` at `address(0)`) refuses the ETH. |
| A pool's or token's own error | For example a V2 `K` check after a transfer tax on the way into the pool. |

Every revert undoes everything: no funds move.

## Gas budget

The builder runs `execute` with at most 2M gas. The solver only returns plans within one cycle-wide budget in `LegSim`: `CYCLE_BUDGET` units, summed over the legs, one per swap-loop step and `W_CROSS` (7) more per initialized tick crossed. Both cost about 7k gas per unit in `execute`. At this budget the worst measured `execute` is about 1.83M gas as its own transaction: 5 legs of empty steps only. Fresh-tick crossings only (ticks initialised above the price and never crossed, so each crossing writes two fee slots from zero) measure about 1.77M on 5 legs. `validate` puts no upper bound on the leg count: the budget is the ceiling, and these measurements cover cycles of up to 5 legs. They are measured worst cases, not a guarantee. The calibration numbers are next to the constants. To re-measure (each call its own transaction, so slots are cold):

```sh
ETH_RPC_URL=<archive rpc> forge test --isolate --match-test 'test_cycleBudget|test_freshTick' -vv
```

Without `--isolate` the push, the solve and the execute share one transaction and the gas figures are warm (too low).

## What the builder sends

Calldata is `execute.selector || abi.encode(Plan)`. The builder computes with the solver, then prepends the executor selector to the raw compute return. `prefixArgs` stays empty. `EndToEnd.t.sol` proves this equals `abi.encodeCall(executor.execute, (plan))` byte for byte.

## Tests

```sh
cd contracts
forge test                                  # no fork: 66 tests pass, the 10 fork suites skip
ETH_RPC_URL=<archive rpc> forge test -vv    # fork suites, pinned to FORK_BLOCK (test/ForkBlock.sol)
```

`FORK_BLOCK=<n>` overrides the pinned block. `test/fixtures/cycles.json` holds the mined cycles that `EndToEnd.t.sol` replays.

## Deploy

```sh
ETHERSCAN_API_KEY=<key> \
  forge script script/Deploy.s.sol --rpc-url $ETH_RPC_URL --account <keystore-name> --broadcast --verify
```

Sign with `--account <name>` (a `cast wallet import` keystore) or `--private-key $DEPLOYER_KEY`. `--verify` needs `ETHERSCAN_API_KEY`. Drop both `--broadcast` and `--verify` for a dry run. Prints `SOLVER=0x…` and `EXECUTOR=0x…`.

Venue addresses default to Ethereum mainnet. For another chain (a devnet with its own Uniswap deployment) set any of these. Each overrides one field, and the script logs the six values it uses:

| Env | Meaning |
|---|---|
| `V2_FACTORY`, `V2_INIT_HASH` | Uniswap V2 factory and its pair init code hash |
| `V3_FACTORY`, `V3_INIT_HASH` | Uniswap V3 factory and its pool init code hash |
| `POOL_MANAGER` | Uniswap V4 PoolManager |
| `WETH` | Wrapped ether |

Both contracts store these as immutables. `venues()` returns them.

`Deploy.s.sol` deploys from your account with CREATE, so the address depends on that account's nonce. For the one shared mainnet executor, use the CREATE2 deploy below.

### Mainnet executor through the canonical CREATE2 deployer

The executor's address is fixed by its init code only: anyone who sends the same transaction gets the same contract at the same address, and the sender gets no rights over it.

| | |
|---|---|
| Deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` (the deterministic deployment proxy) |
| Salt | `keccak256("bex-backrun CycleExecutor")` = `0xffebabef4c1009acbcec8cbbe0e91b69c9bc49516d9c226c2662d1a6faeef318` |
| Init code | `type(CycleExecutor).creationCode ++ abi.encode(MainnetVenues.get())` |
| Init code hash | `0xd19e4522c43d12c81b4dfd1cba8ac04ad2ec13dc946c0442a40c4d3443f4361c` |
| Executor | `0x12EAe402fA25B6B656c65fdff06990f29298449B` = `keccak256(0xff ++ deployer ++ salt ++ keccak256(init code))[12:]`. Deployed on mainnet at block 26319273. |
| Transaction | `to` = deployer, `data` = salt ++ init code (10,787 bytes), no value. Gas used: 2,243,886. |
| Deploy transaction hash | `0xfd404718e0b5f43a2d5ecace9404e614cc351ec55d2f0c46c15529c8d089420a` |

The build uses `remappings.txt` only (`auto_detect_remappings = false` in `foundry.toml`), because remappings go into the metadata hash: a plain and a recursive submodule checkout build the same address. The pins were built with forge 1.5.1 (`foundryup --install 1.5.1`); the metadata settings are explicit in `foundry.toml`. The salt, the init code hash and the address are pinned in `test/Create2Deploy.t.sol`; the transaction itself is generated and not committed. This table is the permanent record of the deploy.

The init code includes the compiler's metadata hash, so ANY change to `src/` (a comment too), to `foundry.toml` or to a library commit changes the address. `test_executorInitCode_matchesPinned` (`Create2Deploy.t.sol`) fails when the build's init code hash or address differs from the pinned constants. Then regenerate the transaction and update the pinned constants and this table:

```sh
forge script script/Create2Deploy.s.sol:Create2Deploy   # prints the init code, salt, tx data and address; writes deploy/out/deploy-tx.json (not committed)
```

`test_canonicalDeployer_deploysExecutorThatLands` (`Create2Deploy.t.sol`, fork) builds salt ++ init code from source, sends it to the deployer on mainnet state, checks that the code at the pinned address equals `out-runtime/executor.hex` from `RuntimeCode.s.sol`, and lands a mined cycle there.

#### Deploy with MetaMask

`deploy/metamask.html` sends `deploy/out/deploy-tx.json` (or `deploy/out/deploy-solver-tx.json` with `?contract=solver`). The forge script writes that file, so run it first. The page is one static file with inline JavaScript and no external scripts. MetaMask does not inject into `file://` pages, so serve the folder:

```sh
cd contracts && forge script script/Create2Deploy.s.sol:Create2Deploy   # writes deploy/out/deploy-tx.json
cd deploy && python3 -m http.server 8000
# open http://localhost:8000/metamask.html
```

1. Compare the boxed executor address and init code hash with the table above. Do this before you confirm anything in MetaMask.
2. Click **Connect MetaMask**. The page stops unless the chain is mainnet (`0x1`). It reads the code at the predicted address. If code is already there, it says so and stops. Compare that code with `out-runtime/executor.hex` (`cast code`).
3. It shows the deployer, the salt, the data length and `eth_estimateGas`.
4. Click **Send deploy transaction**. The page checks the address and then the chain again, right before the wallet prompt. It sends `eth_sendTransaction {from, to: deployer, data, value: "0x0", chainId: "0x1", gas: estimate + 20%}`, so the wallet enforces mainnet and value 0. Confirm in MetaMask. Check that the `to` there is `0x4e59…956C` and the value is 0.
5. After one send, Send stays disabled, including after Connect and after a page reload. The page shows the pending transaction hash and keeps it in `localStorage` for this address. It polls every 3 s and logs a failed poll and retries. It stops when code appears at the predicted address, which also covers a transaction sped up or replaced in MetaMask. Then compare that code with `out-runtime/executor.hex`, or `solver.hex` for the solver (`cast code`, see "Runtime code" below). If the sent transaction reverts, the page forgets it, and a reload allows a new send. To send again after a transaction was dropped, clear this page's site data.

The page does not compute keccak, so it does not re-derive the address from the data. `test_executorInitCode_matchesPinned` does that for the build. Compare the boxed values with the table.

### Mainnet solver through the same deployer

The same mechanism for `CycleSolver` (optional: a builder with `compute.code` runs the solver from the request, see "Runtime code" below, so this deployment is only needed where code mode is not enabled).

| | |
|---|---|
| Deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |
| Salt | `keccak256("bex-backrun CycleSolver")` = `SOLVER_SALT` = `0x564844d8f88d2df87ad7f2f35fdebfdad6624bbd3632461e219f4960f5285dc6` |
| Init code | `type(CycleSolver).creationCode ++ abi.encode(MainnetVenues.get())` |
| Init code hash | `0x7879770c40f889cb97c1f627779e0f6826b75a66c5105c1815b8fecada29e784` |
| Solver | `0xc6125fD7BCC649103c8453912122cDf6Fe2E9696` (not deployed on mainnet) |
| Transaction | `to` = deployer, `data` = salt ++ init code (24,855 bytes), no value. Gas not estimated yet. |
| Deploy transaction hash | none yet |

```sh
forge script script/Create2Deploy.s.sol:Create2DeploySolver   # writes deploy/out/deploy-solver-tx.json (not committed)
```

Open `http://localhost:8000/metamask.html?contract=solver` (serve `deploy/` as in "Deploy with MetaMask" above) and follow the same steps. The page shows the contract name in a box at the top, uses `out/deploy-solver-tx.json`, and keeps its own sent-transaction guard for the solver address. Compare the solver address and init code hash with this table before you confirm.

The solver's address is fixed by its init code: when a solver source changes (a comment too), the code is new and the address changes. The salt stays the same. `test_solverInitCode_matchesPinned` fails until the pinned solver constants in `Create2Deploy.t.sol` are updated. Then update this table too. After a real deploy, put the transaction hash here. `test_canonicalDeployer_deploysSolverThatSolves` (fork) builds the transaction from source, deploys it through the real deployer, compares the code with `out-runtime/solver.hex`, and checks that `solve` at the predicted address equals a locally built solver for 3 mined cycles.

#### Verify on Etherscan

From `contracts/`, with the same `foundry.toml` and library commits:

```sh
forge verify-contract 0x12EAe402fA25B6B656c65fdff06990f29298449B src/CycleExecutor.sol:CycleExecutor \
  --chain mainnet --etherscan-api-key $ETHERSCAN_API_KEY --watch \
  --constructor-args $(jq -r .constructorArgs deploy/out/deploy-tx.json)
```

The constructor argument is the `Venues` struct, ABI-encoded (6 words). It is `constructorArgs` in the generated JSON (run `Create2Deploy` first).

## Runtime code (no solver deploy)

A builder with `compute.code` runs the solver from the request instead of from chain (`bex.compute.code`, see `bot/README.md`). The code sent must be the solver's runtime code with the venue immutables filled in. forge's `deployedBytecode` has zeros where the immutables go, so it reads no pools (`test_forgeDeployedBytecode_hasZeroVenues`). `script/RuntimeCode.s.sol` constructs both contracts in the script EVM (no broadcast, no RPC needed) with the same env as `Deploy.s.sol`, and writes their runtime code as 0x-hex to `out-runtime/solver.hex` and `out-runtime/executor.hex`:

```sh
forge script script/RuntimeCode.s.sol
```

`test_etchedSolver_matchesDeployed` (`RuntimeCode.t.sol`) proves that the etched code returns the same bytes as the deployed solver. The executor has no owner, so `executor.hex` depends only on the venues: with the default (mainnet) venues it is the code that the CREATE2 deploy puts on mainnet. The executor runtime code is only for simulation with state overrides. The executor itself must be a deployed contract, because pools call back into it.

## Safety model

### Who can call execute

Anyone can call `execute`. A plan is a bearer instrument: whoever submits it picks `recipient` and
`builderShareBps`. That is safe because pools come only from the canonical factories and the PoolManager, never
from the caller, the contract gives no approvals, and `execute` pays out only the growth of its own ETH + WETH
holdings. A fork that adds balances, approvals or caller-supplied pools without a sender check makes the contract
drainable.

> Always set `recipient`. With `recipient = 0` the remainder goes to `msg.sender`, which under BEX is the builder's operator, not you.

Before you trust any executor other than the pinned one, check its `venues()`. `Deploy.s.sol` accepts any factory and init code hash.

### Properties

- No owner, no admin key, no kill switch. To stop, stop sending requests. To change the executor, deploy a new version (a new salt or new code is a new address) and point the bot at it.
- The executor keeps no funds of its own between transactions (a leftover waits for `sweep`, below) and never calls `approve`: the first leg is a flash swap,
  repaid from the last leg's output. `execute` pays out all of the profit in the same call: `profit * builderShareBps / 10000` to `block.coinbase`, and the rest to `plan.recipient`, or to `msg.sender` when the recipient is `address(0)`. Both are paid in ETH (WETH is unwrapped first). If either payee cannot take ETH, the whole `execute` reverts (`TipFailed`, `RemainderFailed`). With `builderShareBps = 10000` the remainder is 0 and nothing goes to the recipient.
- In BEX the builder signs the `execute` with its own key, so `msg.sender` is the builder's operator, not the searcher. A searcher sets `recipient` to its own address to be paid (the bot's `payout_address`, default the signer).
- A partial fill can leave an intermediate token here (a V3 or V4 leg that stops at the price limit), and anyone can send tokens to the contract. `sweep(token)` sends the whole balance of `token` (`address(0)` for ETH) to `block.coinbase`, never during a cycle: a pool callback that calls `sweep` reverts `UnexpectedCallback`.
- One executor serves everyone. To tell their cycles apart, senders use the tag.

## Recipient

`Plan.recipient` (`address`, after `builderShareBps`) is who gets the profit after the coinbase's share. `solve` copies it into the plan and does not read it. `execute` pays the remainder to it, or to `msg.sender` when it is `address(0)`. The payout runs with the re-entrancy guard set, so the recipient cannot re-enter `execute` or `sweep`. A recipient that refuses ETH reverts the whole `execute`: the sender chose it, and the cycle never lands until the sender changes it. The recipient is not authenticated: like the tag, anyone can name any address. That only decides where the sender's own remainder goes.

## Tag

`Plan.tag` (`bytes32`, after `recipient`) is a label that the sender chooses. `solve` copies it into the plan and does not read it. `execute` emits it as the second indexed topic of `CycleExecuted(bytes32 indexed cycleId, bytes32 indexed tag, uint256 amountIn, uint256 profit, uint256 paidToCoinbase)`. A sender filters the executor's logs by its own tag (the bot uses its signer address, left-padded to 32 bytes).

The tag is not authenticated. Anyone can send any tag, including yours. It is for attribution and stats only, and it never changes who gets paid: `test_tag_doesNotAffectFunds` runs the same plan under two tags and gets the same payouts.

```sh
cast send $EXECUTOR "sweep(address)" $TOKEN --rpc-url $ETH_RPC_URL --account <any>   # dust to the block's coinbase
```

## Dependencies

`lib/v4-core` is pinned to a commit on `main` (`v4.0.0-22-gbea7f6d`), not to the `v4.0.0` tag. The math libraries the solver uses are identical to `v4.0.0`.


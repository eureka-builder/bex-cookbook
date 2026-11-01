# bex-backrun bot

The searcher. Each block, it sends one BEX request per group of cycles to each builder endpoint. A request asks
the builder to run the solver on its block state and, if the plan pays, to run the executor. The top-level
[`README.md`](../README.md) explains BEX and the quickstart. This file explains the request, the commands, the
settings and what the bot records.

## Build

```sh
cargo build -p bex-backrun --release
```

The binary is `target/release/bex-backrun`. `cargo test -p bex-backrun` runs the tests.

## Code layout

`src/main.rs` lists the modules in the order of the request flow:

| Module | Role |
|---|---|
| `config.rs` | Reads and checks `bot.toml`. |
| `cycles.rs` | Reads and checks `cycles.toml`, with the rules of the contracts. |
| `startup.rs` | The checks before the first request: `bex_capabilities` (code mode) and `venues()` of both contracts. |
| `head.rs` | The stream of new heads: WS `newHeads` with HTTP polling as the fallback. |
| `groups.rs` | Puts cycles that share a pool into one request. |
| `floor.rs` | The `weiPerGas` sent with each cycle, at the next block's basefee. |
| `request.rs` | The request body, the uuid, the code-mode target and the signature. |
| `sender.rs` | Every JSON-RPC call (signed builder calls and plain node calls), and URL redaction. |
| `run.rs` | The send loop of `run`. |
| `store.rs` | The SQLite store of sends and landings. |
| `track.rs` | Reads landings from the chain. |
| `simulate.rs` | The `simulate` command. |
| `status.rs` | The `status` command and the `solve` probe. |

## The request

Each request is one `bex_sendBundle` with two halves, shown here abridged:

```jsonc
{
  "method": "bex_sendBundle",
  "params": [{
    "targetBlock": "0x1234567",          // the next block only
    "replacementUuid": "6f3c…",          // the next block's request replaces this one
    "bex": {
      "compute": {                       // off-chain, on the block's live state
        "code": "0x<solver runtime code>",
        "calldata": "0x<solve(cycle, min profit, wei per gas, profit split)>"
      },
      "execute": {                       // on chain, only when the plan pays
        "to": "0x<executor>",
        "selector": "0x55c63952",        // execute(plan)
        "appendComputeResult": true      // the plan the compute returned
      }
    }
  }]
}
```

The compute returns a plan, or reverts when the cycle has no profit above the floor. The builder appends the plan
to the selector, so the transaction it signs is exactly `execute(plan)`. A signature of the body goes in the
`X-Flashbots-Signature` header. `bex_simulate` takes the same body as a dry run. `src/request.rs` builds the
full body.

## Endpoint limits

The endpoint's limits need no signature:

```sh
curl -s https://rpc.eurekabuilder.xyz -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"bex_capabilities","params":[]}'
```

Example answer:

```json
{"jsonrpc":"2.0","id":1,"result":{"maxCalldataBytes":24576,"maxComputeGas":500000000,"maxExecuteGas":2000000,"computeCodeEnabled":true,"maxComputeCodeBytes":24576}}
```

## Files and env

| File or env var | What it holds |
|---|---|
| `bot.toml` | Endpoints, RPC, contract addresses and send settings. Start from [`bot.example.toml`](bot.example.toml): every setting with a comment. |
| `solver_code` | Code mode: a file with the solver's runtime code as hex (see [Code mode](#code-mode)). |
| `cycles.toml` | The cycles to try, in send order. `cycles/cycles.toml` is the mainnet set, and [`cycles.example.toml`](cycles.example.toml) shows the format. |
| `BEX_SIGNER_KEY` | The signer key, hex. The env var name is `signer_key_env`. A `signer_key` field in `bot.toml` is an error. The bot never logs the key. |

All paths in `bot.toml` are relative to its own directory.

## Cycles

A cycle has 2 or more legs on Uniswap V2, V3 or V4, as many as fit the builder's execute gas limit, and starts
and ends on ETH: `address(0)` on a V4 leg, WETH on a
V2 or V3 leg. One cycle can start on WETH and end on V4 ETH, or the reverse. The executor treats both as one
asset and pays the profit in ETH. At startup the bot refuses a file with a cycle the contracts would refuse
(a wrong field, a broken chain, a pool used twice) and names the cycle and the leg.

A leg is one swap:

```toml
[[cycles]]
name = "eth_usdc__v3_100_v4_100"
legs = [
  { version = 3, token_in = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", token_out = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", fee = 100, tick_spacing = 1 },
  { version = 4, token_in = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", token_out = "0x0000000000000000000000000000000000000000", fee = 100, tick_spacing = 1 },
]
```

- `version` 2, 3 or 4. V2: `fee = 3000`, `tick_spacing = 0`. V3: the fee selects the pool. V4: hookless pools,
  the PoolKey's fee and tick spacing.
- The executor wraps and unwraps between WETH and ETH.

To add a cycle, add an entry and run `simulate`. To add a venue, change both contracts: see
[`contracts/README.md`](../contracts/README.md).

A cycle has a `name` and its `legs`, and no gas figure: the solver prices the gas of the plan it builds. A
`cycles.toml` from an older version, with a `gas_estimate` key, fails to load with serde's "unknown field
`gas_estimate`"; delete the key.

## Commands

All commands take `--config <bot.toml>` (default `bot.toml`) and `--cycles <cycles.toml>` (default `cycles.toml`).

### Startup checks

`run` and `simulate` check two things before the first request, and stop with an error that says what to fix:

1. Code mode: every endpoint's `bex_capabilities` must report `computeCodeEnabled: true` and a
   `maxComputeCodeBytes` at or above the size of `solver_code`. A builder without this feature ignores
   `compute.code`, runs the empty target, and every request fails with no error. So the bot stops instead.
2. `venues()` of the solver and of the executor must be equal in all six fields (factories, init hashes,
   PoolManager, WETH), and their WETH must be `weth` in `bot.toml`. In code mode the solver's `venues()` runs on
   `solver_code` through an `eth_call` state override.

### `simulate`

```sh
bex-backrun simulate [--endpoint <url>]
```

It dry-runs each cycle alone with `bex_simulate` at the current head, one call at a time, at most 5 calls per
second. It prints one row per cycle, then `accepted N  no-profit N  failed N`. The exit code is 1 if a cycle
failed. Run `simulate` first, and fix every failure before `run`.

The builder reports every compute revert as the same issue, `Compute reverted`. When the builder also returns
`compute.revertData`, `simulate` names the revert from it (`[NoProfit (0xe39aafee)]`). Else it calls
`solve(legs, 0, share, address(0), 0)` at `latest` on `rpc_http`:

- `NoProfit`, or a profit under the floor: the cycle is sound and has no profit at this block. It counts as
  no-profit.
- Any other revert (`BadLeg`, an unknown selector) or a failed call: the cycle is broken. It counts as failed.

The builder runs one `bex_simulate` per signer and four per host at a time. It answers a call over that bound with
`-32005` (busy). `simulate` retries after 100 ms, then 200, 400 and 800 ms (5 tries in all), and shows
`[busy retries N]` in the row.

A paced run spans several blocks (688 cycles take about 2.3 minutes at 5 calls per second). So `simulate`
reads the head again every 6 s, and later requests target the new head + 1 with its basefee.

#### Evaluation without a deploy

```sh
bex-backrun simulate --override-code [--repeat-blocks N --every K] [--out rows.csv]
```

`--override-code` runs the cycles on a builder that does not accept `compute.code`. The request has no
`compute.code`. A top-level `stateOverrides` installs `solver_code` at the compute target and, if `executor_code`
is set, the executor's runtime code at `executor`. Then neither contract needs to be deployed.

`--repeat-blocks N --every K` runs the whole set N times: on the first head, then on every K-th new head. `--out`
appends every row to a CSV (the header is written once, to a new file). The columns are `head, target_block,
snapshot_block, cycle, status, amount_in, amount_out, profit, floor_wei, compute_gas, execute_gas,
coinbase_profit_wei, busy_retries, revert_data, issues`. `snapshot_block` is
the block the builder simulated on, and `floor_wei` is the plan's `minProfit`, the floor the solver applied (empty when there is no plan). Use
`snapshot_block` to date a row.

### `run`

```sh
bex-backrun run
```

It sends one `bex_sendBundle` per group, per endpoint, for each new block. It writes every send to the SQLite file
at `db_path` and tracks landings. Stop it with ctrl-c: it takes no more heads, lets the sends in
flight finish and record, and exits.

What it sends:

- **Groups** (`group_size`, 1 to 8, default 1). At startup the bot groups the cycle list in file order: the first
  ungrouped cycle starts a group and takes each later ungrouped cycle that shares a pool with it (same version,
  same token pair, same fee, same tick spacing), up to `group_size`. A group of N > 1 is one request named
  `<first cycle>+<N>`, whose compute is `solveMany` with one floor per cycle. The solver returns the plan with the
  largest profit over its own floor. A group of one keeps the cycle's name and sends `solve`. The name keys the
  `replacementUuid`, the code-mode compute target and the `sent.cycle` column. Because the name holds N, an edit of
  `cycles.toml` can rename a group, which replaces its live request.
- **Copies** (`request_copies`, 1 to 4, default 1). Copy k >= 1 of a group is named `<group name>#k`. After one
  copy's execute commits, the builder can evaluate the next copy on the new state and execute the next-best plan.
  More than 1 needs code mode: the builder's bundle hash does not include the uuid, so copies with one deployed
  solver would be one request.
- **The budget** (`pending_cap`, default 8). Set it equal to your signer's pending limit on the builder. The
  builder accepts requests above that limit and drops them. The bot sends at most `pending_cap / request_copies`
  groups (half of that with `uuid_mode = "parity"`). `select = "top"` (default) sends the first groups in file
  order and logs `sending K groups x C copies (M cycles) of N cycles`. `select = "all"` refuses to start when there
  are more groups. The set is fixed at startup and logged as `cycle set`.
- **The floor**: the bot sends `weiPerGas = ceil(next_base_fee * gas_margin * 10000 / builder_share_bps)` and
  `minProfitWei = min_profit_wei` per cycle. The solver prices the gas of the plan it builds, including the
  builder's 21,000-gas refill of its operator key, and floors the profit at
  `max(minProfitWei, weiPerGas * gas(plan), 1)`. Below the floor, `solve` reverts `NoProfit` in the builder, so
  nothing is placed. `gas_margin` (1.0 or more, default 1.0) raises it.
- **`builder_share_bps`** (1 to 10000, default 5000: half): the share of the profit for `block.coinbase`. The rest
  goes to `payout_address`. A plan is placed only when the coinbase share pays its gas, so a lower share places
  fewer plans.
- **`payout_address`** (default: the signer address): `Plan.recipient`, who gets the profit after the builder's
  share. In BEX the caller of `execute` is the builder's operator key, so without a recipient the rest would go
  to that key. An address that cannot take ETH (a contract without `receive`) makes every `execute` revert.
- **`uuid_mode`**. `cycle` (default): `uuid5(signer, name)`, and each block's request replaces the one before. The
  bot sends for N+1 only after it sees head N, so the replaced request could not have won. `parity`:
  `uuid5(signer, name, target block mod 2)`, so the request for N+1 does not replace the one for N. It helps only
  with a builder whose head lags yours. Two targets are then live at once, so it halves the budget.

When it sends:

- **Heads.** From `rpc_ws` (`newHeads`) if set, else by polling `rpc_http` every 500 ms. Set `rpc_ws` on
  mainnet. While the WS connects, and until its first head, the bot also polls `rpc_http`. If the WS cannot
  connect within 5 s, drops, or sends no head for 25 s, the bot polls for 30 s and then tries the WS again. A head
  seen on both sources is used once. With no head for 36 s, or a head older than 24 s, the bot logs a warning.
- **Delay.** `send_delay_ms` (default 200) after a new head. Keep it short: the builder stops admitting requests
  for a block about 3 s before its slot, and its queue wait is about 1.6 s (p50).
- **In flight.** At most 16 requests to one endpoint at a time. A new head stops the sends of older batches that
  did not start yet (`superseded` in the `sent` table).
- **Retry.** A send that times out (`send_timeout_ms`, default 3000) or hits a transport error is sent again once,
  200 ms later, with the same bytes. A builder that already has the request drops the copy as a duplicate. There
  is no retry after a newer head, and no retry of a JSON-RPC error. The `retries` column counts retries sent.
- **Admission.** If the builder refuses the signer (`-32001 ... access rejected`), `run` stops at the first such
  answer. See [Signer admission](#signer-admission).
- **Logs.** One line per endpoint per block when sends fail, with the count and the first error.

### `status`

```sh
bex-backrun status [--since 1d] [--probe]
```

It prints one row per cycle, then one per group name sent: `sent`, `landed_final` and `landed_provisional`.
`--since` is a block count (`600`) or a time (`30m`, `2h`, `1d`). `run` makes the database. With no database
yet, `status --probe` prints the probe only, and `status` without `--probe` stops.

- `sent` counts the bundle hashes the builder accepted.
- `landed_final` counts `CycleExecuted` logs from the executor with your tag whose block hash was still canonical
  2 blocks later and again 12 blocks later. `landed_provisional` counts those that passed the first check only. A
  landing that fails a check is not counted, and the bot reads the logs again from that block. A group's landings
  count on the row of the cycle that executed.
- `--probe` also calls `solve` at `latest` for each cycle and prints the profit in wei or the revert name
  (`NoProfit`, `BadLeg`). Use it to see if a cycle is profitable now, with no builder involved.

The bot reads landings with `eth_getLogs` from the last scanned block up to the head, so a missed head is scanned
later.

## Shared executor

One executor serves everyone. It has no owner and keeps nothing between transactions. Set `executor` in
`bot.toml` to `0x12EAe402fA25B6B656c65fdff06990f29298449B`. Its address is pinned by its init code. It
is deployed on mainnet: see the deploy record in `contracts/README.md`.

The bot finds its landings by a tag. Each `solve` call carries `tag = bytes32(uint256(uint160(signer)))`. The solver
copies it into the plan, and `execute` emits it as topic 2 of `CycleExecuted`. The landing scan asks
`eth_getLogs` for `[CycleExecuted, any cycleId, tag]` from `executor`. The tag is self-declared: anyone can send
your tag, and those landings count as yours. Use it for stats only. It never moves funds.

## Code mode

A builder that accepts `compute.code` runs the solver from the request. The bot sends the solver's runtime code as
`bex.compute.code`, and no solver is deployed. The executor must still be a deployed contract, because pools call
back into it. Use code mode to change the solver without a deploy.

1. Export the runtime code: `forge script script/RuntimeCode.s.sol` in `contracts/` writes
   `out-runtime/solver.hex`. It must come from a constructed solver, so the venue immutables are filled in. forge's
   `deployedBytecode` has zeros there and reads no pools.
2. In `bot.toml`, set `solver_code` to that file and leave `solver` out. Setting both is an error, and setting
   neither is an error. The code must be 1 to 24,576 bytes.

The builder drops a code request whose compute target is not empty (code, a nonce or a balance:
`ComputeTargetExists`). Anyone can send 1 wei to a fixed address, so each request has a fresh target:
`address(keccak256(abi.encode("bex-backrun", signer, name, target_block)))`. Anyone who knows the signer and the
names can predict the targets, but to block the bot they must fund each target for each block. The `venues()`
check and the `solve` probes run the code through an `eth_call` state override, so `rpc_http` must accept the
third `eth_call` parameter (reth and geth do).

## Signer admission

The builder takes `bex_sendBundle`, `bex_cancelBundle` and `bex_simulate` only from signers it admits, each with a
pending limit. Any other signer gets `-32001 ... access rejected`, and `run` and `simulate` stop with
`signer 0x… is not admitted for BEX on <host>`, followed by the builder's own message. To get a signer admitted,
ask in the builder's Telegram group, [t.me/EurekaBuilder](https://t.me/EurekaBuilder): post the signer address
and ask for its pending limit. The signer only signs requests and needs no ETH; an existing address or a new
one both work. The root README's quickstart has the whole path.

## Log levels and keyed URLs

The bot removes endpoint and RPC URLs from its own log lines and from its database. At `RUST_LOG=debug` or
`trace`, the alloy library can log full URLs in its own spans. If a URL holds a key, run at `info` (the default) or
`warn`.

## Devnet smoke test

`scripts/devnet-smoke.sh <bot.toml> <cycles.toml> [slots]` runs `simulate`, then `run` for `slots` slots (20 by
default), then `status`. It fails if the bot has no canonical landing. It needs a running devnet with a BEX builder,
`BEX_SIGNER_KEY`, and a release build.

## Limits

- **Latency.** The builder admits requests for a block until about 3 s before its slot. The bot sends
  `send_delay_ms` (200 ms) after it sees a head. Use `rpc_ws` and a node close to you.
- **One builder.** A plan lands only in a block this builder builds and the proposer takes.
- **No per-request feedback.** The builder does not say why a request did not land. `status` shows sends and
  landings; `simulate` shows what a cycle does before a send.
- The bot has no price feed and no inventory. It sends the same set of cycles each block and lets the solver decide.
- Cycles are not discovered at run time. You write them in `cycles.toml` (or build them with `cycles/build.py`).
- A run needs a signer the builder admits.
- The solve has no gas cap of its own. One `solve` walks at most 32 tick regions inside the crossing budget. The
  tests hold each solve under 6M gas (`MAX_COMPUTE_GAS`): the worst case built to walk to the budget costs about
  5.8M, and the costliest mined cycle in a quiet market costs 1,324,727. A `solveMany` group costs up to the sum of
  its cycles' solves (at most 8 cycles). That is under the builder's 500M compute cap. But the builder budgets BEX
  by wall-clock time (about 5 ms per pass, 25 ms per candidate block), so measure new cycles with `simulate` before
  you add many.

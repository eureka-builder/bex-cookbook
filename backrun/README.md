# backrun

**Backrun every block with no capital, no gas and no mempool race.**

An open-source searcher for BEX on the Eureka builder. It sends 688 arbitrage cycles over Uniswap V2, V3 and V4,
and its solver sizes each trade to the exact optimum, inside the block, right after the swap that opened the gap.

Clone it, build it and simulate every cycle on the builder in minutes.

> **Unaudited, experimental demo. Use at your own risk. Not financial advice, and no profit is guaranteed. You are responsible for following the laws that apply to you.**

## BEX in one minute

BEX, Builder Execution Extensions, lets you run your own logic inside the Eureka builder while it builds the
block. Each request targets one cycle or a group of cycles, and has two parts:

- **Compute.** Your code runs in place, off-chain, in the builder's EVM, on the live state of the block being
  built. It runs again after each bundle the builder places. It never goes on chain, so it costs no gas and is
  not bound by the block gas limit: up to 500M gas per call.
- **Execute.** A small, cheap on-chain transaction that runs the plan the compute returned. The builder signs it
  and places it only when the plan pays more than its gas.

You hold no capital, send no transaction and pay no gas. The profit is paid in the same transaction: your chosen
share to the builder, the rest to you.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/bex-dark.svg">
  <img alt="A searcher sends the builder requests each block, one per cycle or group of cycles, for example ETH to USDC to USDT and back to ETH. Each request carries a compute (the solver code for its cycles) and an execute (a transaction template). Inside the builder, the block under assembly is on-chain and the compute lane beside it is off-chain: the program runs on the state so far after every bundle placed. When a swap moves a price and the program returns a plan, the builder signs execute(plan) and places it right after the swap. The sealed block holds the swap and the execute; the compute left no trace. The profit is paid in the same transaction: the builder's share to the coinbase and the rest to the searcher's address." src="docs/bex.svg" width="960">
</picture>

Backrunning is one application of BEX. A swap moves a pool's price, and the next trade can take the gap against
another pool. With BEX, the search for that trade runs on the only state that matters: the builder's.

## What this bot does

- Each block, it sends one request per group of cycles. A cycle is a closed path of swaps from ETH back to ETH,
  of any length from 2 legs up to what the execute gas budget allows.
- The compute is the solver. It finds the input with the most profit and returns the trade, or reverts.
- The trade needs no funds: it borrows from the first pool and repays it from the last.

It is a worked example, not an optimal strategy. A searcher's own know-how, in which cycles to send, how to order
them and how to solve them, can turn the same building blocks into a smarter implementation with an edge.

## Quickstart

Every BEX searcher goes through the same four steps. The picture shows them with this bot's commands.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/quickstart-dark.svg">
  <img alt="Four steps of any BEX searcher, with this bot's commands. 1 Get admitted, once, in Telegram: ask for access at t.me/EurekaBuilder with your signer address. 2 Build and simulate, once: dry-run your requests with bex_simulate; this bot: cargo build, the forge script, ops/run.sh simulate. 3 Run, every block: one bex_sendBundle per request, and the builder places what pays; this bot: ops/run.sh run. 4 Watch it land, any time: your executions on chain, found by your tag; this bot: bex-backrun status. Without a signer, ops/run.sh probe runs the solver on your own node." src="docs/quickstart.svg" width="960">
</picture>

### 1. Get admitted

The builder takes requests only from signers it knows. A signer is any Ethereum address, existing or
[new](ops/README.md#make-a-signer). It signs your requests and never needs ETH.
Use a key that holds nothing else.

Post in the builder's Telegram group, [t.me/EurekaBuilder](https://t.me/EurekaBuilder), that you want BEX
access, and have these ready:

- your name (a real name is preferred)
- your signer address
- one line on what you will use BEX for

### 2. Build and simulate

You need Rust 1.91 or later, Foundry, Python 3.11 or later, `jq` and a mainnet JSON-RPC URL. On macOS,
`brew install coreutils` gives `ops/run.sh run SECONDS` its `timeout`. The builder's endpoint
speaks BEX only, so the bot reads heads, the basefee and its landings from your node.

```sh
git clone --recursive https://github.com/eureka-builder/bex-cookbook
cd bex-cookbook/backrun
cargo build -p bex-backrun --release
(cd contracts && forge script script/RuntimeCode.s.sol)   # writes contracts/out-runtime/solver.hex

export BEX_RPC_HTTP=<mainnet JSON-RPC URL>
export BEX_SIGNER_FILE=ops/work/signer.json   # see ops/README.md#make-a-signer; ops/work/ is ignored by git
export BEX_PAYOUT_ADDRESS=<an address you control that is not the signer>
export BEX_PENDING_CAP=<the pending limit the builder gives you>
ops/run.sh simulate
```

Set `BEX_PAYOUT_ADDRESS`, or the profits collect on the signer, whose key sits in a plain file.

It prints one row per cycle and a summary. `no-profit` is the normal row: the cycle is sound and has no gap at
this block. Fix every `failed` row before you send.

### 3. Run

```sh
ops/run.sh run 3600        # one hour; without the number, until ctrl-c
```

### 4. Watch it land

```sh
target/release/bex-backrun status --config ops/work/bot.toml --cycles cycles/cycles.toml --since 1h
```

`sent` counts the requests the builder took, and `landed_final` counts your executions in canonical blocks.

No signer yet? `ops/run.sh probe` runs the solver on your own node and prints each cycle's profit or revert.

> The shared executor is live on mainnet at `0x12EAe402fA25B6B656c65fdff06990f29298449B` (block 26319273).
> [Deploy details](contracts/README.md#mainnet-executor-through-the-canonical-create2-deployer).

## Learn more

| Topic | In short |
|---|---|
| [Code tour](docs/tour.md) | Every file as a station on a transit map, and one block's ride through them. |
| [The request](bot/README.md#the-request) | One `bex_sendBundle`: the solver code as compute, `execute(plan)` as execute. |
| [Settings and commands](bot/README.md#commands) | `simulate`, `run`, `status`, `weiPerGas` (the profit a plan needs, in wei per gas), groups and the payout split. |
| [Endpoint limits](bot/README.md#endpoint-limits) | `bex_capabilities` needs no signature. |
| [How the solver finds the optimum](contracts/README.md#how-cyclesolver-works) | A rate check, a closed form, then exact swap steps. |
| [Safety model](contracts/README.md#safety-model) | No owner, no funds at rest, no approvals, a profit floor. |
| [Cycles](bot/README.md#cycles) | The file format and how to add a cycle. |
| [The cycle set](cycles/README.md) | How the 688 cycles are mined and ordered. |
| [Running and checking a landing](ops/README.md) | `run.sh` and its env vars, `verify_landing.py`. |
| [Known limits](bot/README.md#limits) | Latency, the pending limit, solver gas, one builder. |

## License

BSD-3-Clause-Clear, see [`LICENSE`](../LICENSE). It grants no patent rights. The files compiled into the deployed executor (`contracts/src/CycleExecutor.sol` and the files it imports) stay MIT, as their SPDX headers say, so they match the verified contract on mainnet.

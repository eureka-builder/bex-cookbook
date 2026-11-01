# ops

Two scripts for running the bot and checking what it landed.

| File | What it does |
|---|---|
| `run.sh` | Writes a `bot.toml` from env vars, then runs `probe`, `simulate` or `run`. |
| `verify_landing.py` | Checks one landed `execute` transaction on chain. Python 3 stdlib only. |

## run.sh

Build the bot and export the solver code first:

```sh
cargo build -p bex-backrun --release
(cd contracts && forge script script/RuntimeCode.s.sol)   # writes contracts/out-runtime/solver.hex
```

Then:

```sh
export BEX_RPC_HTTP=<mainnet JSON-RPC URL>
export BEX_SIGNER_FILE=ops/work/signer.json   # a JSON file with {"private_key": "0x..."}
export BEX_PAYOUT_ADDRESS=<an address you control that is not the signer>
export BEX_PENDING_CAP=<the pending limit the builder admitted your signer with>
ops/run.sh probe           # solve every cycle at latest on your node: no builder, no signer, no pending limit
ops/run.sh simulate        # one bex_simulate per cycle, then a summary
ops/run.sh run 3600        # send for one hour; without SECONDS it runs until ctrl-c
```

The script writes a new `ops/work/bot.toml` on each start (mode 600, because it can hold RPC URLs with keys) and appends one line per start to
`ops/work/runs.log`: the time, the mode and the SHA-256 prefixes of the binary, the cycles file and the solver code.
The SQLite database is `ops/work/bex-backrun.sqlite`. `ops/work/` is ignored by git.

The signer key: Python reads `private_key` from `BEX_SIGNER_FILE` and starts the bot with the key in
`BEX_SIGNER_KEY`. The key does not go through a shell variable, a command argument or the terminal. If
`BEX_SIGNER_FILE` is not set, the bot reads `BEX_SIGNER_KEY` from the environment itself. The script warns if
the file is open to group or others.

Set `BEX_PAYOUT_ADDRESS` to a separate address you control. Without it the profits collect on the signer, whose
key sits in a plain file.

| Env | Default | Meaning |
|---|---|---|
| `BEX_RPC_HTTP` | required | Mainnet JSON-RPC: heads, `eth_call` checks, landing logs |
| `BEX_SIGNER_FILE` | none | JSON file with the signer key in `private_key` |
| `BEX_RPC_WS` | none | WS URL for `newHeads`. Without it the bot polls `BEX_RPC_HTTP` every 500 ms |
| `BEX_ENDPOINT` | `https://rpc.eurekabuilder.xyz` | The builder's BEX endpoint |
| `BEX_BIN` | `target/release/bex-backrun` | The bot binary |
| `BEX_CYCLES` | `cycles/cycles.toml` | The cycles file |
| `BEX_SOLVER_CODE` | `contracts/out-runtime/solver.hex` | The solver runtime code (code mode) |
| `BEX_EXECUTOR` | `0x12EAe402fA25B6B656c65fdff06990f29298449B` | The shared executor |
| `BEX_PAYOUT_ADDRESS` | none (the signer address) | `payout_address`: who gets the profit after the builder's share |
| `BEX_BUILDER_SHARE_BPS` | `5000` | `builder_share_bps`: the share of the profit that goes to `block.coinbase`, in bps. The rest goes to `payout_address` |
| `BEX_PENDING_CAP` | required for `simulate` and `run` | The pending limit the builder admitted your signer with. There is no default: the builder accepts requests above the limit and drops them without an error. |
| `BEX_GROUP_SIZE` | `4` | Cycles per request |
| `BEX_REQUEST_COPIES` | `1` | Requests per group per block |
| `BEX_MIN_PROFIT_WEI` | `0` | Lower bound of the profit floor |
| `BEX_WORKDIR` | `ops/work` | Where `bot.toml`, `runs.log` and the database go |

The script fixes the other settings: `gas_margin = 1.0`, `select = "top"`, `send_delay_ms = 200`. See `bot/README.md` for each setting.
It stops if a value holds `"`, `\` or a newline, or if a number is not decimal digits.

### Make a signer

Any Ethereum address works as a signer. To make a new one in the file format `BEX_SIGNER_FILE` expects, from
`backrun/` (it needs `jq`):

```sh
umask 077
mkdir -p ops/work                                                 # ignored by git
cast wallet new --json > ops/work/new.json
jq -r '.[0].address' ops/work/new.json                            # your signer address
jq '{private_key: .[0].private_key}' ops/work/new.json > ops/work/signer.json && rm ops/work/new.json
```

## verify_landing.py

```sh
export BEX_RPC_HTTP=<JSON-RPC URL with debug_traceTransaction>
ops/verify_landing.py <tx hash> [--executor 0x...] [--operator 0x...]
```

The RPC must answer `debug_traceTransaction` with the `callTracer`, and `eth_call` at the landing block (an archive
node for old blocks). Most public RPCs do not have the debug methods.

`--executor` (or `BEX_EXECUTOR`) defaults to the shared mainnet executor. `--operator` (or `BEX_OPERATOR`) is the
builder key that signed the `execute`. Without it, the script does not check the sender, and it uses the sender
as the operator for the other checks. `--self-test` checks the payout logic with no RPC.

It prints one `OK` or `FAIL` line per check, and exits 1 if a check fails:

1. The receipt has status 1. The transaction goes to the executor, and from the operator if `--operator` is given.
2. The receipt has one `CycleExecuted` log from the executor. The transaction calls `execute(Plan)`.
3. `block.coinbase` receives exactly `paidToCoinbase`, and `paidToCoinbase = profit * builderShareBps / 10000`. The
   plan's recipient (the operator, the caller, when the recipient is `address(0)`) receives exactly
   `profit - paidToCoinbase`. At share 10000 that is 0, at share 0 the coinbase receives nothing.
4. `profit` is at least the plan's `minProfit`, and `amountIn` is the plan's.
5. No internal call has an error.
6. ETH value goes only to the coinbase, the recipient (or the operator), the executor, the V4 PoolManager, a pool
   the transaction swaps on, or WETH `deposit()`.
7. There is no `approve` call and no `Approval` log.
8. The next transaction in the block refills the operator: coinbase to operator, value = `gasUsed * basefee` of
   the execute.
9. The executor holds 0 of every token the transaction touched, and 0 ETH, after the block.

Checks 1 and 8 apply where the builder signs the execute with an operator key and refills that key from the
coinbase. That is how BEX runs an `execute`.

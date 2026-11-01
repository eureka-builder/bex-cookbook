# Notes for coding agents

Read `README.md` first, then the README of the directory you change. This file lists what the recipe enforces.
Run every command below from `backrun/`.

## Build and test

Rust 1.91 or later (`rust-version` in `Cargo.toml`, alloy 1.8 needs it), Foundry and Python 3.11 or later.
Clone with `--recursive`, or run `git submodule update --init` (the contracts depend on two submodules).
CI (`../.github/workflows/ci.yml`) runs these on every PR, except the release build and the fork suites. Run them
before you open a PR, and put the results in the PR body:

```sh
cargo build -p bex-backrun --release
cargo test --workspace
cargo clippy --all-targets -- -D warnings
cargo fmt --check
python3 -m unittest cycles/test_build.py
cd contracts && forge fmt --check && forge test   # the 10 fork suites skip without ETH_RPC_URL
ETH_RPC_URL=<archive RPC> forge test              # fork suites, pinned to FORK_BLOCK in test/ForkBlock.sol
```

Tests live in `bot/tests/` (request bodies, signatures and uuids are pinned in `tests/request.rs`), in
`contracts/test/` (`*.t.sol`, fork suites extend `ForkTest`) and in `cycles/test_build.py`.
`python3 cycles/build.py` must rebuild `cycles/cycles.toml` with no diff. `ops/run.sh` and the bot's code mode
need `contracts/out-runtime/solver.hex`, written by `forge script script/RuntimeCode.s.sol` in `contracts/`.

## The executor is pinned

`CycleExecutor.sol`, `Types.sol`, `lib/Pools.sol`, `lib/V2Reader.sol`, `interfaces/`, `foundry.toml` and the
library commits build the executor, `0x12EAe402fA25B6B656c65fdff06990f29298449B`. Its CREATE2 salt, init code
hash and address are pinned in `contracts/test/Create2Deploy.t.sol` and in the table of `contracts/README.md`;
`test_executorInitCode_matchesPinned` fails when the build no longer matches them. Any change to these files, a
comment too, changes the compiler metadata hash, so the init code and the address change.

The executor is deployed on mainnet (block 26319273). Do not edit these files: any change builds a different
address from the deployed one. Document the executor in `contracts/README.md` instead.

To check that the tree builds the deployed code, after the deploy:

```sh
cd contracts && forge script script/RuntimeCode.s.sol        # writes out-runtime/executor.hex
test "$(cast code 0x12EAe402fA25B6B656c65fdff06990f29298449B --rpc-url $ETH_RPC_URL)" = "$(cat out-runtime/executor.hex)" && echo same
```

## The solver can change

The bot sends `CycleSolver` as runtime code in every request (code mode), so solver-only files
(`CycleSolver.sol`, `lib/LegSim.sol`, `ClosedForm.sol`, `RateFilter.sol`, `InRange.sol`, `StepEdge.sol`,
`V3Reader.sol`, `V4Reader.sol`) change freely. After any change there, also a comment:

- Run `forge script script/Create2Deploy.s.sol:Create2DeploySolver`, then update the pinned solver constants in
  `contracts/test/Create2Deploy.t.sol` and the solver table of `contracts/README.md`.
  `test_solverInitCode_matchesPinned` fails until you do. The generated transaction in `contracts/deploy/out/`
  is not committed.
- For a comment-only change, show in the PR that the solver runtime is identical without its trailing CBOR
  metadata (its length is in the last 2 bytes) and that `executor.hex` is identical with metadata.
- Never send forge's `deployedBytecode`: its immutables are zero. Use `script/RuntimeCode.s.sol`.

A behavior change in the bot must keep the request bodies of `bot/tests/request.rs`, or say why they change.

## Prose

READMEs, comments and PR bodies use short plain sentences. No em-dashes. Every number in a doc comes from the
code, a test or committed data. Say what a reader must do, not what the code used to do.

## Nothing internal

The tree holds no internal host, path, config file name, report name or environment. The only external names
are the public BEX endpoint, the Telegram contact and the mainnet addresses. Keep it that way in code,
comments, data files, examples and PR bodies.

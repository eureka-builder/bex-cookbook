# cycles

The mainnet cycle set of the bot. `build.py` writes two files from 30 days of mined arbitrage:

- `cycles.toml`, the bot's `cycles` file: 688 cycles in the live order (see [Live order](#live-order)).
- `contracts/test/fixtures/cycles.json`, the fork fixture. It holds every candidate cycle in rank order, both
  orientations (1010 cycles). Every cycle of `cycles.toml` is in it, so the fork tests check the whole live set.

## Files

| File | What |
|---|---|
| `build.py` | The build. Python 3.11 or later, stdlib only, deterministic. It runs offline from the committed caches. |
| `test_build.py` | Unit tests: `python3 -m unittest cycles/test_build.py`. |
| `mined/eth-anchor-30d.json` | Dune rows: ETH-anchored Uniswap V2/V3/hookless-V4 cycles by ordered pool path over 30 days, with each leg's pool, fee and tick spacing, the arb count, the clean profit (USD), the suspect profit (USD), and the clean arbs' count, median and max. It holds the SQL, the query id and the execution id. |
| `pins/live.txt` | The live order: the names that go first in `cycles.toml` (`--live`). |
| `pins/eth-usd-48.txt` | The names that go first in the rank order (`--pin`). |
| `tokens.json` | A cache of token symbols, used for names only. |

## Rebuild

```sh
python3 cycles/build.py                 # the live set, offline
python3 cycles/build.py --live ''       # cycles.toml = the full ranked set, both orientations
python3 cycles/build.py --min-arbs 20   # a stricter frequency floor (default 10 arbs in 30 days)
python3 cycles/build.py --top 100       # only the 100 best-ranked candidates
python3 cycles/build.py --rank profit   # rank by total profit instead of robust value
python3 cycles/build.py --pin ''        # no rank pins: rank order only
```

A rebuild with no option change writes the same files. `--min-arbs` and `--top` change the fork fixture too.
The build prints a summary (also in the `cycles.toml` header): counts by anchor, legs and versions, the profit
covered, what it dropped and why, and what happened to each cycle of the file it replaces.

To validate a new set, run the fork tests (they need an archive RPC):

```sh
cd contracts
ETH_RPC_URL=<archive rpc> forge test --match-test 'test_quietMarket_everyMinedCycle_eitherNoProfitOrExecutable|test_mainnetCycles_noTransferTax' -vv
```

- `test_mainnetCycles_noTransferTax` moves 1% of each token's pool balance: pool to wallet, wallet to wallet and
  wallet to pool (the way the executor pays pools), and requires the full amount to arrive each time. Add a token
  that fails to `EXCLUDED_TOKENS` in `build.py` and rebuild.
- `test_quietMarket_everyMinedCycle_eitherNoProfitOrExecutable` solves every fixture cycle at `FORK_BLOCK` and
  requires each solve to stay under `MAX_COMPUTE_GAS` (6,000,000 gas, `contracts/test/Fork.t.sol`). The solver
  bounds its own cost (see "Solve gas by path" in `contracts/README.md`), so a cycle that fails it is a solver bug:
  fix the solver, do not drop the cycle.

## Live order

A plain `python3 cycles/build.py` writes the live set in three steps:

1. The candidate set: the mined rows after the filters below, in rank order (1010 cycles). This is also the fork
   fixture.
2. The live order: the 166 names of `pins/live.txt` first, in that order, then the rest in rank order.
   The first live order was 32 hand-picked cycles that cleared the profit floor in replays of recent mainnet
   blocks, then rank order. The first 166 places are a hand-tuned order.
3. One orientation per pool set: a cycle whose set of pools is the same as an earlier cycle's is dropped. The
   reverse of a cycle uses the same pools, and the solver tries both orientations of every request
   (`RateFilter.direction`), so the second orientation adds only compute. This drops 322 cycles.

With `group_size = 4` and `pending_cap = 64` (`bot/bot.example.toml`), the bot sends 64 groups that hold 205 of
the 688 cycles (`test_example_config_selects_64_groups_of_205_cycles` in `bot/tests/cycles_export.rs`). The order
decides which ones: the bot sends the first `pending_cap` groups in file order.

## Pin files and your own set

A pin file (`--pin` or `--live`) has one cycle name per line, in order. Blank lines and text after `#` are ignored.
A name that is not in the candidate set is reported in the summary and skipped. Names are the generated ones, as
in `cycles.toml`.

To send your own set:

- `python3 cycles/build.py --live my-order.txt`: your names first, in your order, then the rest in rank order, one
  orientation per pool set. A file with no names gives rank order with one orientation per pool set.
- `python3 cycles/build.py --live ''`: the full ranked set, both orientations.
- Or write `cycles.toml` by hand (see `bot/cycles.example.toml`) and pass it with `--cycles`. The bot checks it at
  startup.

## What `build.py` does

**Pools.** It checks every leg's pool: V2 against the factory's CREATE2 pair, V3 against CREATE2 for (tokens,
fee), V4 against the hookless PoolKey id. A mismatch drops the row.

**ETH.** ETH is `address(0)` on V4 legs and WETH on V2/V3 legs, at the anchor too. A cycle can start at V4 ETH and
end at V2/V3 WETH, or the reverse. The summary calls these `mixed`, and the others `pure-ETH` and `pure-WETH`.
`Pools.validate` and the executor treat ETH and WETH as one anchor. The executor wraps or unwraps at each V2/V3 to
V4 boundary, and pays the profit in ETH. The query merges ETH and WETH between legs too, so the build drops a row
with ETH or WETH at an inner position (none in the current rows).

**Filters.** It keeps at least 2 legs, distinct pools (the same V2 WETH/X pair at both ends is one pool),
`arbs >= --min-arbs` and a clean profit above 0. The query drops V4 pools on the WETH ERC20. The build drops
cycles through `EXCLUDED_TOKENS` (transfer tax, rebasing): their executes revert. It keeps no list of expensive,
empty or unprofitable cycles: the solver bounds the cost of every solve, and a cycle with no profit (an empty
pool too) reverts `NoProfit` cheaply. Each mined direction is its own candidate.

**Rank order.** First the names of the pin file (`--pin`, default `pins/eth-usd-48.txt`), in its order, then the
rest by rank. A pinned name that is not in the set is reported, not added. Ranks: `robust` (default) is the median
clean profit per arb times the clean arbs, capped at the profit, so one large arb does not lift it. `profit` is the
30-day clean profit. `arbs` is the arb count. Ties fall to profit, then arbs. `pins/eth-usd-48.txt` holds every
ETH/USD same-pair 2-leg cycle and ETH/USD/USD triangle of an earlier 429-cycle set (94% of the value a replay of
2,000 mainnet blocks could insert), ordered by that value. 46 of the 48 are in the candidate set, and 26 in `cycles.toml` (one orientation per pool set).

**Gas.** `cycles.toml` carries no gas figure. The bot sends `weiPerGas` and the solver prices the gas of the plan it
builds, so the floor is `max(minProfitWei, weiPerGas x gas(plan), 1)` (see `bot/README.md`). An older `cycles.toml`
with a per-cycle gas key fails to load in the bot.

**Names.** `<token symbols>__<version_fee per leg>`, with a numeric suffix on a collision.

## Re-mine

The query is Dune [9016757](https://dune.com/queries/9016757) (a fixed 30-day window, 2,131 rows with at least
5 arbs).

1. Run the query on Dune. The SQL is the `sql` field of the `mined/*.json` file. It treats ETH (V4 currency `0x0`)
   and WETH as one asset. It takes V4 pool ids from `PoolManager.Swap` and their fee and tick spacing from
   `Initialize` (hookless only), V3 fee and tick spacing from the factory, and each transaction's gross profit at
   the `dex.trades` price. A transaction whose profit is more than 50% of its largest leg's USD value is a pricing
   error: it goes to `suspect_usd`, not `profit_usd`. For a newer window, move all four window timestamps (two in
   `v4s`, two in `t`) and the `block_month >= DATE ...` partition filter in `t` to the month of the window's start.
2. Save the rows in the same shape (`{query_id, execution_id, window, sql, rows}`) under `mined/` and point `MINED`
   in `build.py` at the new file.
3. `ETH_RPC_URL=<rpc> python3 cycles/build.py --refresh` reads new token symbols with `cast call` and adds them to
   `tokens.json`. Commit the cache with the output.
4. Run the fork tests above, and update the pin files: a re-mine changes the candidate set.

## Caps

The bot sends one request per group of cycles per block (up to `group_size` cycles in one request). With
`select = "top"` it sends the first `pending_cap` groups in file order and logs how many it leaves out. Set
`pending_cap` equal to the pending limit the builder gives your signer: the builder accepts requests above that
limit and drops them.

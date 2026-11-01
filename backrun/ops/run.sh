#!/usr/bin/env bash
# Run the bot with a bot.toml written from env vars.
#
# Usage:
#   ops/run.sh probe             # solve every cycle at latest on your node: no builder, no signer
#   ops/run.sh simulate          # dry-run every cycle once with bex_simulate
#   ops/run.sh run [SECONDS]     # send; stop after SECONDS (ctrl-c stops it too)
#
# The script writes $BEX_WORKDIR/bot.toml from the env below, then runs the bot with it.
# Required:
#   BEX_RPC_HTTP        Ethereum mainnet JSON-RPC URL
#   BEX_PENDING_CAP     (simulate, run) the pending limit the builder admitted your signer with. The builder accepts
#                       requests above it and drops them without an error.
#   BEX_SIGNER_FILE     JSON file with the signer key in "private_key" (hex). The key goes only into
#                       the bot's environment. If not set, the bot reads BEX_SIGNER_KEY itself.
# Optional (default):
#   BEX_RPC_WS          WS URL for newHeads (none: poll BEX_RPC_HTTP)
#   BEX_ENDPOINT        builder BEX endpoint (https://rpc.eurekabuilder.xyz)
#   BEX_BIN             bot binary (target/release/bex-backrun)
#   BEX_CYCLES          cycles file (cycles/cycles.toml)
#   BEX_SOLVER_CODE     solver runtime code, code mode (contracts/out-runtime/solver.hex)
#   BEX_EXECUTOR        executor (the shared mainnet executor)
#   BEX_PAYOUT_ADDRESS  who gets the profit after the builder's share (the signer address)
#   BEX_BUILDER_SHARE_BPS  share of the profit that goes to block.coinbase, bps (5000)
#   BEX_GROUP_SIZE      cycles per request (4)
#   BEX_REQUEST_COPIES  requests per group per block (1)
#   BEX_MIN_PROFIT_WEI  lower bound of the profit floor (0)
#   BEX_WORKDIR         bot.toml and the SQLite database (ops/work)
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MODE=${1:-}
DURATION=${2:-}
case $MODE in
  probe | simulate | run) ;;
  *) echo "usage: ops/run.sh probe | ops/run.sh simulate | ops/run.sh run [SECONDS]" >&2; exit 2 ;;
esac
: "${BEX_RPC_HTTP:?set BEX_RPC_HTTP to an Ethereum mainnet JSON-RPC URL}"
# probe sends nothing to the builder, so it needs no pending limit (the bot's default stands in).
[ "$MODE" = probe ] || : "${BEX_PENDING_CAP:?set BEX_PENDING_CAP to your admitted per-signer pending limit}"

# bot.toml resolves relative paths against its own directory: make every path absolute.
abs() { case $1 in /*) echo "$1" ;; *) echo "$PWD/$1" ;; esac; }
BIN=$(abs "${BEX_BIN:-$ROOT/target/release/bex-backrun}")
CYCLES=$(abs "${BEX_CYCLES:-$ROOT/cycles/cycles.toml}")
SOLVER_CODE=$(abs "${BEX_SOLVER_CODE:-$ROOT/contracts/out-runtime/solver.hex}")
WORKDIR=$(abs "${BEX_WORKDIR:-$ROOT/ops/work}")
[ -x "$BIN" ] || { echo "no bot binary at $BIN: run cargo build -p bex-backrun --release" >&2; exit 1; }
[ -f "$SOLVER_CODE" ] || {
  echo "no solver code at $SOLVER_CODE: run forge script script/RuntimeCode.s.sol in contracts/" >&2
  exit 1
}
# The values go into bot.toml as they are: refuse any that would break a TOML string or number.
for v in BEX_ENDPOINT BEX_RPC_HTTP BEX_RPC_WS BEX_EXECUTOR BEX_PAYOUT_ADDRESS SOLVER_CODE WORKDIR; do
  case ${!v:-} in *[\"\\]* | *$'\n'* | *$'\r'*) echo "$v must not hold \", \\ or a line break" >&2; exit 2 ;; esac
done
for v in BEX_BUILDER_SHARE_BPS BEX_PENDING_CAP BEX_GROUP_SIZE BEX_REQUEST_COPIES BEX_MIN_PROFIT_WEI; do
  case ${!v:-0} in *[!0-9]*) echo "$v must be a decimal number" >&2; exit 2 ;; esac
done
case $DURATION in *[!0-9]* | 0*) echo "run SECONDS must be a positive whole number" >&2; exit 2 ;; esac

# bot.toml can hold RPC URLs with keys: only this user can read it.
mkdir -p "$WORKDIR"
umask 077
CONFIG=$WORKDIR/bot.toml
rm -f "$CONFIG" # a file from an older run keeps its old mode: make a new one
cat >"$CONFIG" <<EOF
endpoints = ["${BEX_ENDPOINT:-https://rpc.eurekabuilder.xyz}"]
rpc_http = "$BEX_RPC_HTTP"
${BEX_RPC_WS:+rpc_ws = \"$BEX_RPC_WS\"}
solver_code = "$SOLVER_CODE"
executor = "${BEX_EXECUTOR:-0x12EAe402fA25B6B656c65fdff06990f29298449B}"
weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
signer_key_env = "BEX_SIGNER_KEY"
builder_share_bps = ${BEX_BUILDER_SHARE_BPS:-5000}
${BEX_PAYOUT_ADDRESS:+payout_address = \"$BEX_PAYOUT_ADDRESS\"}
min_profit_wei = "${BEX_MIN_PROFIT_WEI:-0}"
gas_margin = 1.0
${BEX_PENDING_CAP:+pending_cap = $BEX_PENDING_CAP}
select = "top"
send_delay_ms = 200
group_size = ${BEX_GROUP_SIZE:-4}
request_copies = ${BEX_REQUEST_COPIES:-1}
db_path = "$WORKDIR/bex-backrun.sqlite"
EOF

# A record of what ran, without URLs or keys.
command -v sha256sum >/dev/null || sha256sum() { shasum -a 256 "$@"; } # macOS
echo "$(date -u +%FT%TZ) mode $MODE binary $(sha256sum "$BIN" | cut -c1-12)" \
  "cycles $(sha256sum "$CYCLES" | cut -c1-12) solver $(sha256sum "$SOLVER_CODE" | cut -c1-12)" >>"$WORKDIR/runs.log"

CMD=("$BIN" "$MODE" --config "$CONFIG" --cycles "$CYCLES")
if [ "$MODE" = probe ]; then
  exec "$BIN" status --probe --config "$CONFIG" --cycles "$CYCLES"
fi
if [ "$MODE" = run ] && [ -n "$DURATION" ]; then
  CMD=("$(command -v timeout || echo gtimeout)" --preserve-status -s INT "$DURATION" "${CMD[@]}")
fi

if [ -z "${BEX_SIGNER_FILE:-}" ]; then
  exec "${CMD[@]}"
fi
# Python reads the key and starts the bot with it in the environment: the key never passes
# through a shell variable, an argument or the terminal.
exec python3 -I -c '
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2:]
try:
    key = json.load(open(path))["private_key"]
except (OSError, ValueError, KeyError, TypeError):
    sys.exit(f"cannot read a \"private_key\" field from BEX_SIGNER_FILE {path}")
if os.stat(path).st_mode & 0o077:
    print(f"warning: BEX_SIGNER_FILE {path} is open to group or others: chmod 600 it", file=sys.stderr)
os.environ["BEX_SIGNER_KEY"] = key
os.execvp(cmd[0], cmd)
' "$BEX_SIGNER_FILE" "${CMD[@]}"

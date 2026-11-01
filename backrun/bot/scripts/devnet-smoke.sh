#!/usr/bin/env bash
# Smoke test against a local devnet with a BEX builder: simulate, run for N slots, status;
# fail without a landing.
# Usage: devnet-smoke.sh <config.toml> <cycles.toml> [slots=20]
# Needs BEX_SIGNER_KEY in the env.
# It needs a local devnet with a BEX builder, which is not part of this repo.
# It deletes the db file named by db_path in the config before it starts.
# Set BIN to the binary (default: target/release/bex-backrun of this workspace).
set -euo pipefail
CONFIG=${1:?config.toml}
CYCLES=${2:?cycles.toml}
SLOTS=${3:-20}
BIN=${BIN:-$(dirname "$0")/../../target/release/bex-backrun}
: "${BEX_SIGNER_KEY:?set BEX_SIGNER_KEY}"

# db_path is relative to the config file's directory
DB=$(awk -F'"' '/^db_path/ {print $2}' "$CONFIG")
DB=${DB:-bex-backrun.sqlite}
case $DB in /*) ;; *) DB="$(dirname "$CONFIG")/$DB" ;; esac
rm -f "$DB"
"$BIN" simulate --config "$CONFIG" --cycles "$CYCLES"

# `run` has no slot limit: 12 s per slot, plus 20 s for the last landings to be tracked.
timeout --preserve-status -s INT $((SLOTS * 12 + 20)) \
  "$BIN" run --config "$CONFIG" --cycles "$CYCLES" || [ $? -eq 130 ]

out=$("$BIN" status --config "$CONFIG" --cycles "$CYCLES" --since $((SLOTS + 10)))
echo "$out"
echo "--- probe"
"$BIN" status --config "$CONFIG" --cycles "$CYCLES" --since 1 --probe | tail -n +"$(( $(wc -l <<<"$out") + 1 ))"
# landed_final + landed_provisional are the last two columns; the header row is skipped
landed=$(awk 'NR > 1 { n += $(NF-1) + $NF } END { print n + 0 }' <<<"$out")
echo "canonical landings: $landed"
[ "$landed" -ge 1 ] || { echo "no canonical landing" >&2; exit 1; }

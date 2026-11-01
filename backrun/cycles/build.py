#!/usr/bin/env python3
"""Build cycles/cycles.toml and contracts/test/fixtures/cycles.json from the mined Dune rows.

Stdlib only and deterministic. The mined rows carry every leg's pool, fee and tickSpacing; the build
checks each pool against its factory CREATE2 address (V2/V3) or PoolKey id (V4). Token symbols (names
only) come from the committed cache cycles/tokens.json; `--refresh` fills missing entries with
`cast call` against $ETH_RPC_URL. See cycles/README.md.
"""
import argparse
import collections
import hashlib
import json
import os
import re
import subprocess
import tomllib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
MINED = HERE / "mined/eth-anchor-30d.json"
TOKENS = HERE / "tokens.json"
PINS = HERE / "pins/eth-usd-48.txt"
LIVE = HERE / "pins/live.txt"
TOML_OUT = HERE / "cycles.toml"
FIXTURE_OUT = ROOT / "contracts/test/fixtures/cycles.json"

ZERO = "0x" + "0" * 40
WETH = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
V2_FACTORY, V2_INIT = "0x5c69bee701ef814a2b6a3edd4b1652cb9cc5aa6f", "96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
V3_FACTORY, V3_INIT = "0x1f98431c8ad98523631ae4a59f267346ea31f984", "e34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54"

# Tokens whose transfers do not deliver the sent amount; a cycle through them reverts on execute.
# Found by EndToEnd.t.sol `test_mainnetCycles_noTransferTax` on the fork (rebasing: known).
EXCLUDED_TOKENS = {
    "0x05a0d55bbb2c047a3624af4db6d3a3ce2ea7da09": "Penguin: 1% transfer tax",
    "0xa0df17b5ac76ababa36e1450e2cbcd18a620c845": "FWA: wallet-to-wallet transfer delivers 0",
    "0xd46ba6d942050d489dbd938a2c909a5d5039a161": "AMPL: rebasing",
    "0x89d584a1edb3a70b3b07963f9a3ea5399e38b136": "AIT: 4% tax on transfers into its V2 pair",
    "0x0b61c4f33bcdef83359ab97673cb5961c6435f4e": "EARN: transfer out of its pool reverts",
    "0x44319df45d41ebbf50342357b6581630f7812390": "ACEofANAL: transfer out of its pool reverts",
    "0xa7d12701385abb9814f220d2df705b9fe75bfdfa": "SCADA: transfer out of its pool reverts",
    # Auto-sells into its WETH pair on transfer; the solver's orientation flip would execute it (UniswapV2: K).
    "0x8dce83eca4af45dbe618da1779f9aaca43201084": "AIKEK: auto-sells into its WETH pair on transfer",
}

# ---- keccak256 (the original Keccak padding, not NIST SHA3), for CREATE2 and EIP-55 ----
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _rc():
    r, out = 1, []
    for _ in range(24):
        rc = 0
        for j in range(7):
            r = ((r << 1) ^ ((r >> 7) * 0x71)) % 256
            if r & 2:
                rc ^= 1 << ((1 << j) - 1)
        out.append(rc)
    return out


_RC = _rc()


def _rol(x, n):
    return ((x << n) | (x >> (64 - n))) & _M if n else x


def _f(a):
    for rc in _RC:
        c = [a[x] ^ a[x + 5] ^ a[x + 10] ^ a[x + 15] ^ a[x + 20] for x in range(5)]
        a = [a[i] ^ c[(i - 1) % 5] ^ _rol(c[(i + 1) % 5], 1) for i in range(25)]
        b = [0] * 25
        for x in range(5):
            for y in range(5):
                b[y + 5 * ((2 * x + 3 * y) % 5)] = _rol(a[x + 5 * y], _ROT[x][y])
        a = [b[i] ^ (~b[(i + 1) % 5 + 5 * (i // 5)] & b[(i + 2) % 5 + 5 * (i // 5)]) for i in range(25)]
        a[0] ^= rc
    return a


def keccak(data: bytes) -> bytes:
    rate = 136
    data = bytearray(data) + b"\x01" + b"\x00" * ((-len(data) - 1) % rate)
    data[-1] |= 0x80
    a = [0] * 25
    for off in range(0, len(data), rate):
        for i in range(rate // 8):
            a[i] ^= int.from_bytes(data[off + 8 * i: off + 8 * i + 8], "little")
        a = _f(a)
    return b"".join(x.to_bytes(8, "little") for x in a[:4])


try:  # OpenSSL 3.2+ has Keccak-256: about 50x faster than the code above, same bytes
    hashlib.new("keccak-256")
    keccak = lambda data: hashlib.new("keccak-256", data).digest()  # noqa: E731
except ValueError:
    pass

assert keccak(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"


def checksum(addr: str) -> str:
    h = addr[2:].lower()
    k = keccak(h.encode()).hex()
    return "0x" + "".join(ch.upper() if int(k[i], 16) >= 8 else ch for i, ch in enumerate(h))


def create2(factory: str, salt: bytes, init_hash: str) -> str:
    return "0x" + keccak(b"\xff" + bytes.fromhex(factory[2:]) + salt + bytes.fromhex(init_hash))[12:].hex()


def v2_pair(a, b):
    t0, t1 = sorted((a, b))
    return create2(V2_FACTORY, keccak(bytes.fromhex(t0[2:] + t1[2:])), V2_INIT)


def v4_id(c0, c1, fee, ts):
    """PoolId of a hookless V4 pool: keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks = 0))."""
    words = [c0[2:].rjust(64, "0"), c1[2:].rjust(64, "0"), f"{fee:064x}", f"{ts:064x}", "0" * 64]
    return "0x" + keccak(bytes.fromhex("".join(words))).hex()


def v3_pool(a, b, fee):
    t0, t1 = sorted((a, b))
    return create2(V3_FACTORY, keccak(bytes.fromhex(t0[2:].rjust(64, "0") + t1[2:].rjust(64, "0") + f"{fee:064x}")), V3_INIT)


assert checksum(WETH) == "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
assert v3_pool(WETH, "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", 500) == "0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640"
ETH_USDC_V4_100 = "0x00b9edc1583bf6ef09ff3a09f6c23ecb57fd7d0bb75625717ec81eed181e22d7"
assert v4_id(ZERO, "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", 100, 1) == ETH_USDC_V4_100

# ---- chain caches ----


def cast(*args):
    r = subprocess.run(["cast", "call", *args], capture_output=True, text=True, timeout=60)
    if r.returncode:
        raise RuntimeError(r.stderr.strip()[:200])
    return r.stdout.strip().splitlines()[-1].split(" ")[0].strip('"')  # last line: shims may print banners


def fetch_symbol(t):
    try:
        return cast(t, "symbol()(string)")
    except Exception:
        try:  # bytes32 symbols (MKR-style)
            return bytes.fromhex(cast(t, "symbol()(bytes32)")[2:]).rstrip(b"\0").decode(errors="ignore")
        except Exception:
            return ""


def refresh(path, keys, fn):
    cache = json.loads(path.read_text()) if path.exists() else {}
    todo = sorted(k for k in keys if k not in cache)
    if todo:
        if "ETH_RPC_URL" not in os.environ:
            raise SystemExit("--refresh needs ETH_RPC_URL")
        with ThreadPoolExecutor(16) as ex:
            cache.update(zip(todo, ex.map(fn, todo)))
        path.write_text(json.dumps(dict(sorted(cache.items())), indent=1) + "\n")
    return cache


# ---- build ----


def sym(t, syms):
    if t in (ZERO, WETH):
        return "eth"
    return re.sub(r"[^a-z0-9]", "", syms.get(t, "").lower())[:12] or t[2:8]


def cycle_name(legs, syms):
    """The generated cycle name (before any _2 collision suffix); syms is tokens.json (address -> symbol)."""
    return "_".join(sym(l[1], syms) for l in legs) + "__" + "_".join(f"v{l[0]}" if l[0] == 2 else f"v{l[0]}_{l[3]}" for l in legs)


def pool_id(leg):
    v, a, b, fee, ts = leg
    if v == 2:
        return ("v2", v2_pair(a, b))
    if v == 3:
        return ("v3", v3_pool(a, b, fee))
    return ("v4", *sorted((a, b)), fee, ts)


def legs_of(row):
    """A mined row's legs as (version, token_in, token_out, fee, tickSpacing), or (None, why).

    The row names ETH as WETH on every leg. ETH is address(0) on V4 legs and WETH on V2/V3 legs, so a
    cycle can start at V4 native ETH and end at V2/V3 WETH (or the reverse): the executor and
    Pools.validate treat both as the anchor, and the executor wraps or unwraps between legs.
    """
    toks, vers, pls = row["tokens"].split(","), row["versions"].split(","), row["pools"].split(",")
    fees, tss = (list(map(int, row[k].split(","))) for k in ("fees", "spacings"))
    n = len(toks)
    if n < 2:
        return None, "leg count"
    if WETH in toks[1:]:  # the query merges ETH and WETH between legs too; only the anchor may be ETH/WETH
        return None, "ETH/WETH inside the path"
    legs = []
    for i in range(n):
        a, b, v, p, fee, ts = toks[i], toks[(i + 1) % n], int(vers[i]), pls[i], fees[i], tss[i]
        if v == 2 and v2_pair(a, b) != p:
            return None, "v2 pair != CREATE2"
        if v == 3 and v3_pool(a, b, fee) != p:
            return None, "v3 pool != CREATE2"
        if v == 4:
            a, b = (ZERO if x == WETH else x for x in (a, b))
            if v4_id(*sorted((a, b)), fee, ts) != p:
                return None, "v4 pool id != hookless PoolKey"
        if v not in (2, 3, 4):
            return None, f"uniswap v{v} leg"
        legs.append((v, a, b, fee, ts))
    return legs, None


def anchor(legs):
    """pure-ETH (V4 at both ends), pure-WETH (V2/V3 at both ends) or mixed (wraps or unwraps at the anchor)."""
    first, last = legs[0][1] == ZERO, legs[-1][2] == ZERO
    return "pure-ETH" if first and last else "pure-WETH" if not (first or last) else "mixed"


USDC = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
_MIXED = {"tokens": f"{WETH},{USDC}", "versions": "4,3", "fees": "100,500", "spacings": "1,10",
          "pools": f"{ETH_USDC_V4_100},0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640"}
assert legs_of(_MIXED) == ([(4, ZERO, USDC, 100, 1), (3, USDC, WETH, 500, 10)], None)
assert anchor(legs_of(_MIXED)[0]) == "mixed"
assert legs_of({**_MIXED, "fees": "500,500"})[1] == "v4 pool id != hookless PoolKey"
assert legs_of({**_MIXED, "tokens": f"{WETH},{WETH}"})[1] == "ETH/WETH inside the path"


def read_pins(path):
    """One cycle name per line, in order; blank lines and `#` comments ignored."""
    lines = (l.split("#")[0].strip() for l in Path(path).read_text().splitlines())
    return list(dict.fromkeys(l for l in lines if l))


def apply_pins(out, pins):
    """Pinned cycles first, in pin order, then the rest in rank order. Returns (order, pins not in the set)."""
    at = {c[0]: c for c in out}
    first = [at[n] for n in pins if n in at]
    return first + [c for c in out if c[0] not in set(pins)], [n for n in pins if n not in at]


assert apply_pins([("a",), ("b",), ("c",)], ["c", "x", "a"]) == ([("c",), ("a",), ("b",)], ["x"])


def one_per_pool_set(out):
    """The first cycle of each pool set, in file order. A cycle and its reverse use the same pools, and the
    solver tries both orientations of every request, so a later cycle on the same pools adds only compute."""
    seen, kept = set(), []
    for c in out:
        pools = frozenset(pool_id(l) for l in c[-1])
        if pools not in seen:
            seen.add(pools)
            kept.append(c)
    return kept


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min-arbs", type=int, default=10, help="minimum arbs over the 30-day window")
    ap.add_argument("--rank", choices=("robust", "profit", "arbs"), default="robust",
                    help="file order after the pins (the bot sends the first pending_cap): robust = median clean profit per arb"
                         " x clean arbs (default); profit = 30-day clean profit; arbs = arb count")
    ap.add_argument("--pin", default=str(PINS), help="cycle names to put first, in order ('' for none); default %(default)s")
    ap.add_argument("--top", type=int, help="keep only the N best-ranked cycles")
    ap.add_argument("--live", default=str(LIVE),
                    help="cycles.toml order: these cycle names first, then rank order, then one orientation per pool set"
                         " ('' for the full ranked set, both orientations); the fork fixture keeps the full set;"
                         " default %(default)s")
    ap.add_argument("--refresh", action="store_true", help="fill missing tokens.json entries via cast")
    args = ap.parse_args()

    mined = json.loads(MINED.read_text())
    rows = mined["rows"]
    if args.refresh:
        refresh(TOKENS, {t for r in rows for t in r["tokens"].split(",")} - {ZERO}, fetch_symbol)
    syms = json.loads(TOKENS.read_text())
    dropped = collections.Counter()
    why_dropped = {}  # legs -> reason, for the previous-set diff

    def drop(legs, why):
        dropped[why] += 1
        if legs:
            why_dropped.setdefault(tuple(legs), why)

    cycles = {}  # legs tuple -> [arbs, profit_usd, robust_usd]
    for r in rows:
        legs, why = legs_of(r)
        if why is None:
            bad = sorted({EXCLUDED_TOKENS[l[1]] for l in legs if l[1] in EXCLUDED_TOKENS})
            ids = [pool_id(l) for l in legs]
            if r["arbs"] < args.min_arbs:
                why = "arbs < min"
            elif bad:
                why = "excluded token (" + bad[0].split(":")[0] + ")"
            elif len(set(ids)) != len(ids):  # e.g. the same V2 WETH/X pair at both ends
                why = "repeated pool"
            elif r["profit_usd"] <= 0:  # every arb unpriced, mispriced or at a loss
                why = "no clean profit"
        if why:
            drop(legs, why)
            continue
        c = cycles.setdefault(tuple(legs), [0, 0.0, 0.0])
        if c[0]:
            dropped["merged duplicate (arbs and profit summed)"] += 1
        c[0] += r["arbs"]
        c[1] += r["profit_usd"]
        # Repeatable value: median x count, so one large arb does not lift it. Capped at the profit: with 1-2 clean
        # arbs Dune's median is the upper element, and median x count can exceed the sum.
        c[2] += min(r["med_profit_usd"] * r["clean_arbs"], r["profit_usd"])

    def rank(kv):
        arbs, usd, robust = kv[1]
        return {"robust": (-robust, -usd, -arbs), "profit": (-usd, -arbs), "arbs": (-arbs, -usd)}[args.rank] + (kv[0],)

    out, names = [], set()
    for legs, (arbs, usd, robust) in sorted(cycles.items(), key=rank):
        base = cycle_name(legs, syms)
        name, i = base, 2
        while name in names:
            name, i = f"{base}_{i}", i + 1
        names.add(name)
        out.append((name, arbs, usd, robust, list(legs)))
    pins = read_pins(args.pin) if args.pin else []
    out, missing_pins = apply_pins(out, pins)
    if args.top is not None:
        for *_, legs in out[args.top:]:
            drop(legs, f"beyond --top {args.top}")
        out = out[: args.top]
    # The bot's file: the live order, one orientation per pool set. The fixture keeps every candidate.
    live_pins = read_pins(args.live) if args.live else []
    sel, missing_live = apply_pins(out, live_pins)
    if args.live:
        sel = one_per_pool_set(sel)
        in_file = {tuple(l) for *_, l in sel}
        for *_, legs in out:
            if tuple(legs) not in in_file:
                why_dropped.setdefault(tuple(legs), "same pool set as an earlier cycle")
    # One request covers both orientations of its pool set: count the profit of both.
    covered = {frozenset(map(pool_id, l)) for *_, l in sel}

    # The file this run replaces: which of its cycles survive, and why the rest do not.
    prev = [tuple((l["version"], l["token_in"].lower(), l["token_out"].lower(), l["fee"], l["tick_spacing"]) for l in c["legs"])
            for c in tomllib.loads(TOML_OUT.read_text())["cycles"]] if TOML_OUT.exists() else []
    kept = {tuple(l) for *_, l in sel}
    prev_fate = collections.Counter("kept" if k in kept else why_dropped.get(k, "not mined (< 5 arbs, or a different pool now)") for k in prev)

    total_usd = sum(r["profit_usd"] for r in rows)
    usd_of = {k: v[1] for k, v in cycles.items()}
    by_cls = collections.defaultdict(lambda: [0, 0.0])
    for _, _, usd, _, l in sel:
        by_cls[anchor(l)][0] += 1
        by_cls[anchor(l)][1] += usd
    by_legs = collections.Counter(len(l) for *_, l in sel)
    by_mix = collections.Counter("/".join(f"v{x[0]}" for x in l) for *_, l in sel)
    summary = [
        f"cycles: {len(out)}, ranked by {args.rank}"
        + (f" after {len(pins) - len(missing_pins)} pinned ({Path(args.pin).name})" if pins else ""),
        *([f"pins not in the set: {', '.join(missing_pins)}"] if missing_pins else []),
        *([f"live order: {len(live_pins) - len(missing_live)} first ({Path(args.live).name}), then rank order;"
           f" one orientation per pool set: {len(sel)} of {len(out)} cycles (the fork fixture keeps all {len(out)})"]
          if args.live else []),
        *([f"live names not in the set: {', '.join(missing_live)}"] if missing_live else []),
        "by anchor: " + ", ".join(f"{k} {n} (${u:,.0f})" for k, (n, u) in sorted(by_cls.items())),
        "by legs: " + ", ".join(f"{k}-leg {v}" for k, v in sorted(by_legs.items())),
        "by versions: " + ", ".join(f"{k} {v}" for k, v in sorted(by_mix.items(), key=lambda kv: (-kv[1], kv[0]))),
        f"clean profit covered (both orientations of each pool set): "
        f"${sum(u for _, _, u, _, l in out if frozenset(map(pool_id, l)) in covered):,.0f} of ${total_usd:,.0f} in the mined rows (>= 5 arbs)",
        "dropped: " + (", ".join(f"{k} {v}" for k, v in sorted(dropped.items())) or "none"),
    ]

    toml = [
        "# GENERATED by cycles/build.py -- do not edit; rebuild with `python3 cycles/build.py`.",
        f"# Source: Dune query {mined['query_id']}; rows in {MINED.relative_to(ROOT)}.",
        "# Window: a 30-day window, Ethereum mainnet, closed cycles anchored at ETH or WETH (one asset).",
        f"# Filters: Uniswap V2/V3/hookless V4, at least 2 legs, distinct pools, arbs >= {args.min_arbs}, clean profit > 0,",
        "#     pools checked against CREATE2 (V2/V3) or the hookless PoolKey id (V4); each mined direction is its own cycle.",
        f"# Order: {'live order (--live) first, then ' if args.live else 'pins first, then '}by {args.rank}"
        f"{', one orientation per pool set' if args.live else ''} (the bot sends the first pending_cap groups).",
        *("# " + s for s in summary),
        "",
    ]
    for name, arbs, usd, robust, legs in sel:
        toml += [f"# {arbs} arbs, ${usd:,.0f} / 30d (robust ${robust:,.0f}), {anchor(legs)}", "[[cycles]]", f'name = "{name}"', "legs = ["]
        for v, a, b, fee, ts in legs:
            toml.append(f'  {{ version = {v}, token_in = "{checksum(a)}", token_out = "{checksum(b)}", fee = {fee}, tick_spacing = {ts} }},')
        toml += ["]", ""]
    fixture = []
    for name, arbs, usd, robust, legs in out:
        fixture.append({"name": name, "legs": [
            {"version": v, "tokenIn": checksum(a), "tokenOut": checksum(b), "fee": fee, "tickSpacing": ts}
            for v, a, b, fee, ts in legs]})
    TOML_OUT.write_text("\n".join(toml))
    FIXTURE_OUT.write_text(json.dumps(fixture, indent=1))  # the fixture has no trailing newline
    print("\n".join(summary))
    # Printed only, so a rebuild of an unchanged input rewrites the same file.
    print(f"replaced file ({len(prev)} cycles, ${sum(usd_of.get(k, 0) for k in prev):,.0f} of clean profit in these rows): "
          + ", ".join(f"{k} {v}" for k, v in sorted(prev_fate.items(), key=lambda kv: (-kv[1], kv[0]))))
    print("top 32:")
    for i, (name, arbs, usd, robust, legs) in enumerate(sel[:32], 1):
        print(f"{i:3} {name:48} {anchor(legs):9} {arbs:5} arbs  ${usd:>9,.0f}  robust ${robust:>8,.0f}{'  pin' if name in pins else ''}")
    print("arbs < 30 in the first 32 / 128: " + " / ".join(str(sum(1 for c in sel[:n] if c[1] < 30)) for n in (32, 128)))


if __name__ == "__main__":
    main()

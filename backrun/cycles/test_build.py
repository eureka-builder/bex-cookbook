import importlib.util
import json
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("build", HERE / "build.py")
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)

SYMS = json.loads((HERE / "tokens.json").read_text())
ADDR = {v.lower(): k for k, v in SYMS.items()}


def legs_from_name(name):
    """Legs for a generated name like eth_usdt_usdc__v3_100_v4_7_v3_500 (V2 fee/spacing 0; fee = the number)."""
    toks, vers = name.split("__")
    syms, parts = toks.split("_"), vers.split("_")
    addrs = [build.WETH if s == "eth" else ADDR[s] for s in syms]
    legs, i, k = [], 0, 0
    while i < len(parts):
        v = int(parts[i][1:])
        fee = 0 if v == 2 else int(parts[i + 1])
        i += 1 if v == 2 else 2
        legs.append((v, addrs[k], addrs[(k + 1) % len(addrs)], fee, 0))
        k += 1
    return tuple(legs)


class NameTest(unittest.TestCase):
    def test_forward_name_roundtrip(self):
        for n in ("eth_usdc__v3_500_v3_100", "eth_usdt_usdc__v3_100_v4_7_v3_500"):
            self.assertEqual(build.cycle_name(legs_from_name(n), SYMS), n)


class PoolSetTest(unittest.TestCase):
    def test_one_per_pool_set_keeps_the_first_orientation(self):
        fwd = legs_from_name("eth_usdc__v3_500_v3_100")
        other = legs_from_name("eth_usdt__v3_500_v3_100")
        rev = [(v, b, a, fee, ts) for v, a, b, fee, ts in reversed(fwd)]  # the same pools, walked the other way
        out = [("fwd", list(fwd)), ("rev", rev), ("other", list(other))]
        self.assertEqual([c[0] for c in build.one_per_pool_set(out)], ["fwd", "other"])


if __name__ == "__main__":
    unittest.main()

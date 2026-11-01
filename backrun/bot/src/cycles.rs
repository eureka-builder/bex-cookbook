//! `cycles.toml`, the cycles the bot tries. A cycle is a closed path of swaps (legs) on Uniswap V2, V3 or
//! V4 pools that start and end on ETH. [`load_cycles`] refuses a cycle that the contracts would
//! refuse (`Pools.validate`), so a bad file fails at startup and not on every block.
//! `cycles/build.py` writes the mainnet file. `groups.rs` puts the cycles into requests.
use alloy::primitives::Address;
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::{collections::HashSet, path::Path};

/// Mirrors the Solidity `Leg { uint8 version; address tokenIn; address tokenOut; uint24 fee; int24 tickSpacing; }`.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Leg {
    pub version: u8,
    pub token_in: Address,
    pub token_out: Address,
    pub fee: u32,
    pub tick_spacing: i32,
}

/// One cycle. The solver prices its gas (`floor.rs` sends only the gas price).
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Cycle {
    pub name: String,
    pub legs: Vec<Leg>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct File {
    cycles: Vec<Cycle>,
}

/// Reads `cycles.toml` in file order. Names must be unique, and every cycle must pass [`validate`].
pub fn load_cycles(path: &Path, weth: Address) -> Result<Vec<Cycle>> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("reading {} (--cycles)", path.display()))?;
    let file: File =
        toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))?;
    let mut names = HashSet::new();
    for c in &file.cycles {
        if !names.insert(c.name.as_str()) {
            bail!("duplicate cycle name {}", c.name);
        }
        validate(c, weth).with_context(|| format!("cycle {}", c.name))?;
    }
    Ok(file.cycles)
}

/// The checks of `Pools.validate` in the contracts: at least 2 legs, known versions, field widths,
/// ETH as `address(0)` on V4 and as WETH on V2/V3, a closed chain from ETH back to ETH, and no
/// pool twice.
fn validate(c: &Cycle, weth: Address) -> Result<()> {
    if c.legs.len() < 2 {
        bail!("needs at least 2 legs, has {}", c.legs.len());
    }
    // ETH anchor: address(0) and WETH are the same asset.
    let norm = |a: Address| if a == weth { Address::ZERO } else { a };
    for (i, l) in c.legs.iter().enumerate() {
        if !matches!(l.version, 2..=4) {
            bail!("leg {i}: version {} not in {{2,3,4}}", l.version);
        }
        if l.fee >= 1 << 24 {
            bail!("leg {i}: fee {} does not fit uint24", l.fee);
        }
        if !(-(1 << 23)..1 << 23).contains(&l.tick_spacing) {
            bail!(
                "leg {i}: tick_spacing {} does not fit int24",
                l.tick_spacing
            );
        }
        if l.version == 2 && (l.fee != 3000 || l.tick_spacing != 0) {
            bail!("leg {i}: V2 leg needs fee 3000 and tick_spacing 0");
        }
        if l.version != 4 && (l.token_in == Address::ZERO || l.token_out == Address::ZERO) {
            bail!("leg {i}: V2/V3 leg must use WETH, not address(0)");
        }
        if l.version == 4 && (l.token_in == weth || l.token_out == weth) {
            bail!("leg {i}: V4 leg must use address(0) for ETH, not WETH");
        }
        let next = &c.legs[(i + 1) % c.legs.len()];
        if norm(l.token_out) != norm(next.token_in) {
            bail!("leg {i}: token_out does not match next leg's token_in");
        }
    }
    if norm(c.legs[0].token_in) != Address::ZERO {
        bail!("first token_in must be address(0) or WETH");
    }
    // Pools.validate reverts BadLeg on a repeated pool, which would revert every solveMany of the
    // cycle's group on every block.
    let mut pools = HashSet::new();
    for (i, l) in c.legs.iter().enumerate() {
        if !pools.insert(onchain_pool(l)) {
            bail!("leg {i}: repeats a pool of an earlier leg; remove the cycle or change the leg");
        }
    }
    Ok(())
}

/// A leg's pool as the chain knows it: V2 (pair), V3 (pair, fee), V4 (pair, fee, tick spacing).
/// V3's tick spacing is the pool's own, not part of its address.
fn onchain_pool(l: &Leg) -> (u8, Address, Address, u32, i32) {
    let (a, b) = if l.token_in <= l.token_out {
        (l.token_in, l.token_out)
    } else {
        (l.token_out, l.token_in)
    };
    match l.version {
        2 => (2, a, b, 0, 0),
        3 => (3, a, b, l.fee, 0),
        _ => (4, a, b, l.fee, l.tick_spacing),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::address;
    use std::str::FromStr;

    const WETH: Address = address!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
    const USDC: Address = address!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
    const ZERO: Address = Address::ZERO;

    fn leg(version: u8, a: Address, b: Address, fee: u32, ts: i32) -> Leg {
        Leg {
            version,
            token_in: a,
            token_out: b,
            fee,
            tick_spacing: ts,
        }
    }
    fn v3(a: Address, b: Address) -> Leg {
        leg(3, a, b, 500, 10)
    }
    fn cyc(name: &str, legs: Vec<Leg>) -> Cycle {
        Cycle {
            name: name.into(),
            legs,
        }
    }

    #[test]
    fn test_validate_table() {
        let ok2 = vec![v3(WETH, USDC), leg(3, USDC, WETH, 3000, 60)];
        let cases: Vec<(&str, Vec<Leg>, bool)> = vec![
            (
                "fee 2^24",
                vec![leg(3, WETH, USDC, 1 << 24, 10), v3(USDC, WETH)],
                false,
            ),
            (
                "tick 2^23",
                vec![leg(3, WETH, USDC, 500, 1 << 23), v3(USDC, WETH)],
                false,
            ),
            (
                "tick -2^23-1",
                vec![leg(3, WETH, USDC, 500, -(1 << 23) - 1), v3(USDC, WETH)],
                false,
            ),
            (
                "v2 fee",
                vec![leg(2, WETH, USDC, 500, 0), v3(USDC, WETH)],
                false,
            ),
            (
                "v2 tick",
                vec![leg(2, WETH, USDC, 3000, 1), v3(USDC, WETH)],
                false,
            ),
            (
                "v4 weth",
                vec![leg(4, WETH, USDC, 500, 10), v3(USDC, WETH)],
                false,
            ),
            ("v3 zero in", vec![v3(ZERO, USDC), v3(USDC, WETH)], false),
            (
                "v2 zero out",
                vec![v3(WETH, USDC), leg(2, USDC, ZERO, 3000, 0)],
                false,
            ),
            ("1 leg", vec![v3(WETH, WETH)], false),
            (
                "6 legs",
                vec![
                    v3(WETH, USDC),
                    v3(USDC, USDC),
                    v3(USDC, USDC),
                    v3(USDC, USDC),
                    v3(USDC, USDC),
                    v3(USDC, WETH),
                ],
                false,
            ),
            ("wrong anchor", vec![v3(USDC, WETH), v3(WETH, USDC)], false),
            ("ok", ok2.clone(), true),
            (
                "repeated v3 pool",
                vec![v3(WETH, USDC), v3(USDC, WETH), v3(WETH, WETH)],
                false,
            ),
            (
                "repeated v3 pool, other tick_spacing",
                vec![
                    leg(3, WETH, USDC, 500, 10),
                    leg(3, USDC, USDC, 3000, 60),
                    leg(3, USDC, WETH, 500, 1),
                ],
                false,
            ),
            (
                "repeated v2 pair",
                vec![
                    leg(2, WETH, USDC, 3000, 0),
                    v3(USDC, USDC),
                    leg(2, USDC, WETH, 3000, 0),
                ],
                false,
            ),
            (
                "same v4 pair, other fee: distinct pools",
                vec![leg(4, ZERO, USDC, 500, 10), leg(4, USDC, ZERO, 3000, 60)],
                true,
            ),
            (
                "same v4 pair and fee, other tick_spacing: distinct pools",
                vec![leg(4, ZERO, USDC, 500, 10), leg(4, USDC, ZERO, 500, 60)],
                true,
            ),
            (
                "repeated v4 pool",
                vec![
                    leg(4, ZERO, USDC, 500, 10),
                    leg(4, USDC, USDC, 100, 1),
                    leg(4, USDC, ZERO, 500, 10),
                ],
                false,
            ),
            (
                "weth cycle closing with address(0) via v4",
                vec![v3(WETH, USDC), leg(4, USDC, ZERO, 500, 10)],
                true,
            ),
        ];
        for (name, legs, ok) in cases {
            assert_eq!(validate(&cyc("c", legs), WETH).is_ok(), ok, "{name}");
        }
    }

    fn tmp(name: &str, body: &str) -> std::path::PathBuf {
        let p = std::env::temp_dir().join(format!("bex-cyc-{}-{name}", std::process::id()));
        std::fs::write(&p, body).unwrap();
        p
    }

    #[test]
    fn test_load_cycles_devnet_fixture_has_8() {
        let weth = Address::from_str("0x5fbdb2315678afecb367f032d93f642f64180aa3").unwrap();
        let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/cycles.devnet.toml");
        let cycles = load_cycles(&p, weth).unwrap();
        assert_eq!(cycles.len(), 8);
    }

    #[test]
    fn test_load_cycles_rejects_broken_chain() {
        let weth = Address::repeat_byte(0xee);
        let (a, b, c) = (
            "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            "0x00000000000000000000000000000000000000aa",
            "0x00000000000000000000000000000000000000bb",
        );
        let leg = |i: &str, o: &str, fee: u32| {
            format!("{{ version = 3, token_in = \"{i}\", token_out = \"{o}\", fee = {fee}, tick_spacing = 10 }}")
        };
        let bad = format!(
            "[[cycles]]\nname = \"x\"\nlegs = [{}, {}]\n",
            leg(a, b, 500),
            leg(c, a, 3000)
        );
        assert!(load_cycles(&tmp("bad.toml", &bad), weth).is_err());
        let good = format!(
            "[[cycles]]\nname = \"x\"\nlegs = [{}, {}]\n",
            leg(a, b, 500),
            leg(b, a, 3000)
        );
        assert!(load_cycles(&tmp("good.toml", &good), weth).is_ok());
    }

    #[test]
    fn test_cycles_example_loads_with_mainnet_weth() {
        let weth = Address::from_str("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2").unwrap();
        let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("cycles.example.toml");
        assert!(!load_cycles(&p, weth).unwrap().is_empty());
    }

    #[test]
    fn test_duplicate_names_rejected() {
        let legs = vec![v3(WETH, USDC), leg(3, USDC, WETH, 3000, 60)];
        let toml = |names: [&str; 2]| {
            let mut s = String::new();
            for n in names {
                s += &format!("[[cycles]]\nname = \"{n}\"\nlegs = [\n");
                for l in &legs {
                    s += &format!(
                        "{{ version = 3, token_in = \"{}\", token_out = \"{}\", fee = {}, tick_spacing = {} }},\n",
                        l.token_in, l.token_out, l.fee, l.tick_spacing
                    );
                }
                s += "]\n";
            }
            s
        };
        let dir = std::env::temp_dir().join(format!("cyc-dup-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("c.toml");
        std::fs::write(&p, toml(["a", "a"])).unwrap();
        assert!(load_cycles(&p, WETH).is_err());
        std::fs::write(&p, toml(["a", "b"])).unwrap();
        assert_eq!(load_cycles(&p, WETH).unwrap().len(), 2);
    }
}

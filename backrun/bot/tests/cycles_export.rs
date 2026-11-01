use alloy::primitives::{address, Address};
use bex_backrun::cycles::load_cycles;
use std::path::Path;

const WETH: Address = address!("5fbdb2315678afecb367f032d93f642f64180aa3");

fn load(name: &str) -> Vec<bex_backrun::cycles::Cycle> {
    let p = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    load_cycles(&p, WETH).unwrap()
}

/// A file in the expanded `[[cycles.legs]]` layout (what a TOML writer emits) loads under the
/// devnet WETH and holds the same cycles as the hand-written fixture.
#[test]
fn test_devnet_export_parses_and_matches_fixture() {
    let exported = load("cycles.devnet.exported.toml");
    assert_eq!(exported.len(), 8);
    assert_eq!(exported, load("cycles.devnet.toml"));
}

/// The generated mainnet set (`cycles/build.py`) loads under the mainnet WETH, all of it.
#[test]
fn test_mainnet_cycle_set_loads() {
    let weth = address!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../cycles/cycles.toml");
    let cycles = load_cycles(&p, weth).unwrap();
    // Exact: a truncated regeneration fails here. Update with the build.py summary.
    assert_eq!(cycles.len(), 688);
}

/// What `bot.example.toml` sends from the mainnet set (`cycles/README.md`): the first `pending_cap`
/// groups of `group_size`, in file order. Update with the README when the set changes.
#[test]
fn test_example_config_selects_64_groups_of_205_cycles() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let text = std::fs::read_to_string(dir.join("bot.example.toml")).unwrap();
    let cfg: bex_backrun::config::BotConfig = toml::from_str(&text).unwrap();
    let cycles = load_cycles(&dir.join("../cycles/cycles.toml"), cfg.weth).unwrap();
    let groups = bex_backrun::run::select_groups(&cfg, &cycles).unwrap();
    let sent: usize = groups.iter().map(|g| g.cycles.len()).sum();
    assert_eq!((groups.len(), sent, cycles.len()), (64, 205, 688));
}

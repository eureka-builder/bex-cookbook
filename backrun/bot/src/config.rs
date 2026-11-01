//! `bot.toml`, the bot's settings. [`load_bot`] reads the file, resolves relative paths against
//! its directory, reads the code files, and refuses settings that cannot work. Every command
//! starts here. The comments in `bot/bot.example.toml` explain each setting for an operator.
use alloy::primitives::{Address, Bytes, U256};
use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use url::Url;

/// Parsed `bot.toml`. The signer key is never a field: it is read from the
/// env var named by `signer_key_env`, and an unknown `signer_key` is rejected.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BotConfig {
    // Where requests and reads go.
    /// Builder BEX endpoints. Every request goes to every endpoint.
    pub endpoints: Vec<Url>,
    /// The Ethereum node: heads, `eth_call` checks and probes, landing logs.
    pub rpc_http: Url,
    /// Optional WS URL for `newHeads` (`head.rs`).
    #[serde(default)]
    pub rpc_ws: Option<Url>,

    // The contracts.
    /// The deployed solver. Leave unset in code mode (`solver_code`): the compute target is
    /// then derived per request (`request::code_target`).
    #[serde(default)]
    pub solver: Address,
    /// Code mode: a file with the solver's runtime code as hex (`contracts/script/RuntimeCode.s.sol`),
    /// sent as `bex.compute.code`. A relative path is resolved against the config file's directory.
    #[serde(default)]
    pub solver_code: Option<PathBuf>,
    /// The bytes of `solver_code`, read by `load_bot`.
    #[serde(skip)]
    pub solver_code_bytes: Option<Bytes>,
    pub executor: Address,
    /// The executor's runtime code as hex, for `simulate --override-code` only: it is installed
    /// at `executor` by a state override, so the executor need not be deployed. `run` never
    /// uses it. Relative to the config file's directory.
    #[serde(default)]
    pub executor_code: Option<PathBuf>,
    /// The bytes of `executor_code`, read by `load_bot`.
    #[serde(skip)]
    pub executor_code_bytes: Option<Bytes>,
    /// WETH of the venues. A cycle may use it or `address(0)` for ETH (`cycles.rs`).
    pub weth: Address,

    // The signer and the profit floor inputs (`floor.rs`).
    #[serde(default = "d_key_env")]
    pub signer_key_env: String,
    /// The share of the profit that goes to `block.coinbase`, 1..=10000 bps.
    #[serde(default = "d_share")]
    pub builder_share_bps: u16,
    /// Who gets the profit after the builder's share (`Plan.recipient`). Default: the signer
    /// address. Under BEX the builder's operator key calls `execute`, so without this the rest
    /// would go to that key.
    #[serde(default)]
    pub payout_address: Option<Address>,
    /// The lower bound of every cycle's profit floor (`minProfitWei`).
    #[serde(default)]
    pub min_profit_wei: U256,
    /// Multiplier (>= 1.0) on the gas cost in the floor.
    #[serde(default = "d_margin")]
    pub gas_margin: f64,

    // What `run` sends (`run::select_groups`).
    /// The signer's pending limit on the builder: the most requests live at once.
    #[serde(default = "d_pending")]
    pub pending_cap: usize,
    /// What `run` does when there are more groups than `pending_budget()`.
    #[serde(default)]
    pub select: Select,
    /// Cycles per request (1..=8): `run` groups cycles that share a pool with the group's first
    /// cycle (`groups::group_cycles`) and sends one `solveMany` request per group. 1 = one per cycle.
    #[serde(default = "d_group")]
    pub group_size: usize,
    /// Requests per group per block (1..=4): copy k >= 1 is keyed (uuid, code target) by
    /// `<group name>#k`, so after one copy's execute commits, the builder evaluates the next one on
    /// the post-commit state. Code mode only: the builder's bundle hash omits the uuid.
    #[serde(default = "d_copies")]
    pub request_copies: usize,
    /// How `replacementUuid` is keyed (`request::build_group_request`).
    #[serde(default)]
    pub uuid_mode: UuidMode,

    // Timing.
    /// Wait after a new head before the first send. 200 by default: the builder stops admitting
    /// requests for a block about 3 s before its slot, and its queue wait is about 1.6 s (p50), so
    /// a later send is not evaluated.
    #[serde(default = "d_send_delay")]
    pub send_delay_ms: u64,
    /// Timeout of one `bex_sendBundle`, 3000 ms by default. A send that times out is retried once.
    #[serde(default = "d_send_timeout")]
    pub send_timeout_ms: u64,

    // Records (`store.rs`, `track.rs`).
    /// The SQLite file. A relative path is resolved against the config file's directory.
    #[serde(default = "d_db")]
    pub db_path: PathBuf,
}

/// `top`: send the first `pending_budget()` groups in file order (file order = rank).
/// `all`: send every group; refuse to start if there are more than the budget.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Select {
    #[default]
    Top,
    All,
}

/// `cycle` (default): one `replacementUuid` per (signer, request name); each block's request
/// replaces the previous one. `parity`: one per (signer, request name, target block mod 2), so the
/// request for N+1 does not replace N's; it costs half the budget (see `pending_budget`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum UuidMode {
    Parity,
    #[default]
    Cycle,
}

impl BotConfig {
    /// The most requests (groups x `request_copies`) `run` sends per block. In parity mode two
    /// targets are live at once (N and N+1), so each gets half of `pending_cap`.
    pub fn pending_budget(&self) -> usize {
        match self.uuid_mode {
            UuidMode::Parity => self.pending_cap / 2,
            UuidMode::Cycle => self.pending_cap,
        }
    }
}

/// EIP-170, and the builder's `max_compute_code_bytes` default and cap.
pub const MAX_CODE_BYTES: usize = 24_576;

/// Reads a 0x-hex runtime code file; refuses empty code and code over `MAX_CODE_BYTES`.
pub fn read_code(path: &Path) -> Result<Bytes> {
    let text =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    let code: Bytes = text
        .trim()
        .parse()
        .with_context(|| format!("{}: not hex", path.display()))?;
    if code.is_empty() {
        bail!("{}: empty code (the builder refuses `0x`)", path.display());
    }
    if code.len() > MAX_CODE_BYTES {
        bail!(
            "{}: {} bytes of code, over the {MAX_CODE_BYTES}-byte limit",
            path.display(),
            code.len()
        );
    }
    Ok(code)
}

fn d_key_env() -> String {
    "BEX_SIGNER_KEY".into()
}
fn d_share() -> u16 {
    5_000
}
fn d_margin() -> f64 {
    1.0
}
/// The builder's default pending limit per signer. The builder accepts a request above the
/// signer's limit and drops it.
fn d_pending() -> usize {
    8
}
fn d_group() -> usize {
    1
}
fn d_copies() -> usize {
    1
}
fn d_send_delay() -> u64 {
    200
}
fn d_send_timeout() -> u64 {
    3_000
}
fn d_db() -> PathBuf {
    "bex-backrun.sqlite".into()
}

/// Reads and checks `bot.toml`. Every error names the setting to fix.
pub fn load_bot(path: &Path) -> Result<BotConfig> {
    let text = std::fs::read_to_string(path)
        .with_context(|| format!("reading {} (--config)", path.display()))?;
    let mut cfg: BotConfig =
        toml::from_str(&text).with_context(|| format!("parsing {}", path.display()))?;
    if let Some(dir) = path.parent() {
        cfg.db_path = dir.join(&cfg.db_path); // a no-op for an absolute db_path
        cfg.solver_code = cfg.solver_code.map(|p| dir.join(p));
        cfg.executor_code = cfg.executor_code.map(|p| dir.join(p));
    }
    if let Some(p) = &cfg.executor_code {
        cfg.executor_code_bytes = Some(read_code(p)?);
    }
    if cfg.solver_code.is_none() && cfg.solver == Address::ZERO {
        bail!("set solver (a deployed solver) or solver_code (code mode)");
    }
    if let Some(p) = &cfg.solver_code {
        if cfg.solver != Address::ZERO {
            bail!("set solver or solver_code, not both: in code mode the compute target is derived per request");
        }
        cfg.solver_code_bytes = Some(read_code(p)?);
    }
    if cfg.endpoints.is_empty() {
        bail!("endpoints must list at least one builder endpoint");
    }
    if cfg.builder_share_bps == 0 || cfg.builder_share_bps > 10_000 {
        bail!(
            "builder_share_bps must be in 1..=10000, got {}",
            cfg.builder_share_bps
        );
    }
    if !(1..=8).contains(&cfg.group_size) {
        bail!("group_size must be in 1..=8, got {}", cfg.group_size);
    }
    if !(1..=4).contains(&cfg.request_copies) {
        bail!(
            "request_copies must be in 1..=4, got {}",
            cfg.request_copies
        );
    }
    if cfg.request_copies > 1 && cfg.solver_code.is_none() {
        bail!("request_copies > 1 needs solver_code: the builder's bundle hash omits the replacementUuid, so copies with one deployed solver are one request");
    }
    if !(cfg.gas_margin.is_finite() && cfg.gas_margin >= 1.0) {
        bail!(
            "gas_margin must be finite and >= 1.0, got {}",
            cfg.gas_margin
        );
    }
    Ok(cfg)
}

#[cfg(test)]
mod tests {
    use super::*;

    const BASE: &str = r#"
rpc_http = "http://127.0.0.1:8545"
solver = "0x0000000000000000000000000000000000000001"
executor = "0x0000000000000000000000000000000000000002"
weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
"#;

    fn tmp(name: &str, body: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("bex-{}-{name}", std::process::id()));
        std::fs::write(&p, body).unwrap();
        p
    }

    #[test]
    fn test_load_bot_requires_endpoint() {
        assert!(load_bot(&tmp("noep.toml", BASE)).is_err());
        let empty = format!("endpoints = []\n{BASE}");
        assert!(load_bot(&tmp("emptyep.toml", &empty)).is_err());
        let ok = format!("endpoints = [\"http://localhost:1\"]\n{BASE}");
        let cfg = load_bot(&tmp("ok.toml", &ok)).unwrap();
        assert_eq!(cfg.signer_key_env, "BEX_SIGNER_KEY");
        assert_eq!(cfg.builder_share_bps, 5_000);
        assert_eq!(cfg.payout_address, None);
        assert_eq!(cfg.gas_margin, 1.0);
        assert_eq!(cfg.pending_cap, 8);
        assert_eq!(cfg.select, Select::Top);
        assert_eq!(cfg.uuid_mode, UuidMode::Cycle);
        assert_eq!(cfg.send_delay_ms, 200);
        assert_eq!(cfg.send_timeout_ms, 3_000);
        assert_eq!(cfg.db_path, std::env::temp_dir().join("bex-backrun.sqlite"));
    }

    #[test]
    fn test_load_bot_rejects_share_out_of_range() {
        for bad in [0, 10_001] {
            let s =
                format!("endpoints = [\"http://localhost:1\"]\nbuilder_share_bps = {bad}\n{BASE}");
            let e = load_bot(&tmp("share.toml", &s)).unwrap_err().to_string();
            assert!(e.contains("builder_share_bps"), "{e}");
        }
    }

    #[test]
    fn test_load_bot_payout_address() {
        let s = format!(
            "endpoints = [\"http://localhost:1\"]\npayout_address = \"0x00000000000000000000000000000000000000aa\"\n{BASE}"
        );
        let cfg = load_bot(&tmp("payout.toml", &s)).unwrap();
        assert_eq!(cfg.payout_address, Some(Address::with_last_byte(0xaa)));
        let s = format!("endpoints = [\"http://localhost:1\"]\npayout_address = \"0x12\"\n{BASE}");
        assert!(load_bot(&tmp("payoutbad.toml", &s)).is_err());
    }

    #[test]
    fn test_load_bot_rejects_bad_gas_margin() {
        for bad in ["0.99", "nan", "inf", "-1.0"] {
            let s = format!("endpoints = [\"http://localhost:1\"]\ngas_margin = {bad}\n{BASE}");
            let e = load_bot(&tmp("margin.toml", &s)).unwrap_err().to_string();
            assert!(e.contains("gas_margin"), "{bad}: {e}");
        }
    }

    /// `BASE` without `solver`: code mode derives the target.
    fn code_base() -> String {
        BASE.replace(
            "solver = \"0x0000000000000000000000000000000000000001\"\n",
            "",
        )
    }

    #[test]
    fn test_load_bot_deployed_mode_requires_solver() {
        let s = format!("endpoints = [\"http://localhost:1\"]\n{}", code_base());
        let e = load_bot(&tmp("nosolver.toml", &s)).unwrap_err().to_string();
        assert!(e.contains("set solver"), "{e}");
    }

    #[test]
    fn test_load_bot_refuses_solver_with_solver_code() {
        let code = tmp("both.hex", "0x6001");
        let s = format!(
            "endpoints = [\"http://localhost:1\"]\nsolver_code = \"{}\"\n{BASE}",
            code.display()
        );
        let e = load_bot(&tmp("both.toml", &s)).unwrap_err().to_string();
        assert!(e.contains("not both"), "{e}");
    }

    #[test]
    fn test_load_bot_reads_solver_code_relative_to_config() {
        let dir = std::env::temp_dir().join(format!("bex-code-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("solver.hex"), "0x6001600055\n").unwrap();
        let p = dir.join("bot.toml");
        let s = format!(
            "endpoints = [\"http://localhost:1\"]\nsolver_code = \"solver.hex\"\n{}",
            code_base()
        );
        std::fs::write(&p, s).unwrap();
        let cfg = load_bot(&p).unwrap();
        assert_eq!(
            cfg.solver_code_bytes.unwrap().to_vec(),
            vec![0x60, 1, 0x60, 0, 0x55]
        );
        assert!(cfg.executor_code_bytes.is_none());
        std::fs::write(dir.join("executor.hex"), "0x6002").unwrap();
        let s = format!(
            "endpoints = [\"http://localhost:1\"]\nsolver_code = \"solver.hex\"\nexecutor_code = \"executor.hex\"\n{}",
            code_base()
        );
        std::fs::write(&p, s).unwrap();
        assert_eq!(
            load_bot(&p).unwrap().executor_code_bytes.unwrap().to_vec(),
            vec![0x60, 2]
        );
    }

    #[test]
    fn test_load_bot_refuses_empty_or_oversized_code() {
        for (name, hex, want) in [
            ("empty", "0x".to_string(), "empty code"),
            (
                "big",
                format!("0x{}", "00".repeat(MAX_CODE_BYTES + 1)),
                "24576",
            ),
        ] {
            let code = tmp(&format!("{name}.hex"), &hex);
            let s = format!(
                "endpoints = [\"http://localhost:1\"]\nsolver_code = \"{}\"\n{}",
                code.display(),
                code_base()
            );
            let e = format!("{:#}", load_bot(&tmp("code.toml", &s)).unwrap_err());
            assert!(e.contains(want), "{name}: {e}");
        }
        let at_cap = tmp("cap.hex", &format!("0x{}", "00".repeat(MAX_CODE_BYTES)));
        let s = format!(
            "endpoints = [\"http://localhost:1\"]\nsolver_code = \"{}\"\n{}",
            at_cap.display(),
            code_base()
        );
        assert!(load_bot(&tmp("cap.toml", &s)).is_ok());
    }

    #[test]
    fn test_load_bot_select_values() {
        let s = format!("endpoints = [\"http://localhost:1\"]\nselect = \"all\"\n{BASE}");
        assert_eq!(load_bot(&tmp("sel.toml", &s)).unwrap().select, Select::All);
        let s = format!("endpoints = [\"http://localhost:1\"]\nselect = \"best\"\n{BASE}");
        assert!(load_bot(&tmp("selbad.toml", &s)).is_err());
        let s = format!("endpoints = [\"http://localhost:1\"]\nuuid_mode = \"parity\"\n{BASE}");
        assert_eq!(
            load_bot(&tmp("um.toml", &s)).unwrap().uuid_mode,
            UuidMode::Parity
        );
        let s = format!("endpoints = [\"http://localhost:1\"]\nuuid_mode = \"block\"\n{BASE}");
        assert!(load_bot(&tmp("umbad.toml", &s)).is_err());
    }

    #[test]
    fn test_load_bot_group_size() {
        let ok = format!("endpoints = [\"http://localhost:1\"]\n{BASE}");
        assert_eq!(load_bot(&tmp("gs.toml", &ok)).unwrap().group_size, 1);
        for (n, good) in [(0, false), (1, true), (8, true), (9, false)] {
            let s = format!("endpoints = [\"http://localhost:1\"]\ngroup_size = {n}\n{BASE}");
            let r = load_bot(&tmp("gs.toml", &s));
            assert_eq!(r.is_ok(), good, "{n}");
            if let Err(e) = r {
                assert!(e.to_string().contains("group_size"), "{e}");
            }
        }
    }

    #[test]
    fn test_load_bot_request_copies() {
        let ok = format!("endpoints = [\"http://localhost:1\"]\n{BASE}");
        assert_eq!(load_bot(&tmp("rc.toml", &ok)).unwrap().request_copies, 1);
        let code = tmp("rc.hex", "0x6001");
        for (n, good) in [(0, false), (1, true), (4, true), (5, false)] {
            let s = format!(
                "endpoints = [\"http://localhost:1\"]\nsolver_code = \"{}\"\nrequest_copies = {n}\n{}",
                code.display(),
                code_base()
            );
            let r = load_bot(&tmp("rc.toml", &s));
            assert_eq!(r.is_ok(), good, "{n}");
            if let Err(e) = r {
                assert!(e.to_string().contains("request_copies"), "{e}");
            }
        }
        // deployed mode: copies share one bundle hash on the builder
        let s = format!("endpoints = [\"http://localhost:1\"]\nrequest_copies = 2\n{BASE}");
        let e = load_bot(&tmp("rc.toml", &s)).unwrap_err().to_string();
        assert!(e.contains("solver_code"), "{e}");
    }

    #[test]
    fn test_signer_key_from_env_only() {
        let s = format!("endpoints = [\"http://localhost:1\"]\nsigner_key = \"0xdead\"\n{BASE}");
        assert!(load_bot(&tmp("key.toml", &s)).is_err());
    }

    /// `bot.example.toml` is the documented shape of `bot.toml`. `load_bot` would read
    /// `solver.hex`, so this parses the file and checks the same rules.
    #[test]
    fn test_bot_example_parses() {
        let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("bot.example.toml");
        let cfg: BotConfig = toml::from_str(&std::fs::read_to_string(p).unwrap()).unwrap();
        assert_eq!(cfg.solver, Address::ZERO);
        assert_eq!(cfg.solver_code, Some(PathBuf::from("solver.hex")));
        assert_eq!(
            (cfg.builder_share_bps, cfg.min_profit_wei, cfg.gas_margin),
            (5_000, U256::ZERO, 1.0)
        );
        assert_eq!(cfg.payout_address, None);
        assert_eq!((cfg.pending_cap, cfg.select), (64, Select::Top));
        assert_eq!((cfg.group_size, cfg.request_copies), (4, 1));
        assert_eq!((cfg.send_delay_ms, cfg.uuid_mode), (200, UuidMode::Cycle));
    }
}

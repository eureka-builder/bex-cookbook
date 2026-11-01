//! `bex-backrun status`: what happened to the sends, from the store. One row per cycle of
//! `cycles.toml`, then one per other name sent (group names). `--probe` also calls `solve` at
//! `latest` for each cycle, with no builder involved.
//!
//! The `solve` probe ([`solve_latest`]) and the revert names ([`revert_of`]) are also what
//! `simulate` uses to explain a compute revert.
use crate::abi::{BadLeg, ICycleSolver, NoProfit, TooManyCrossings};
use crate::config::BotConfig;
use crate::cycles::{Cycle, Leg};
use crate::request::{cycle_id, solve_calldata};
use crate::sender::{rpc, RpcError};
use crate::store::SqliteStore;
use crate::track::CONFIRM_DEPTH_FINAL;
use alloy::primitives::{Address, Bytes, B256, U256};
use alloy::sol_types::{SolCall, SolError};
use anyhow::Result;
use serde_json::json;
use std::collections::{BTreeSet, HashMap, HashSet};

/// Columns, in print order. `sent` counts distinct bundle hashes the builder accepted;
/// `landed_final` counts canonical `CycleExecuted` logs re-checked at depth 12,
/// `landed_provisional` those canonical at depth 2 only.
pub const COLUMNS: [&str; 3] = ["sent", "landed_final", "landed_provisional"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub cycle: String,
    /// In `COLUMNS` order.
    pub counts: [u64; 3],
}

/// The store's rows in the `status` window.
struct Window {
    /// (sent name, bundle hash) of every accepted send.
    sent: Vec<(String, String)>,
    /// (cycleId, is final, count) of canonical landings.
    landed: Vec<(String, i64, i64)>,
}

/// The sends in the last `since_blocks` blocks before the newest send, and the landings in the
/// same blocks.
async fn read_window(store: &SqliteStore, since_blocks: u64) -> Result<Window> {
    let w = store
        .with(move |c| -> rusqlite::Result<_> {
            let newest: i64 = c.query_row("SELECT COALESCE(MAX(block), 0) FROM sent", [], |r| r.get(0))?;
            let min = newest.saturating_sub(since_blocks as i64);
            let sent = c
                .prepare("SELECT DISTINCT cycle, bundle_hash FROM sent WHERE block >= ? AND bundle_hash IS NOT NULL")?
                .query_map([min], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<Result<_, _>>()?;
            let landed = c
                .prepare("SELECT cycle_id, COALESCE(confirmed_depth, 0) >= ?2, COUNT(*) FROM landing WHERE canonical = 1 AND block >= ?1 GROUP BY 1, 2")?
                .query_map((min, CONFIRM_DEPTH_FINAL as i64), |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
                .collect::<Result<_, _>>()?;
            Ok(Window { sent, landed })
        })
        .await??;
    Ok(w)
}

/// Counts per cycle over sends in the last `since_blocks` blocks (relative to the newest send).
/// Rows: the loaded cycles in file order, then every other name in `sent.cycle` (group names,
/// sorted). Sends are keyed by the sent name, landings by the executed cycle.
pub async fn status(store: &SqliteStore, cycles: &[Cycle], since_blocks: u64) -> Result<Vec<Row>> {
    let Window { sent, landed } = read_window(store, since_blocks).await?;
    let loaded: HashSet<&str> = cycles.iter().map(|c| c.name.as_str()).collect();
    let extra: BTreeSet<String> = sent
        .iter()
        .map(|(n, _)| n)
        .filter(|n| !loaded.contains(n.as_str()))
        .cloned()
        .collect();
    // distinct bundle hashes per name
    let mut seen: HashMap<String, HashSet<String>> = HashMap::new();
    for (name, hash) in sent {
        seen.entry(name).or_default().insert(hash);
    }
    // (name, is final) -> count
    let ids = landing_ids(cycles);
    let mut landed_by_name: HashMap<(&str, bool), u64> = HashMap::new();
    for (id, fin, n) in &landed {
        if let Some(name) = ids.get(id) {
            *landed_by_name.entry((name, *fin != 0)).or_default() += *n as u64;
        }
    }
    let row = |name: String| {
        let landed = |fin| {
            landed_by_name
                .get(&(name.as_str(), fin))
                .copied()
                .unwrap_or(0)
        };
        let counts = [
            seen.get(&name).map_or(0, |s| s.len() as u64),
            landed(true),
            landed(false),
        ];
        Row {
            cycle: name,
            counts,
        }
    };
    Ok(cycles
        .iter()
        .map(|c| c.name.clone())
        .chain(extra)
        .map(row)
        .collect())
}

/// `cycleId` -> cycle name, for both orientations: the solver may return the reversed legs, and the
/// executor emits the executed legs' `cycleId` (`RateFilter.reverse`: order reversed, each leg's
/// tokens swapped).
fn landing_ids(cycles: &[Cycle]) -> HashMap<String, String> {
    let mut ids = HashMap::new();
    for c in cycles {
        let rev: Vec<Leg> = c
            .legs
            .iter()
            .rev()
            .map(|l| Leg {
                token_in: l.token_out,
                token_out: l.token_in,
                ..l.clone()
            })
            .collect();
        for legs in [&c.legs, &rev] {
            ids.insert(format!("{:#x}", cycle_id(legs)), c.name.clone());
        }
    }
    ids
}

pub fn format_table(rows: &[Row]) -> String {
    let w = rows.iter().map(|r| r.cycle.len()).max().unwrap_or(5).max(5);
    let mut out = format!("{:<w$}", "cycle");
    for c in COLUMNS {
        out += &format!("  {c}");
    }
    for r in rows {
        out += &format!("\n{:<w$}", r.cycle);
        for (n, c) in r.counts.iter().zip(COLUMNS) {
            out += &format!("  {n:>width$}", width = c.len());
        }
    }
    out
}

/// Selectors of the contracts' custom errors (Types.sol) that the bot names.
const ERRORS: [([u8; 4], &str); 3] = [
    (NoProfit::SELECTOR, "NoProfit"),
    (TooManyCrossings::SELECTOR, "TooManyCrossings"),
    (BadLeg::SELECTOR, "BadLeg"),
];

/// The result of one `solve` probe at `latest`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Solve {
    /// `amountOut - amountIn`, wei.
    Profit(U256),
    Revert {
        name: Option<&'static str>,
        selector: String,
    },
    Error(String),
}

impl Solve {
    /// The legs are sound and the cycle only lacks profit. A profit here (minProfit 0)
    /// after a builder compute revert means the floor, or a newer state, made it revert.
    pub fn no_profit(&self) -> bool {
        matches!(
            self,
            Solve::Profit(_)
                | Solve::Revert {
                    name: Some("NoProfit"),
                    ..
                }
        )
    }
}

impl std::fmt::Display for Solve {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Solve::Profit(p) => write!(f, "profit {p}"),
            Solve::Revert {
                name: Some(n),
                selector,
            } => write!(f, "revert {n} ({selector})"),
            Solve::Revert {
                name: None,
                selector,
            } => write!(f, "revert {selector}"),
            Solve::Error(e) => f.write_str(e),
        }
    }
}

/// `eth_call` params `[call, "latest"]` to the solver; in code mode with a third,
/// state-override param that installs `solver_code` (reth and geth take it).
pub fn solver_call(cfg: &BotConfig, data: &Bytes) -> serde_json::Value {
    let to = crate::request::solver_for_calls(cfg);
    let call = json!({"to": to, "data": data});
    match &cfg.solver_code_bytes {
        Some(code) => json!([call, "latest", {format!("{to:#x}"): {"code": code}}]),
        None => json!([call, "latest"]),
    }
}

/// A revert from its data (`0x` + selector + args): named when it is a bex-backrun error.
pub fn revert_of(data: &str) -> Option<Solve> {
    // `get`, not `[..10]`: the text comes from a node or builder and can be any UTF-8.
    let selector = data.get(..10)?.to_ascii_lowercase();
    let name = ERRORS
        .iter()
        .find(|(s, _)| alloy::hex::encode_prefixed(s) == selector)
        .map(|(_, n)| *n);
    Some(Solve::Revert { name, selector })
}

/// `eth_call solve(legs, 0, 0, share, 0, 0)` on `rpc_http` at `latest` (a probe: no recipient, no tag).
pub async fn solve_latest(client: &reqwest::Client, cfg: &BotConfig, c: &Cycle) -> Solve {
    let data = solve_calldata(
        &c.legs,
        U256::ZERO,
        U256::ZERO,
        cfg.builder_share_bps,
        Address::ZERO,
        B256::ZERO,
    );
    match rpc(client, &cfg.rpc_http, "eth_call", solver_call(cfg, &data)).await {
        Ok(v) => match v
            .as_str()
            .and_then(|s| s.parse::<Bytes>().ok())
            .and_then(|b| ICycleSolver::solveCall::abi_decode_returns(&b).ok())
        {
            Some(p) => Solve::Profit(p.amountOut.saturating_sub(p.amountIn)),
            None => Solve::Error(format!("undecodable result {v}")),
        },
        Err(e) => e
            .downcast_ref::<RpcError>()
            .and_then(|r| r.data.as_deref())
            .and_then(revert_of)
            .unwrap_or_else(|| Solve::Error(format!("{e:#}"))),
    }
}

/// `--probe`: `solve_latest` per cycle, as a printable line.
pub async fn probe(cfg: &BotConfig, cycles: &[Cycle]) -> Vec<(String, String)> {
    let client = reqwest::Client::new();
    let mut out = vec![];
    for c in cycles {
        out.push((
            c.name.clone(),
            solve_latest(&client, cfg, c).await.to_string(),
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_revert_of_short_or_multibyte_is_none() {
        assert!(super::revert_of("0x1234").is_none());
        assert!(super::revert_of("0x1234567é").is_none());
    }

    #[test]
    fn test_reversed_cycle_id_resolves_to_the_cycle() {
        use super::*;
        use alloy::primitives::Address;
        let (a, b, e) = (
            Address::repeat_byte(0xaa),
            Address::repeat_byte(0xbb),
            Address::repeat_byte(0xee),
        );
        let leg = |i, o, fee| Leg {
            version: 3,
            token_in: i,
            token_out: o,
            fee,
            tick_spacing: 10,
        };
        let c = Cycle {
            name: "tri".into(),
            legs: vec![leg(e, a, 100), leg(a, b, 500), leg(b, e, 3000)],
        };
        let rev = [leg(e, b, 3000), leg(b, a, 500), leg(a, e, 100)];
        let ids = landing_ids(std::slice::from_ref(&c));
        assert_eq!(ids.len(), 2);
        assert_eq!(ids[&format!("{:#x}", cycle_id(&c.legs))], "tri");
        assert_eq!(ids[&format!("{:#x}", cycle_id(&rev))], "tri");
    }
}

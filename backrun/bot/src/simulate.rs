//! `bex-backrun simulate`: one `bex_simulate` per cycle against one endpoint, to find broken
//! cycles before `run`.
//!
//! Each cycle goes alone (no groups), with the same request `run` would send for it (`request.rs`).
//! A row per cycle prints as it comes back. The verdict counts `accepted`, `no-profit` (the cycle is
//! sound but has no profit now) and `failed` (the cycle or the setup is broken). The builder
//! reports every compute revert as the same issue, `Compute reverted`. `simulate` then tells
//! `NoProfit` from a broken cycle with the builder's `revertData`, or else with `solve` at
//! `latest` on the node (`status.rs`).
//!
//! `--override-code` evaluates without a deploy: no `compute.code`, and a `stateOverrides` field
//! installs `solver_code` (and `executor_code`) instead. `--repeat-blocks N --every K` repeats
//! the run on later heads, and `--out` appends every row to a CSV.
use crate::abi::ICycleSolver;
use crate::config::BotConfig;
use crate::cycles::Cycle;
use crate::floor::{next_base_fee, wei_per_gas};
use crate::head::Head;
use crate::request::{build_request, BexRequest};
use crate::sender::{
    call, envelope, not_admitted, not_admitted_error, redact, BuilderError, BUSY, ENDPOINT_TIMEOUT,
};
use crate::status::{revert_of, solve_latest, Solve};
use alloy::eips::BlockNumberOrTag;
use alloy::primitives::{Address, Bytes, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol_types::SolCall;
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::time::Duration;
use url::Url;

/// The builder drops the revert bytes from its issues: `NoProfit` and a broken cycle
/// (`BadLeg`) both arrive as this single issue, so `simulate` asks which one it is.
const COMPUTE_REVERTED: &str = "Compute reverted";

/// The `-32602` refusal of a builder that does not accept `compute.code`.
const CODE_DISABLED: &str = "compute.code is not enabled";

/// At most this many `bex_simulate` calls per second to the builder (retries included).
pub const MAX_SIMULATES_PER_SEC: u64 = 5;

/// `-32005` busy: retried after 100 ms, doubling (100, 200, 400, 800 ms), 5 tries in all.
const BUSY_TRIES: u32 = 5;
const BUSY_FIRST_WAIT: Duration = Duration::from_millis(100);

#[derive(Debug, Default, PartialEq, Eq)]
pub struct Verdict {
    pub accepted: usize,
    /// Rejected with the single issue "Compute reverted", and the revert is `NoProfit`
    /// (from the builder's `revertData`, else from `solve` at latest, which can also return
    /// a profit under the floor).
    pub no_profit: usize,
    pub failed: usize,
    pub rows: Vec<Row>,
}

impl Verdict {
    /// Process exit code 0 when nothing failed.
    pub fn ok(&self) -> bool {
        self.failed == 0
    }
}

/// One cycle's `bex_simulate`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub cycle: String,
    pub status: &'static str,
    pub amount_in: Option<U256>,
    pub amount_out: Option<U256>,
    /// `compute.gasUsed` and `execute.gasUsed`, when the builder returned them.
    pub compute_gas: Option<u64>,
    pub execute_gas: Option<u64>,
    /// `execute.coinbaseProfitWei` as the builder wrote it.
    pub coinbase_profit: Option<String>,
    /// The `targetBlock` the request carried (the head when it was sent, + 1).
    pub target_block: u64,
    /// `snapshotBlock`: the parent block the builder simulated on (it simulated the next
    /// block). A paced run spans several blocks, so this, not the start head, dates the row.
    pub snapshot_block: Option<u64>,
    /// The plan's `minProfit`: the floor the solver applied (`max(minProfitWei, weiPerGas *
    /// gas(plan), 1)`). `None` when the compute returned no plan.
    pub floor_wei: Option<U256>,
    /// `-32005` busy answers retried before this result.
    pub retries: u32,
    /// `compute.revertData`, else `execute.revertData`, of a failed simulate (builders with
    /// the simulate diagnostics only).
    pub revert_data: Option<String>,
    pub issues: String,
}

/// Timing of a `simulate` batch.
#[derive(Debug, Clone)]
pub struct Pacing {
    /// Least time between two builder calls (retries included).
    pub min_gap: Duration,
    /// A batch re-reads the head this often, so a long batch targets the current block.
    pub head_refresh: Duration,
}

impl Default for Pacing {
    /// `MAX_SIMULATES_PER_SEC`, and a head read every 6 s (half a slot): one cheap RPC
    /// per 30 builder calls.
    fn default() -> Self {
        Pacing {
            min_gap: Duration::from_millis(1000 / MAX_SIMULATES_PER_SEC),
            head_refresh: Duration::from_secs(6),
        }
    }
}

/// [`simulate_paced`] with the default pacing.
pub async fn simulate(
    cfg: &BotConfig,
    cycles: &[Cycle],
    endpoint: &Url,
    signer: &PrivateKeySigner,
    head: &Head,
    override_code: bool,
) -> Result<Verdict> {
    let pacing = Pacing::default();
    simulate_paced(cfg, cycles, endpoint, signer, head, override_code, &pacing).await
}

/// One `bex_simulate` per cycle, in file order, one call at a time: the builder runs one
/// `bex_simulate` per signer at a time. A paced batch outlives its head (the 688 mainnet cycles
/// take about 2.3 minutes), so the head is re-read every `head_refresh`. Later requests then target the new
/// head + 1 and use its basefee for the floor. Each row records the target it used.
pub async fn simulate_paced(
    cfg: &BotConfig,
    cycles: &[Cycle],
    endpoint: &Url,
    signer: &PrivateKeySigner,
    head: &Head,
    override_code: bool,
    pacing: &Pacing,
) -> Result<Verdict> {
    if override_code && cfg.solver_code_bytes.is_none() {
        bail!("--override-code needs solver_code in the config");
    }
    let client = reqwest::Client::new();
    let mut head = head.clone();
    let mut head_read = tokio::time::Instant::now();
    let mut pace = tokio::time::interval(pacing.min_gap);
    pace.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut v = Verdict::default();
    for c in cycles {
        if head_read.elapsed() >= pacing.head_refresh {
            head_read = tokio::time::Instant::now();
            refresh_head(cfg, &mut head).await;
        }
        let target_block = head.number + 1;
        let req = simulate_request(cfg, c, &head, signer.address(), override_code);
        let body = envelope("bex_simulate", &req);
        let (res, retries) = simulate_call(&client, signer, endpoint, body, &mut pace).await;
        let r = match res {
            Ok(r) => r,
            Err(e) => match not_admitted(&e) {
                Some(said) => return Err(not_admitted_error(signer.address(), endpoint, &said)),
                None => rejection_of(&e),
            },
        };
        let (status, issues, amounts) = classify(&r);
        let (count, issues) = judge(&client, cfg, c, &r, status, issues).await;
        match count {
            Count::Accepted => v.accepted += 1,
            Count::NoProfit => v.no_profit += 1,
            Count::Failed => v.failed += 1,
        }
        let snapshot_block = r["snapshotBlock"].as_u64();
        let row = Row {
            cycle: c.name.clone(),
            status,
            amount_in: amounts.map(|a| a.0),
            amount_out: amounts.map(|a| a.1),
            compute_gas: r["compute"]["gasUsed"].as_u64(),
            execute_gas: r["execute"]["gasUsed"].as_u64(),
            coinbase_profit: r["execute"]["coinbaseProfitWei"]
                .as_str()
                .map(str::to_owned),
            target_block,
            snapshot_block,
            floor_wei: amounts.map(|a| a.2),
            retries,
            revert_data: ["compute", "execute"]
                .iter()
                .find_map(|k| r[k]["revertData"].as_str())
                .map(str::to_owned),
            issues,
        };
        println!("{}", format_row(&row));
        v.rows.push(row);
    }
    Ok(v)
}

/// Where a row counts in the [`Verdict`].
enum Count {
    Accepted,
    NoProfit,
    Failed,
}

/// Accepted, no profit or failed. A compute revert is no profit only if it is `NoProfit` (or a
/// profit under the floor); the explanation is added to the issues.
async fn judge(
    client: &reqwest::Client,
    cfg: &BotConfig,
    c: &Cycle,
    r: &Value,
    status: &str,
    issues: String,
) -> (Count, String) {
    if status == "accepted" {
        return (Count::Accepted, issues);
    }
    if issues != COMPUTE_REVERTED {
        return (Count::Failed, issues);
    }
    let (probe, at) = explain_compute_revert(client, cfg, c, r).await;
    let count = if probe.no_profit() {
        Count::NoProfit
    } else {
        Count::Failed
    };
    (count, format!("{issues}; {at}: {probe}"))
}

/// The request `run` would send for this cycle alone at `head`. With `override_code`, the
/// solver code moves from `compute.code` into `stateOverrides`, with `executor_code` next to it.
fn simulate_request(
    cfg: &BotConfig,
    c: &Cycle,
    head: &Head,
    signer: Address,
    override_code: bool,
) -> BexRequest {
    let wpg = wei_per_gas(cfg, next_base_fee(head));
    let mut req = build_request(cfg, c, head.number + 1, wpg, signer);
    if override_code {
        let code = req.bex.compute.code.take();
        let mut o = serde_json::Map::new();
        o.insert(format!("{:#x}", req.bex.compute.to), json!({"code": code}));
        if let Some(e) = &cfg.executor_code_bytes {
            o.insert(format!("{:#x}", cfg.executor), json!({"code": e}));
        }
        req.state_overrides = Some(Value::Object(o));
    }
    req
}

/// One `bex_simulate`, retried while the builder answers busy. Returns the retry count too.
async fn simulate_call(
    client: &reqwest::Client,
    signer: &PrivateKeySigner,
    endpoint: &Url,
    body: Vec<u8>,
    pace: &mut tokio::time::Interval,
) -> (Result<Value>, u32) {
    let (mut retries, mut wait) = (0, BUSY_FIRST_WAIT);
    loop {
        pace.tick().await;
        let r = call(client, signer, endpoint, body.clone(), ENDPOINT_TIMEOUT).await;
        let busy = matches!(&r, Err(e) if e.downcast_ref::<BuilderError>().is_some_and(|b| b.code == BUSY));
        if !busy || retries + 1 >= BUSY_TRIES {
            return (r, retries);
        }
        tokio::time::sleep(wait).await;
        wait *= 2;
        retries += 1;
    }
}

/// A failed call as a rejected simulate result, so it prints as a row.
fn rejection_of(e: &anyhow::Error) -> Value {
    let e = format!("{e:#}");
    let issue = if e.contains(CODE_DISABLED) {
        format!("builder refuses compute.code ({e}): use a deployed solver, or --override-code")
    } else {
        e
    };
    json!({"accepted": false, "issues": [issue]})
}

/// Why the compute reverted: from the builder's `compute.revertData` when it sent it, else
/// from `solve` at `latest` on the node. Returns the answer and where it came from.
async fn explain_compute_revert(
    client: &reqwest::Client,
    cfg: &BotConfig,
    c: &Cycle,
    r: &Value,
) -> (Solve, &'static str) {
    match r["compute"]["revertData"].as_str() {
        Some(d) => (
            revert_of(d).unwrap_or_else(|| Solve::Error(format!("revert data {d}"))),
            "builder",
        ),
        None => (solve_latest(client, cfg, c).await, "solve at latest"),
    }
}

/// Moves `head` to the latest block if the node has a newer one.
async fn refresh_head(cfg: &BotConfig, head: &mut Head) {
    match read_head(cfg, BlockNumberOrTag::Latest).await {
        Some(h) if h.number > head.number => *head = h,
        Some(_) => {}
        None => tracing::warn!(
            head = head.number,
            "head refresh failed; keeping the old head"
        ),
    }
}

/// The header of block `tag` from `rpc_http`; `None` on failure.
async fn read_head(cfg: &BotConfig, tag: BlockNumberOrTag) -> Option<Head> {
    let p = ProviderBuilder::new().connect_http(cfg.rpc_http.clone());
    match p.get_block_by_number(tag).await {
        Ok(b) => b.map(|b| Head::from_rpc(&b.header)),
        Err(e) => {
            tracing::warn!(block = %tag, error = %redact(&e, &cfg.rpc_http), "block header");
            None
        }
    }
}

/// `name  status  in out profit  issues`, `-` for an unknown amount.
pub fn format_row(r: &Row) -> String {
    let opt = |x: Option<U256>| x.map_or("-".to_string(), |x| x.to_string());
    let profit = r
        .amount_in
        .zip(r.amount_out)
        .map(|(i, o)| o.saturating_sub(i));
    let mut line = format!(
        "{}  {}  {} {} {}  {}",
        r.cycle,
        r.status,
        opt(r.amount_in),
        opt(r.amount_out),
        opt(profit),
        r.issues
    );
    if r.compute_gas.is_some() || r.execute_gas.is_some() {
        let g = |x: Option<u64>| x.map_or("-".to_string(), |x| x.to_string());
        line.push_str(&format!("  gas {}/{}", g(r.compute_gas), g(r.execute_gas)));
    }
    if let Some(p) = &r.coinbase_profit {
        line.push_str(&format!("  coinbase +{p}"));
    }
    if let Some(d) = &r.revert_data {
        let named = revert_of(d).map_or(d.clone(), |s| s.to_string());
        line.push_str(&format!("  [{named}]"));
    }
    if r.retries > 0 {
        line.push_str(&format!("  [busy retries {}]", r.retries));
    }
    line
}

/// The status, the issues joined, and the plan's (amountIn, amountOut, minProfit) of a simulate result.
fn classify(r: &Value) -> (&'static str, String, Option<(U256, U256, U256)>) {
    let status = if r["accepted"].as_bool() == Some(true) {
        "accepted"
    } else {
        "rejected"
    };
    let issues = r["issues"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("; ")
        })
        .unwrap_or_default();
    let amounts = r["compute"]["returnData"]
        .as_str()
        .and_then(|s| s.parse::<Bytes>().ok())
        .and_then(|b| ICycleSolver::solveCall::abi_decode_returns(&b).ok())
        .map(|p| (p.amountIn, p.amountOut, p.minProfit));
    (status, issues, amounts)
}

/// `simulate --repeat-blocks N --every K`.
#[derive(Debug, Clone)]
pub struct Repeat {
    pub override_code: bool,
    /// Runs in all (N).
    pub runs: u32,
    /// New heads between two runs (K).
    pub every: u64,
    /// CSV the rows are appended to.
    pub out: Option<std::path::PathBuf>,
}

pub const CSV_HEADER: &str = "head,target_block,snapshot_block,cycle,status,amount_in,amount_out,\
profit,floor_wei,compute_gas,execute_gas,coinbase_profit_wei,\
busy_retries,revert_data,issues";

/// Runs `simulate` on the first head, then on every `every`-th new head, `runs` times in all.
/// Appends each run's rows to `out`. Returns the summed verdict (rows not kept).
pub async fn repeat(
    cfg: &BotConfig,
    cycles: &[Cycle],
    endpoint: &Url,
    signer: &PrivateKeySigner,
    heads: impl futures::Stream<Item = Head>,
    opts: &Repeat,
) -> Result<Verdict> {
    use futures::StreamExt;
    let mut heads = std::pin::pin!(crate::head::monotonic(heads));
    let mut total = Verdict::default();
    let mut next = 0u64;
    let mut done = 0;
    while done < opts.runs {
        let h = heads.next().await.context("head stream ended")?;
        if h.number < next {
            continue;
        }
        next = h.number + opts.every.max(1);
        let v = simulate(cfg, cycles, endpoint, signer, &h, opts.override_code).await?;
        println!(
            "head {}: accepted {}  no-profit {}  failed {}",
            h.number, v.accepted, v.no_profit, v.failed
        );
        if let Some(out) = &opts.out {
            append_csv(out, &h, &v.rows)?;
        }
        total.accepted += v.accepted;
        total.no_profit += v.no_profit;
        total.failed += v.failed;
        done += 1;
    }
    Ok(total)
}

/// Appends rows, writing `CSV_HEADER` first to a new or empty file.
pub fn append_csv(path: &std::path::Path, head: &Head, rows: &[Row]) -> Result<()> {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("opening {}", path.display()))?;
    let mut out = String::new();
    if f.metadata()?.len() == 0 {
        out.push_str(CSV_HEADER);
        out.push('\n');
    }
    for r in rows {
        let line: Vec<String> = csv_fields(head, r).iter().map(|s| csv_field(s)).collect();
        out.push_str(&line.join(","));
        out.push('\n');
    }
    f.write_all(out.as_bytes())
        .with_context(|| format!("writing {}", path.display()))
}

/// One row's fields in `CSV_HEADER` order; an unknown value is empty.
fn csv_fields(head: &Head, r: &Row) -> [String; 15] {
    let opt = |x: Option<String>| x.unwrap_or_default();
    let profit = r
        .amount_in
        .zip(r.amount_out)
        .map(|(i, o)| o.saturating_sub(i));
    [
        head.number.to_string(),
        r.target_block.to_string(),
        opt(r.snapshot_block.map(|x| x.to_string())),
        r.cycle.clone(),
        r.status.to_string(),
        opt(r.amount_in.map(|x| x.to_string())),
        opt(r.amount_out.map(|x| x.to_string())),
        opt(profit.map(|x| x.to_string())),
        opt(r.floor_wei.map(|x| x.to_string())),
        opt(r.compute_gas.map(|x| x.to_string())),
        opt(r.execute_gas.map(|x| x.to_string())),
        opt(r.coinbase_profit.clone()),
        r.retries.to_string(),
        opt(r.revert_data.clone()),
        r.issues.clone(),
    ]
}

fn csv_field(s: &str) -> String {
    if s.contains([',', '"', '\n', '\r']) {
        format!("\"{}\"", s.replace('"', "\"\""))
    } else {
        s.to_string()
    }
}

//! The checks `run` and `simulate` make before the first request. Each one stops the bot with
//! an error that says what to fix:
//!
//! 1. Code mode: every endpoint must accept `compute.code` of this size ([`check_compute_code`]).
//! 2. The solver and the executor must use the same venues, and their WETH must be `weth` in
//!    `bot.toml` ([`check_venues`]).
use crate::abi::{ICycleExecutor, Venues};
use crate::config::BotConfig;
use crate::request::solver_for_calls;
use crate::sender::{call, host_port, retryable, rpc, ENDPOINT_TIMEOUT};
use crate::status::solver_call;
use alloy::primitives::{Address, Bytes};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol_types::SolCall;
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use url::Url;

/// All startup checks. `override_code` (`simulate --override-code`) sends no `compute.code`:
/// it skips the capability check, and `executor_code` joins the overrides of the venue check.
pub async fn check(
    cfg: &BotConfig,
    signer: &PrivateKeySigner,
    endpoints: &[Url],
    override_code: bool,
) -> Result<()> {
    if override_code {
        anyhow::ensure!(
            cfg.solver_code_bytes.is_some(),
            "--override-code needs solver_code in the config"
        );
        return check_venues(cfg, cfg.executor_code_bytes.as_ref()).await;
    }
    check_compute_code(cfg, signer, endpoints).await?;
    check_venues(cfg, None).await
}

/// Code mode: fails unless every endpoint's `bex_capabilities` reports
/// `computeCodeEnabled: true` and a `maxComputeCodeBytes` that fits `solver_code`. A builder
/// without the compute-code feature has no such field and ignores `compute.code`: it would run
/// the empty target, and every request would fail with no error to the sender.
pub async fn check_compute_code(
    cfg: &BotConfig,
    signer: &PrivateKeySigner,
    endpoints: &[Url],
) -> Result<()> {
    let Some(code) = &cfg.solver_code_bytes else {
        return Ok(());
    };
    let client = reqwest::Client::new();
    let body = serde_json::to_vec(
        &json!({"jsonrpc":"2.0","id":1,"method":"bex_capabilities","params":[]}),
    )?;
    for url in endpoints {
        let host = host_port(url);
        let caps = capabilities(&client, signer, url, &body)
            .await
            .with_context(|| format!("{host}: bex_capabilities"))?;
        let enabled = &caps["computeCodeEnabled"];
        if enabled != &Value::Bool(true) {
            let got = if enabled.is_null() {
                "absent".to_string()
            } else {
                enabled.to_string()
            };
            bail!(
                "builder {host} does not accept compute.code (bex_capabilities: computeCodeEnabled \
                 {got}); use a deployed solver, or `simulate --override-code`"
            );
        }
        match caps["maxComputeCodeBytes"].as_u64() {
            Some(max) if code.len() as u64 <= max => {}
            max => bail!(
                "builder {host} takes compute.code up to {} bytes (bex_capabilities: \
                 maxComputeCodeBytes); solver_code is {} bytes",
                max.map_or("?".to_string(), |m| m.to_string()),
                code.len()
            ),
        }
    }
    Ok(())
}

/// `bex_capabilities`, sent again once after a timeout or a transport error: the first call to
/// an endpoint opens its TLS connection, which can take longer than the timeout.
async fn capabilities(
    client: &reqwest::Client,
    signer: &PrivateKeySigner,
    url: &Url,
    body: &[u8],
) -> Result<Value> {
    match call(client, signer, url, body.to_vec(), ENDPOINT_TIMEOUT).await {
        Err(e) if retryable(&e) => call(client, signer, url, body.to_vec(), ENDPOINT_TIMEOUT).await,
        r => r,
    }
}

/// Fails unless the solver's and the executor's `venues()` are equal field by field
/// (factories, init hashes, PoolManager, WETH) and their `weth` equals `cfg.weth`.
/// A mismatch makes the solver quote pools the executor does not use, or every leg `BadLeg`.
/// In code mode the solver's `venues()` runs on `solver_code` through a state override.
/// `executor_code` (when given) is installed at `executor` the same way, so
/// `simulate --override-code` needs no deployed executor.
pub async fn check_venues(cfg: &BotConfig, executor_code: Option<&Bytes>) -> Result<()> {
    let client = reqwest::Client::new();
    let data = Bytes::from(ICycleExecutor::venuesCall {}.abi_encode());
    let executor_params = match executor_code {
        Some(code) => json!([{"to": cfg.executor, "data": data}, "latest",
            {format!("{:#x}", cfg.executor): {"code": code}}]),
        None => json!([{"to": cfg.executor, "data": data}, "latest"]),
    };
    let solver = venues_of(
        &client,
        cfg,
        "solver",
        solver_for_calls(cfg),
        solver_call(cfg, &data),
    )
    .await?;
    let executor = venues_of(&client, cfg, "executor", cfg.executor, executor_params).await?;
    let (s, e) = (venue_fields(&solver), venue_fields(&executor));
    if let Some(((f, a), (_, b))) = s.iter().zip(&e).find(|((_, a), (_, b))| a != b) {
        bail!("solver and executor differ in venues().{f}: solver {a}, executor {b}");
    }
    Ok(())
}

/// `venues()` of one contract (`eth_call` with `params`), checked against `cfg.weth`.
async fn venues_of(
    client: &reqwest::Client,
    cfg: &BotConfig,
    name: &str,
    addr: Address,
    params: Value,
) -> Result<Venues> {
    let v = rpc(client, &cfg.rpc_http, "eth_call", params)
        .await
        .with_context(|| format!("{name} {addr}: venues()"))?;
    if v.as_str() == Some("0x") {
        bail!("{name} {addr}: no contract at this address (venues() returned no data); is it deployed? See contracts/README.md");
    }
    let venues = v
        .as_str()
        .and_then(|s| s.parse::<Bytes>().ok())
        .and_then(|b| ICycleExecutor::venuesCall::abi_decode_returns(&b).ok())
        .with_context(|| {
            format!("{name} {addr}: venues() undecodable; is it a bex-backrun contract?")
        })?;
    if venues.weth != cfg.weth {
        bail!(
            "{name} {addr} uses WETH {}, but bot.toml weth is {}",
            venues.weth,
            cfg.weth
        );
    }
    Ok(venues)
}

/// The six `venues()` fields by name, in declaration order.
fn venue_fields(v: &Venues) -> [(&'static str, String); 6] {
    [
        ("v2Factory", v.v2Factory.to_string()),
        ("v2InitHash", v.v2InitHash.to_string()),
        ("v3Factory", v.v3Factory.to_string()),
        ("v3InitHash", v.v3InitHash.to_string()),
        ("poolManager", v.poolManager.to_string()),
        ("weth", v.weth.to_string()),
    ]
}

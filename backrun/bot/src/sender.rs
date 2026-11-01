//! JSON-RPC transport. Every call the bot makes goes through this file:
//!
//! - [`call`] and [`send_bundle`]: signed POSTs to a builder endpoint (`X-Flashbots-Signature`).
//!   `run` sends `bex_sendBundle`, `simulate` sends `bex_simulate`, the startup checks send
//!   `bex_capabilities`.
//! - [`rpc`]: plain POSTs to the Ethereum node (`eth_call`, `eth_getLogs`, ...).
//!
//! An endpoint or RPC URL can hold a key, so no error or log line from here holds a full URL:
//! [`host_port`] and [`redact`] replace it with `host:port`.
use crate::config::BotConfig;
use crate::request::{flashbots_signature, BexRequest};
use alloy::primitives::Address;
use alloy::signers::local::PrivateKeySigner;
use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};
use std::{str::FromStr, time::Duration};
use url::Url;

/// Timeout of the builder calls with no setting of their own (`bex_capabilities`, `bex_simulate`).
pub const ENDPOINT_TIMEOUT: Duration = Duration::from_millis(3_000);
/// Timeout of one plain [`rpc`] call.
const RPC_TIMEOUT: Duration = Duration::from_secs(5);

/// The builder's code for a call over a resource limit. `bex_simulate` answers it when its
/// per-signer (1) or per-host (4) bound is full: "bex_simulate is busy, retry".
pub const BUSY: i64 = -32005;

/// Reads the signer key (hex, `0x` optional) from the env var named in the config.
/// Called once at startup. The key never appears in an error or a log.
pub fn signer_from_env(cfg: &BotConfig) -> Result<PrivateKeySigner> {
    let var = &cfg.signer_key_env;
    let raw = std::env::var(var).map_err(|_| {
        anyhow!("env var {var} is not set: export the signer's private key (hex) in it")
    })?;
    PrivateKeySigner::from_str(raw.trim()).map_err(|_| {
        anyhow!("env var {var} is not a valid private key: it must be 32 bytes of hex")
    })
}

/// `host:port` of a URL. The rest of the URL (path, query, user info) can hold a key.
pub fn host_port(u: &Url) -> String {
    format!(
        "{}:{}",
        u.host_str().unwrap_or("?"),
        u.port_or_known_default().unwrap_or(0)
    )
}

/// `msg` with `url` replaced by its `host:port`. An alloy or reqwest error's Display
/// appends ` for url (<full URL>)`, and the URL can hold a key.
pub fn redact(msg: impl std::fmt::Display, url: &Url) -> String {
    msg.to_string().replace(url.as_str(), &host_port(url))
}

/// The exact bytes that get POSTed (and signed).
pub fn envelope(method: &str, req: &BexRequest) -> Vec<u8> {
    serde_json::to_vec(&json!({"jsonrpc":"2.0","id":1,"method":method,"params":[req]}))
        .expect("a BexRequest serializes")
}

/// No answer in time.
#[derive(Debug)]
pub struct Timeout(pub Duration);

impl std::fmt::Display for Timeout {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "timeout after {} ms", self.0.as_millis())
    }
}

impl std::error::Error for Timeout {}

/// A timeout or a transport error: the request may never have reached the builder. A
/// JSON-RPC error or a non-JSON answer is the builder's reply, so it is not retryable.
pub fn retryable(e: &anyhow::Error) -> bool {
    e.downcast_ref::<Timeout>().is_some() || e.downcast_ref::<reqwest::Error>().is_some()
}

/// A JSON-RPC `error` from a builder endpoint.
#[derive(Debug)]
pub struct BuilderError {
    pub code: i64,
    /// The whole error object.
    pub raw: Value,
}

impl std::fmt::Display for BuilderError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "rpc error: {}", self.raw)
    }
}

impl std::error::Error for BuilderError {}

/// `-32001 ... access rejected`: the builder does not admit this signer for BEX. Returns the
/// builder's message, which says whom to contact.
pub fn not_admitted(e: &anyhow::Error) -> Option<String> {
    let b = e.downcast_ref::<BuilderError>()?;
    let msg = b.raw["message"].as_str()?;
    (b.code == -32001 && msg.contains("access rejected")).then(|| msg.to_string())
}

/// The error `run` and `simulate` stop with when the builder does not admit the signer.
/// `builder_said` is the builder's own refusal, kept because it names the contact.
pub fn not_admitted_error(signer: Address, url: &Url, builder_said: &str) -> anyhow::Error {
    anyhow!(
        "signer {signer} is not admitted for BEX on {}: ask the builder operator to admit this \
         signer for BEX and to tell you its pending limit, then set pending_cap to that limit. \
         The builder said: {builder_said}",
        url.host_str().unwrap_or("?")
    )
}

/// POSTs `body`, signed by `signer`, and returns the JSON-RPC `result`. An RPC `error` is a
/// [`BuilderError`], no answer in time is a [`Timeout`].
pub async fn call(
    client: &reqwest::Client,
    signer: &PrivateKeySigner,
    url: &Url,
    body: Vec<u8>,
    timeout: Duration,
) -> Result<Value> {
    let sig = flashbots_signature(signer, &body);
    let post = client
        .post(url.clone())
        .header("content-type", "application/json")
        .header("X-Flashbots-Signature", sig)
        .body(body)
        .send();
    let (status, bytes) = tokio::time::timeout(timeout, async {
        let r = post.await?;
        let status = r.status();
        Ok::<_, reqwest::Error>((status, r.bytes().await?))
    })
    .await
    .map_err(|_| Timeout(timeout))?
    // reqwest's Display names the full URL, which can hold a key
    .map_err(|e| anyhow::Error::new(e.without_url()).context("transport"))?;
    let v: Value =
        serde_json::from_slice(&bytes).with_context(|| format!("HTTP {status}: non-JSON body"))?;
    if let Some(e) = v.get("error") {
        return Err(BuilderError {
            code: e["code"].as_i64().unwrap_or(0),
            raw: e.clone(),
        }
        .into());
    }
    v.get("result")
        .cloned()
        .ok_or_else(|| anyhow!("HTTP {status}: no result"))
}

/// `bex_sendBundle`: the bundle hash of the request the builder took.
pub async fn send_bundle(
    client: &reqwest::Client,
    signer: &PrivateKeySigner,
    url: &Url,
    body: Vec<u8>,
    timeout: Duration,
) -> Result<String> {
    let r = call(client, signer, url, body, timeout).await?;
    r["bundleHash"]
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("no bundleHash in {r}"))
}

/// A JSON-RPC `error` from [`rpc`], kept whole so a caller can read `data` (revert bytes).
#[derive(Debug)]
pub struct RpcError {
    pub message: String,
    pub data: Option<String>,
}

impl std::fmt::Display for RpcError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "rpc error: {}", self.message)
    }
}

impl std::error::Error for RpcError {}

/// A plain (unsigned) JSON-RPC call to the Ethereum node: no signature. Errors name the
/// method, never the URL.
pub async fn rpc(
    client: &reqwest::Client,
    url: &Url,
    method: &str,
    params: Value,
) -> Result<Value> {
    let body = json!({"jsonrpc":"2.0","id":1,"method":method,"params":params});
    let resp = client
        .post(url.clone())
        .timeout(RPC_TIMEOUT)
        .json(&body)
        .send()
        .await
        .map_err(|e| anyhow::Error::new(e.without_url()).context(format!("{method}: transport")))?;
    let v: Value = resp.json().await.map_err(|e| {
        anyhow::Error::new(e.without_url()).context(format!("{method}: bad response"))
    })?;
    if let Some(e) = v.get("error") {
        return Err(RpcError {
            message: e["message"].as_str().unwrap_or("?").to_string(),
            data: e["data"].as_str().map(str::to_owned),
        }
        .into());
    }
    v.get("result")
        .cloned()
        .ok_or_else(|| anyhow!("{method}: no result"))
}

//! The send loop of `bex-backrun run`.
//!
//! At startup [`select_groups`] fixes the requests: the cycles of `cycles.toml` in groups
//! (`groups.rs`), the first `pending_budget() / request_copies` of them, `request_copies` times each. Then, for each new head N:
//!
//! 1. every group gets a `bex_sendBundle` body for target block N+1, with the `weiPerGas`
//!    at the basefee of N+1 (`floor.rs`, `request.rs`);
//! 2. after `send_delay_ms`, every body goes to every endpoint (`sender.rs`), at most
//!    [`POSTS_PER_ENDPOINT`] at a time per endpoint, with one retry of a timeout or transport error;
//! 3. each send ends with one [`Record`] in the store (`store.rs`).
//!
//! A newer head stops the sends of older batches that did not start yet (`superseded`). The
//! first answer that says the builder does not admit the signer stops the run.
use crate::config::{BotConfig, Select};
use crate::cycles::Cycle;
use crate::floor::{next_base_fee, wei_per_gas};
use crate::groups::{group_cycles, Group};
use crate::head::Head;
use crate::request::build_group_request;
use crate::sender::{envelope, not_admitted, not_admitted_error, retryable, send_bundle};
use crate::store::{now, Record, Store};
use alloy::primitives::Address;
use alloy::signers::local::PrivateKeySigner;
use anyhow::{bail, Result};
use futures::{future::join_all, Stream, StreamExt};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    Arc,
};
use std::time::Duration;
use tokio::sync::{watch, Semaphore};
use url::Url;

/// Most POSTs in flight per endpoint, across batches.
pub const POSTS_PER_ENDPOINT: usize = 16;
/// Wait before the one retry of a send that timed out or hit a transport error.
pub const RETRY_DELAY: Duration = Duration::from_millis(200);
/// No head for this long (3 slots) logs a warning.
const HEAD_STALL: Duration = Duration::from_secs(36);
/// A head whose timestamp is older than this (2 slots) logs a warning.
const HEAD_STALE_SECS: i64 = 24;
/// The error of a send that did not start because a newer head came first.
const SUPERSEDED: &str = "superseded";

/// What all batches of one run share.
struct Ctx {
    client: reqwest::Client,
    signer: PrivateKeySigner,
    /// Each endpoint with its in-flight limit.
    endpoints: Vec<(Url, Semaphore)>,
    send_delay: Duration,
    send_timeout: Duration,
    /// The newest target block a batch was started for.
    latest: AtomicU64,
    store: Arc<dyn Store>,
    /// Set by the first answer that says the builder does not admit the signer: the endpoint
    /// and the builder's message.
    rejected: watch::Sender<Option<(Url, String)>>,
}

/// [`run_until`] with no stop: runs until `heads` ends (never, for the live stream).
pub async fn run(
    cfg: &BotConfig,
    cycles: &[Cycle],
    signer: PrivateKeySigner,
    heads: impl Stream<Item = Head>,
    store: Arc<dyn Store>,
) -> Result<()> {
    run_until(cfg, cycles, signer, heads, store, std::future::pending()).await
}

/// Sends one batch per new head until `heads` ends or `stop` resolves. A batch checks the
/// newest target right before each POST, so no request for an older target block starts once
/// a newer batch did. Older batches are not aborted: their in-flight sends finish within
/// `send_timeout_ms` and record normally, so every (target, request, endpoint) the loop decided
/// to send ends with exactly one record. Returns once every started batch has finished.
pub async fn run_until(
    cfg: &BotConfig,
    cycles: &[Cycle],
    signer: PrivateKeySigner,
    heads: impl Stream<Item = Head>,
    store: Arc<dyn Store>,
    stop: impl std::future::Future<Output = ()>,
) -> Result<()> {
    let groups: Vec<Group> = select_groups(cfg, cycles)?
        .iter()
        .flat_map(|g| (0..cfg.request_copies).map(|k| g.copy(k)))
        .collect();
    let ctx = Arc::new(Ctx {
        client: reqwest::Client::new(),
        signer,
        endpoints: cfg
            .endpoints
            .iter()
            .map(|u| (u.clone(), Semaphore::new(POSTS_PER_ENDPOINT)))
            .collect(),
        send_delay: Duration::from_millis(cfg.send_delay_ms),
        send_timeout: Duration::from_millis(cfg.send_timeout_ms),
        latest: AtomicU64::new(0),
        store,
        rejected: watch::channel(None).0,
    });
    let mut rejected = ctx.rejected.subscribe();
    let mut heads = std::pin::pin!(heads);
    let mut stop = std::pin::pin!(stop);
    let mut batches = tokio::task::JoinSet::new();
    loop {
        let next = tokio::select! {
            _ = &mut stop => break,
            _ = rejected.changed() => {
                let (url, said) = rejected.borrow().clone().expect("set before the change");
                return Err(not_admitted_error(ctx.signer.address(), &url, &said));
            }
            n = tokio::time::timeout(HEAD_STALL, heads.next()) => n,
        };
        let h = match next {
            Ok(Some(h)) => h,
            Ok(None) => break,
            Err(_) => {
                tracing::warn!("no new head for {} s", HEAD_STALL.as_secs());
                continue;
            }
        };
        warn_if_stale(&h);
        let target = h.number + 1;
        if target <= ctx.latest.load(Ordering::SeqCst) {
            continue; // never two batches for one target block
        }
        ctx.latest.store(target, Ordering::SeqCst);
        while batches.try_join_next().is_some() {}
        let bodies = request_bodies(cfg, &groups, &h, ctx.signer.address());
        batches.spawn(send_batch(ctx.clone(), target, bodies));
    }
    while batches.join_next().await.is_some() {}
    if let Some((url, said)) = rejected.borrow().clone() {
        return Err(not_admitted_error(ctx.signer.address(), &url, &said));
    }
    Ok(())
}

fn warn_if_stale(h: &Head) {
    let age = now() - h.timestamp as i64;
    if age > HEAD_STALE_SECS {
        tracing::warn!(head = h.number, age_s = age, "stale head");
    }
}

/// The `bex_sendBundle` bodies for head `h`, one per group, named by the group. The
/// `weiPerGas` uses the basefee of the target block `h.number + 1`.
fn request_bodies(
    cfg: &BotConfig,
    groups: &[Group],
    h: &Head,
    signer: Address,
) -> Vec<(String, Vec<u8>)> {
    let target = h.number + 1;
    let wpg = wei_per_gas(cfg, next_base_fee(h));
    groups
        .iter()
        .map(|g| {
            let r = build_group_request(cfg, g, target, wpg, signer);
            (g.name.clone(), envelope("bex_sendBundle", &r))
        })
        .collect()
}

/// The groups `run` sends, chosen once at startup, so the set never changes across heads (a
/// changed set would replace live requests). All cycles are grouped (`group_size`). Then
/// `select = "top"` keeps the first `pending_budget() / request_copies` groups in file order, and
/// `select = "all"` refuses to start if there are more.
pub fn select_groups(cfg: &BotConfig, cycles: &[Cycle]) -> Result<Vec<Group>> {
    let budget = cfg.pending_budget();
    let k = budget / cfg.request_copies;
    if k == 0 {
        bail!(
            "pending budget is {budget} (pending_cap {}), below request_copies {}; raise pending_cap",
            cfg.pending_cap,
            cfg.request_copies
        );
    }
    let mut groups = group_cycles(cycles, cfg.group_size);
    let total = groups.len();
    if total > k && cfg.select == Select::All {
        bail!(
            "{total} groups x {} copies ({} cycles, group_size {}) exceed the pending budget {budget} (pending_cap {}); raise pending_cap, trim cycles or set select = \"top\"",
            cfg.request_copies,
            cycles.len(),
            cfg.group_size,
            cfg.pending_cap
        );
    }
    groups.truncate(k);
    let m: usize = groups.iter().map(|g| g.cycles.len()).sum();
    if groups.len() < total {
        tracing::warn!(
            "sending {k} groups x {} copies ({m} cycles) of {} cycles (pending budget {budget}, pending_cap {}); raise pending_cap or trim the set",
            cfg.request_copies,
            cycles.len(),
            cfg.pending_cap
        );
    }
    let names: Vec<&str> = groups.iter().map(|g| g.name.as_str()).collect();
    tracing::info!(
        select = ?cfg.select,
        uuid_mode = ?cfg.uuid_mode,
        pending_cap = cfg.pending_cap,
        group_size = cfg.group_size,
        copies = cfg.request_copies,
        budget,
        total = cycles.len(),
        groups = groups.len(),
        sent_cycles = m,
        cycles = %names.join(","),
        "cycle set"
    );
    Ok(groups)
}

/// The result of one send, for the batch log line: (endpoint index, error, retries).
type SendResult = (usize, Option<String>, u32);

/// Sends every body of one head to every endpoint, after `send_delay_ms`.
async fn send_batch(ctx: Arc<Ctx>, target: u64, bodies: Vec<(String, Vec<u8>)>) {
    tokio::time::sleep(ctx.send_delay).await;
    let ctx = &*ctx;
    // Every (request, endpoint) is its own future: a slow endpoint delays only itself.
    let sends = bodies.iter().flat_map(|(name, body)| {
        (0..ctx.endpoints.len()).map(move |i| send_one(ctx, target, i, name, body))
    });
    let results = join_all(sends).await;
    log_batch(ctx, target, &results);
}

/// One request to endpoint `i`: send, record, and return the error unless it was superseded.
async fn send_one(ctx: &Ctx, target: u64, i: usize, name: &str, body: &[u8]) -> SendResult {
    let url = &ctx.endpoints[i].0;
    let (outcome, retries) = send_with_retry(ctx, target, i, body).await;
    if let Ok(hash) = &outcome {
        // log the host only: an endpoint URL can hold a key
        let host = url.host_str().unwrap_or("?");
        tracing::debug!(target, cycle = %name, host, %hash, "sent");
    }
    let failure = outcome.as_ref().err().filter(|e| *e != SUPERSEDED).cloned();
    ctx.store.record(Record {
        target_block: target,
        cycle: name.to_string(),
        endpoint: url.clone(),
        outcome,
        retries,
    });
    (i, failure, retries)
}

/// `bex_sendBundle` with one retry of a timeout or transport error, with the same bytes (same
/// uuid and sequence number: a builder that already has the request drops the copy as a
/// duplicate). No send starts once `target` is no longer the newest target block. Returns the
/// bundle hash or the error, and the retries sent (0 or 1).
async fn send_with_retry(
    ctx: &Ctx,
    target: u64,
    i: usize,
    body: &[u8],
) -> (Result<String, String>, u32) {
    let (url, posts) = &ctx.endpoints[i];
    let mut retries = 0;
    let mut first_err = None;
    let outcome = loop {
        let permit = posts.acquire().await.expect("semaphore never closed");
        if ctx.latest.load(Ordering::SeqCst) != target {
            break Err(first_err.unwrap_or_else(|| SUPERSEDED.to_string()));
        }
        retries = u32::from(first_err.is_some());
        let sent = send_bundle(
            &ctx.client,
            &ctx.signer,
            url,
            body.to_vec(),
            ctx.send_timeout,
        )
        .await;
        match sent {
            Ok(hash) => break Ok(hash),
            Err(e) => {
                if let Some(said) = not_admitted(&e) {
                    ctx.rejected.send_if_modified(|r| {
                        r.is_none() && r.replace((url.clone(), said)).is_none()
                    });
                }
                if retries > 0 || !retryable(&e) {
                    break Err(format!("{e:#}"));
                }
                first_err = Some(format!("{e:#}"));
                drop(permit); // the wait holds no in-flight slot
                tokio::time::sleep(RETRY_DELAY).await;
            }
        }
    };
    (outcome, retries)
}

/// One log line per endpoint per head, not one per request.
fn log_batch(ctx: &Ctx, target: u64, results: &[SendResult]) {
    for (i, (url, _)) in ctx.endpoints.iter().enumerate() {
        let mine = || results.iter().filter(|(j, _, _)| *j == i);
        let retried: u32 = mine().map(|(_, _, r)| r).sum();
        let mut errs = mine().filter_map(|(_, e, _)| e.as_ref());
        let host = url.host_str().unwrap_or("?");
        if let Some(first) = errs.next() {
            let failed = 1 + errs.count();
            tracing::warn!(target, host, failed, retried, first_error = %first, "sends failed");
        } else if retried > 0 {
            tracing::info!(target, host, retried, "sends retried, all sent");
        }
    }
}

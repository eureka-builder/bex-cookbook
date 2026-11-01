//! What happened to the sends. `run` starts [`track`] next to the send loop, on its own head
//! stream, and it writes to the same store: the executor's `CycleExecuted` logs with this sender's
//! tag (landings), from a block cursor up to each head. Each landing's block hash is checked again
//! at depth 2 (provisional) and 12 (final). A reorged landing rewinds the cursor, so the new
//! block's logs are read.
use crate::abi::ICycleExecutor::CycleExecuted;
use crate::config::BotConfig;
use crate::sender::rpc;
use crate::store::SqliteStore;
use alloy::primitives::B256;
use alloy::rpc::types::Log;
use alloy::sol_types::SolEvent;
use anyhow::{Context, Result};
use futures::{Stream, StreamExt};
use rusqlite::OptionalExtension;
use serde_json::json;

/// The newest blocks re-scanned on every head, whatever the cursor: a block reorged
/// in at a height already scanned still has its logs read.
const WINDOW: u64 = 3;
/// Most blocks per `eth_getLogs` call when the cursor lags the head.
pub const LOG_CHUNK: u64 = 100;
/// A cursor seeded from the earliest send reaches back at most this many blocks, so a
/// stale DB cannot trigger a days-long rescan.
const MAX_SEED_LAG: i64 = 1000;
/// `meta` key: the last block whose logs were read.
pub const LAST_SCANNED: &str = "last_scanned_block";
/// A landing's block hash is checked at this depth (provisional) ...
const CONFIRM_DEPTH: u64 = 2;
/// ... and again at this one (final). A landing counts as final only after this check.
pub const CONFIRM_DEPTH_FINAL: u64 = 12;

/// Runs until `heads` ends. Landings are this sender's: `CycleExecuted` logs whose `tag` topic
/// is `tag` (`request::tag`).
pub async fn track(
    cfg: &BotConfig,
    store: &SqliteStore,
    heads: impl Stream<Item = u64>,
    tag: B256,
) {
    let client = reqwest::Client::new();
    let mut heads = std::pin::pin!(heads);
    while let Some(h) = heads.next().await {
        track_head(cfg, &client, store, h, tag).await;
    }
}

/// One landing tick. Each step logs its own failure and the next step still runs.
pub async fn track_head(
    cfg: &BotConfig,
    client: &reqwest::Client,
    store: &SqliteStore,
    head: u64,
    tag: B256,
) {
    if let Err(e) = track_landings(cfg, client, store, head, tag).await {
        tracing::warn!(head, error = format!("{e:#}"), "landing tracking failed");
    }
    if let Err(e) = confirm_landings(cfg, client, store, head).await {
        tracing::warn!(head, error = format!("{e:#}"), "canonicality check failed");
    }
}

/// Reads `CycleExecuted` logs from `min(cursor + 1, head - WINDOW + 1)` to `head` in
/// chunks of `LOG_CHUNK` blocks; the cursor moves past a chunk only once it is stored,
/// so a failed or skipped head is scanned on a later one.
async fn track_landings(
    cfg: &BotConfig,
    client: &reqwest::Client,
    store: &SqliteStore,
    head: u64,
    tag: B256,
) -> Result<()> {
    // No cursor yet: persist a lower bound BEFORE the first scan (the window start, or
    // the block before the earliest send if that is older), so a failing first scan
    // leaves a cursor and the gap is rescanned on recovery.
    let seed = head.saturating_sub(WINDOW) as i64;
    let cursor: Option<i64> = store
        .with(move |c| -> rusqlite::Result<Option<i64>> {
            let cur: Option<i64> = c
                .query_row(
                    "SELECT value FROM meta WHERE key = ?",
                    [LAST_SCANNED],
                    |r| r.get(0),
                )
                .optional()?;
            if cur.is_some() {
                return Ok(cur);
            }
            let first_sent: Option<i64> =
                c.query_row("SELECT MIN(block) FROM sent", [], |r| r.get(0))?;
            let floor = (head as i64 - MAX_SEED_LAG).max(0);
            let lower = first_sent.map_or(seed, |b| seed.min((b - 2).max(floor)));
            c.execute(
                "INSERT OR IGNORE INTO meta(key, value) VALUES (?1, ?2)",
                (LAST_SCANNED, lower),
            )?;
            Ok(Some(lower))
        })
        .await??;
    let recent = head.saturating_sub(WINDOW - 1);
    let mut from = cursor.map_or(recent, |c| (c as u64 + 1).min(recent));
    while from <= head {
        let to = (from + LOG_CHUNK - 1).min(head);
        scan_logs(cfg, client, store, from, to, tag).await?;
        store
            .with(move |c| {
                c.execute(
                    "INSERT INTO meta(key, value) VALUES (?1, ?2)
                     ON CONFLICT(key) DO UPDATE SET value = MAX(value, excluded.value)",
                    (LAST_SCANNED, to as i64),
                )
            })
            .await??;
        from = to + 1;
    }
    Ok(())
}

async fn scan_logs(
    cfg: &BotConfig,
    client: &reqwest::Client,
    store: &SqliteStore,
    from: u64,
    to: u64,
    tag: B256,
) -> Result<()> {
    // The shared executor logs every sender's cycles: ask only for ours (topic 2 = tag).
    let params = json!([{
        "fromBlock": format!("{from:#x}"),
        "toBlock": format!("{to:#x}"),
        "address": cfg.executor,
        "topics": [CycleExecuted::SIGNATURE_HASH, null, tag],
    }]);
    let logs: Vec<Log> =
        serde_json::from_value(rpc(client, &cfg.rpc_http, "eth_getLogs", params).await?)
            .context("eth_getLogs: bad logs")?;
    for log in logs {
        let (Some(block), Some(block_hash), Some(tx_hash), false) = (
            log.block_number,
            log.block_hash,
            log.transaction_hash,
            log.removed,
        ) else {
            continue;
        };
        if log.topics().get(2) != Some(&tag) {
            continue; // a node that ignores the topic filter: another sender's cycle
        }
        let Ok(ev) = CycleExecuted::decode_log(&log.inner) else {
            tracing::warn!(%tx_hash, "undecodable CycleExecuted log");
            continue;
        };
        let ev = ev.data;
        store
            .with(move |c| {
                c.execute(
                    "INSERT OR IGNORE INTO landing(block, block_hash, tx_hash, cycle_id, amount_in, profit, paid) VALUES (?,?,?,?,?,?,?)",
                    (
                        block as i64,
                        format!("{block_hash:#x}"),
                        format!("{tx_hash:#x}"),
                        format!("{:#x}", ev.cycleId),
                        ev.amountIn.to_string(),
                        ev.profit.to_string(),
                        ev.paidToCoinbase.to_string(),
                    ),
                )
            })
            .await??;
    }
    Ok(())
}

/// Landings at least `CONFIRM_DEPTH` blocks old and not yet checked, and canonical
/// landings at least `CONFIRM_DEPTH_FINAL` old not yet final: `canonical` becomes whether
/// the chain's block at that height still has the landing's hash, and `confirmed_depth`
/// the depth checked. A failed check rewinds the landing cursor to the block before it,
/// so the replacement blocks are re-read.
async fn confirm_landings(
    cfg: &BotConfig,
    client: &reqwest::Client,
    store: &SqliteStore,
    head: u64,
) -> Result<()> {
    let max = head.saturating_sub(CONFIRM_DEPTH) as i64;
    let max_final = head.saturating_sub(CONFIRM_DEPTH_FINAL) as i64;
    let pending = store
        .with(move |c| -> rusqlite::Result<Vec<(i64, String)>> {
            c.prepare(
                "SELECT DISTINCT block, block_hash FROM landing
                 WHERE (canonical IS NULL AND block <= ?1)
                    OR (canonical = 1 AND COALESCE(confirmed_depth, 0) < ?3 AND block <= ?2)",
            )?
            .query_map((max, max_final, CONFIRM_DEPTH_FINAL as i64), |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .and_then(|rows| rows.collect())
        })
        .await??;
    for (block, block_hash) in pending {
        let b = rpc(
            client,
            &cfg.rpc_http,
            "eth_getBlockByNumber",
            json!([format!("{block:#x}"), false]),
        )
        .await?;
        let Some(chain_hash) = b["hash"].as_str() else {
            continue; // block unknown to the node: retry next head
        };
        let canonical = chain_hash.eq_ignore_ascii_case(&block_hash);
        if !canonical {
            tracing::warn!(block, %block_hash, chain_hash, "landing reorged out");
        }
        let depth = if block <= max_final {
            CONFIRM_DEPTH_FINAL
        } else {
            CONFIRM_DEPTH
        } as i64;
        store
            .with(move |c| -> rusqlite::Result<()> {
                c.execute(
                    "UPDATE landing SET canonical = ?, confirmed_depth = ? WHERE block = ? AND block_hash = ?",
                    (canonical, canonical.then_some(depth), block, block_hash),
                )?;
                if !canonical {
                    c.execute(
                        "UPDATE meta SET value = MIN(value, ?) WHERE key = ?",
                        (block - 1, LAST_SCANNED),
                    )?;
                }
                Ok(())
            })
            .await??;
    }
    Ok(())
}

//! Where the bot writes what it did. `run` records one [`Record`] per send through the [`Store`]
//! trait. `track` adds the on-chain landings, and `status` reads them all.
//!
//! [`SqliteStore`] is the store of the binary. One writer thread owns the only connection. Every
//! operation is a closure sent over a channel, so no SQLite call blocks the tokio runtime.
//! [`MemStore`] keeps records in memory, for tests.
//!
//! Tables: `sent` (one row per send), `landing` (`CycleExecuted` logs), `meta` (the landing
//! scan cursor).
use crate::sender::host_port;
use anyhow::{anyhow, Result};
use rusqlite::Connection;
use std::{
    path::Path,
    sync::mpsc::{channel, Sender},
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};
use url::Url;

/// One send attempt: `(target block, request name, endpoint, bundle_hash | error)`.
#[derive(Debug, Clone)]
pub struct Record {
    pub target_block: u64,
    /// The request's name: the group name (`<seed>+<N>`, `#k` for a copy), or the cycle name
    /// for a group of one. Stored in the `sent.cycle` column.
    pub cycle: String,
    pub endpoint: Url,
    pub outcome: Result<String, String>,
    /// Sends after the first (0 or 1): a timeout or transport error is retried once.
    pub retries: u32,
}

/// Where `run` puts its records. `record` must not block.
pub trait Store: Send + Sync {
    fn record(&self, rec: Record);
}

/// Records in memory, for tests.
#[derive(Default)]
pub struct MemStore(Mutex<Vec<Record>>);

impl MemStore {
    pub fn records(&self) -> Vec<Record> {
        self.0.lock().unwrap().clone()
    }
}

impl Store for MemStore {
    fn record(&self, rec: Record) {
        self.0.lock().unwrap().push(rec);
    }
}

type Job = Box<dyn FnOnce(&mut Connection) + Send>;

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS sent(
    block INTEGER NOT NULL, cycle TEXT NOT NULL, endpoint TEXT NOT NULL,
    bundle_hash TEXT, error TEXT, sent_at INTEGER NOT NULL, retries INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS sent_block ON sent(block);
CREATE TABLE IF NOT EXISTS landing(
    block INTEGER NOT NULL, block_hash TEXT NOT NULL, tx_hash TEXT NOT NULL,
    cycle_id TEXT NOT NULL, amount_in TEXT NOT NULL, profit TEXT NOT NULL,
    paid TEXT NOT NULL, canonical INTEGER, confirmed_depth INTEGER,
    UNIQUE(block_hash, tx_hash, cycle_id));
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
";

/// Unix time in seconds.
pub fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

pub struct SqliteStore(Sender<Job>);

impl SqliteStore {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        conn.execute_batch(SCHEMA)?;
        let (tx, rx) = channel::<Job>();
        std::thread::Builder::new()
            .name("sqlite-writer".into())
            .spawn(move || {
                let mut conn = conn;
                for job in rx {
                    job(&mut conn);
                }
            })?;
        Ok(Self(tx))
    }

    /// Returns once every job queued before it has run (all earlier records are on disk).
    pub async fn flush(&self) -> Result<()> {
        self.with(|_| ()).await
    }

    /// Runs `f` on the writer thread and awaits its result.
    pub async fn with<R: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Connection) -> R + Send + 'static,
    ) -> Result<R> {
        let (tx, rx) = tokio::sync::oneshot::channel();
        self.0
            .send(Box::new(move |c| {
                let _ = tx.send(f(c));
            }))
            .map_err(|_| anyhow!("sqlite writer stopped"))?;
        rx.await.map_err(|_| anyhow!("sqlite writer stopped"))
    }
}

impl Store for SqliteStore {
    /// Queues the insert and returns at once. The endpoint is stored as `host:port` only.
    fn record(&self, rec: Record) {
        let (hash, error) = match rec.outcome {
            Ok(h) => (Some(h), None),
            Err(e) => (None, Some(e)),
        };
        let endpoint = host_port(&rec.endpoint);
        let job: Job = Box::new(move |c| {
            if let Err(e) = c.execute(
                "INSERT INTO sent(block, cycle, endpoint, bundle_hash, error, sent_at, retries) VALUES (?,?,?,?,?,?,?)",
                (rec.target_block as i64, rec.cycle, endpoint, hash, error, now(), rec.retries),
            ) {
                tracing::error!(error = %e, "recording a send failed");
            }
        });
        if self.0.send(job).is_err() {
            tracing::error!("sqlite writer stopped; send record dropped");
        }
    }
}

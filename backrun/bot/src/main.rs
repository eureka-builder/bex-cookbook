//! The `bex-backrun` command line: `run`, `simulate` and `status`.
//!
//! The library modules, in the order of the request flow:
//! `config` (bot.toml) and `cycles` (cycles.toml) are loaded, `startup` checks the builder and the
//! contracts, `head` yields new heads, `groups` puts cycles into requests, `floor` prices each
//! cycle's gas, `request` builds each request, `sender` posts it, `store` records it, and `track`
//! reads what happened. `simulate` and `status` are the other two commands.
use anyhow::Result;
use bex_backrun::{
    config, cycles, head, request, run, sender, simulate, startup, status, store::SqliteStore,
    track,
};
use clap::{Parser, Subcommand};
use futures::StreamExt;
use std::{
    path::{Path, PathBuf},
    process::ExitCode,
    sync::Arc,
};
use url::Url;

#[derive(Parser)]
#[command(name = "bex-backrun", about = "BEX backrun bot")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Send one BEX request per group of cycles per block.
    Run {
        #[arg(long, default_value = "bot.toml")]
        config: PathBuf,
        #[arg(long, default_value = "cycles.toml")]
        cycles: PathBuf,
    },
    /// Dry-run every cycle with `bex_simulate`; exit 1 if any is rejected for a real reason.
    Simulate {
        #[arg(long, default_value = "bot.toml")]
        config: PathBuf,
        #[arg(long, default_value = "cycles.toml")]
        cycles: PathBuf,
        /// Defaults to the first endpoint in the config.
        #[arg(long)]
        endpoint: Option<Url>,
        /// Evaluate without a deploy: no `compute.code`; `stateOverrides` installs
        /// `solver_code` (and `executor_code`, when set) instead.
        #[arg(long)]
        override_code: bool,
        /// Run this many times in all...
        #[arg(long, default_value_t = 1)]
        repeat_blocks: u32,
        /// ...one run every this many new heads.
        #[arg(long, default_value_t = 1)]
        every: u64,
        /// Append every row to this CSV (relative to the current directory).
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// Show sends and landings from the store.
    Status {
        #[arg(long, default_value = "bot.toml")]
        config: PathBuf,
        #[arg(long, default_value = "cycles.toml")]
        cycles: PathBuf,
        /// Window: a block count (`600`) or a duration (`30m`, `2h`, `1d`; 12 s blocks).
        #[arg(long, default_value = "1d", value_parser = parse_since)]
        since: u64,
        /// Also `eth_call` solve() for every cycle at latest.
        #[arg(long)]
        probe: bool,
    },
}

fn parse_since(s: &str) -> Result<u64, String> {
    let (num, mult) = match s.chars().last() {
        Some('s') => (&s[..s.len() - 1], 1),
        Some('m') => (&s[..s.len() - 1], 60),
        Some('h') => (&s[..s.len() - 1], 3600),
        Some('d') => (&s[..s.len() - 1], 86_400),
        _ => return s.parse().map_err(|_| format!("bad --since {s:?}")),
    };
    let n: u64 = num.parse().map_err(|_| format!("bad --since {s:?}"))?;
    let secs = n
        .checked_mul(mult)
        .ok_or_else(|| format!("--since {s:?} is too large"))?;
    Ok(secs / 12)
}

#[tokio::main]
async fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with_writer(std::io::stderr)
        .init();
    match real_main(Cli::parse()).await {
        Ok(code) => code,
        Err(e) => {
            tracing::error!("{e:#}");
            ExitCode::from(2)
        }
    }
}

async fn real_main(cli: Cli) -> Result<ExitCode> {
    match cli.cmd {
        Cmd::Run { config, cycles } => cmd_run(&config, &cycles).await,
        Cmd::Simulate {
            config,
            cycles,
            endpoint,
            override_code,
            repeat_blocks,
            every,
            out,
        } => {
            let opts = simulate::Repeat {
                override_code,
                runs: repeat_blocks,
                every,
                out,
            };
            cmd_simulate(&config, &cycles, endpoint, &opts).await
        }
        Cmd::Status {
            config,
            cycles,
            since,
            probe,
        } => cmd_status(&config, &cycles, since, probe).await,
    }
}

/// `run`: the startup checks, then the tracker in the background and the send loop until
/// ctrl-c. On ctrl-c the loop takes no more heads, the batches in flight finish and record,
/// and the store is flushed.
async fn cmd_run(config: &Path, cycles: &Path) -> Result<ExitCode> {
    let cfg = config::load_bot(config)?;
    let cycles = cycles::load_cycles(cycles, cfg.weth)?;
    let signer = sender::signer_from_env(&cfg)?;
    startup::check(&cfg, &signer, &cfg.endpoints, false).await?;
    let store = Arc::new(SqliteStore::open(&cfg.db_path)?);
    let tag = request::tag(signer.address());
    let tracker = {
        let (cfg, store) = (cfg.clone(), store.clone());
        tokio::spawn(async move {
            track::track(&cfg, &store, head::heads(&cfg).map(|h| h.number), tag).await
        })
    };
    let stop_tracker = tracker.abort_handle();
    tokio::spawn(async move {
        match tracker.await {
            Err(e) if e.is_cancelled() => {}
            r => tracing::error!(?r, "tracker exited; sends go on without landing tracking"),
        }
    });
    let stop = async {
        let _ = tokio::signal::ctrl_c().await;
        tracing::info!("ctrl-c: draining in-flight sends");
    };
    let res = run::run_until(
        &cfg,
        &cycles,
        signer,
        head::heads(&cfg),
        store.clone(),
        stop,
    )
    .await;
    stop_tracker.abort();
    store.flush().await?;
    res?;
    Ok(ExitCode::SUCCESS)
}

/// `simulate`: the startup checks on every endpoint (and `--endpoint`), then the simulate runs.
/// Exit code 1 if a cycle failed.
async fn cmd_simulate(
    config: &Path,
    cycles: &Path,
    endpoint: Option<Url>,
    opts: &simulate::Repeat,
) -> Result<ExitCode> {
    let cfg = config::load_bot(config)?;
    let cycles = cycles::load_cycles(cycles, cfg.weth)?;
    let signer = sender::signer_from_env(&cfg)?;
    let endpoint = endpoint.unwrap_or_else(|| cfg.endpoints[0].clone());
    let mut checked = cfg.endpoints.clone();
    if !checked.contains(&endpoint) {
        checked.push(endpoint.clone());
    }
    startup::check(&cfg, &signer, &checked, opts.override_code).await?;
    let heads = head::poll_heads(cfg.rpc_http.clone(), head::POLL_INTERVAL);
    let v = simulate::repeat(&cfg, &cycles, &endpoint, &signer, heads, opts).await?;
    println!(
        "accepted {}  no-profit {}  failed {}",
        v.accepted, v.no_profit, v.failed
    );
    Ok(if v.ok() {
        ExitCode::SUCCESS
    } else {
        ExitCode::from(1)
    })
}

/// `status`: the table from the store, then (`--probe`) one `solve` per cycle. `--probe` also
/// works before the first `run` (no database yet): then it prints the probe only.
async fn cmd_status(config: &Path, cycles: &Path, since: u64, probe: bool) -> Result<ExitCode> {
    let cfg = config::load_bot(config)?;
    let cycles = cycles::load_cycles(cycles, cfg.weth)?;
    if cfg.db_path.exists() {
        let store = SqliteStore::open(&cfg.db_path)?;
        println!(
            "{}",
            status::format_table(&status::status(&store, &cycles, since).await?)
        );
        store.flush().await?;
    } else {
        anyhow::ensure!(
            probe,
            "no database at {} (db_path, relative to the config file's directory): `run` creates it, \
             or use --probe alone",
            cfg.db_path.display()
        );
        println!("no database yet at {}: probe only", cfg.db_path.display());
    }
    if probe {
        for (name, line) in status::probe(&cfg, &cycles).await {
            println!("{name}  {line}");
        }
    }
    Ok(ExitCode::SUCCESS)
}

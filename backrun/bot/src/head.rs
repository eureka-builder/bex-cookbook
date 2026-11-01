//! The chain head source of `run` (and of `track`, which runs next to it): a stream of new
//! heads, each yielded once and in increasing order.
//!
//! With `rpc_ws` set, the heads come from WS `newHeads`, and HTTP polling of `rpc_http` fills in
//! while the WS connects, after it drops, and while it is silent. Without `rpc_ws`, the bot
//! polls `rpc_http` every [`POLL_INTERVAL`]. Each head starts one batch of sends in `run.rs`.
use crate::config::BotConfig;
use crate::sender::redact;
use alloy::eips::BlockNumberOrTag;
use alloy::providers::{Provider, ProviderBuilder, WsConnect};
use alloy::pubsub::{ConnectionHandle, PubSubConnect};
use alloy::rpc::types::Header as RpcHeader;
use alloy::transports::{TransportErrorKind, TransportResult};
use futures::{future::Either, Stream, StreamExt};
use std::time::Duration;
use url::Url;

/// `WsConnect` that never reconnects. alloy's pubsub service redials by itself when the
/// socket drops, so one `ws_heads` attempt opened a second connection behind our back (and
/// up to ten more while the node refuses). Here a dropped socket ends the subscription
/// stream at once and `ws_heads` decides when to dial again.
struct OneShotWs(WsConnect);

impl PubSubConnect for OneShotWs {
    fn is_local(&self) -> bool {
        self.0.is_local()
    }
    async fn connect(&self) -> TransportResult<ConnectionHandle> {
        // one failed `try_reconnect` is one try too many: shut the service down
        Ok(self.0.connect().await?.with_max_retries(1))
    }
    async fn try_reconnect(&self) -> TransportResult<ConnectionHandle> {
        Err(TransportErrorKind::custom_str("ws reconnect disabled"))
    }
}

pub const POLL_INTERVAL: Duration = Duration::from_millis(500);
/// Timers of the WS head source (`ws_heads`).
#[derive(Debug, Clone, Copy)]
pub struct WsTimers {
    /// No WS head for this long means the WS is dead.
    pub idle: Duration,
    /// How long to poll after a WS failure before trying the WS again.
    pub retry: Duration,
    /// Most time for connect + `eth_subscribe`.
    pub connect: Duration,
}

impl WsTimers {
    /// idle 25 s: two slots plus head lag, so one missed slot does not trip it.
    pub const DEFAULT: Self = Self {
        idle: Duration::from_secs(25),
        retry: Duration::from_secs(30),
        connect: Duration::from_secs(5),
    };
}

/// The header fields the bot uses: the block number, the basefee inputs of the next block,
/// and the timestamp (for the stale-head warning).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Head {
    pub number: u64,
    pub base_fee: u64,
    pub gas_used: u64,
    pub gas_limit: u64,
    pub timestamp: u64,
}

impl Head {
    pub(crate) fn from_rpc(h: &RpcHeader) -> Self {
        Head {
            number: h.number,
            base_fee: h.base_fee_per_gas.unwrap_or_default(),
            gas_used: h.gas_used,
            gas_limit: h.gas_limit,
            timestamp: h.timestamp,
        }
    }
}

/// Heads, deduplicated by number and never lower than one already yielded.
pub fn heads(cfg: &BotConfig) -> impl Stream<Item = Head> {
    let http = cfg.rpc_http.clone();
    let raw = match cfg.rpc_ws.clone() {
        Some(ws) => ws_heads(ws, http, WsTimers::DEFAULT).boxed(),
        None => poll_heads(http, POLL_INTERVAL).boxed(),
    };
    monotonic(raw)
}

/// Drops heads whose number is not above the last yielded one. A same-height
/// reorg head is dropped by design: the bot targets `number + 1` either way.
pub fn monotonic(s: impl Stream<Item = Head>) -> impl Stream<Item = Head> {
    let mut last: Option<u64> = None;
    s.filter_map(move |h| {
        let keep = last.is_none_or(|l| h.number > l);
        if keep {
            last = Some(h.number);
        }
        futures::future::ready(keep.then_some(h))
    })
}

/// HTTP polling of `eth_getBlockByNumber("latest", false)`; errors are retried next tick.
pub fn poll_heads(url: Url, every: Duration) -> impl Stream<Item = Head> {
    async_stream::stream! {
        let p = ProviderBuilder::new().connect_http(url.clone());
        let mut tick = tokio::time::interval(every);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tick.tick().await;
            match p.get_block_by_number(BlockNumberOrTag::Latest).await {
                Ok(Some(b)) => yield Head::from_rpc(&b.header),
                Ok(None) => {}
                Err(e) => tracing::warn!(error = %redact(&e, &url), "head poll failed"),
            }
        }
    }
}

enum Ev {
    Ws(Option<Head>),
    Poll(Head),
    Done,
}

/// `eth_subscribe("newHeads")` on `ws`, with `http` polling as the fallback. Polling runs
/// while the WS connects and subscribes and until its first head arrives, so a slow or
/// black-holed WS never delays a head. When the WS cannot connect within `t.connect`, its
/// stream ends, or no head comes for `t.idle`, polling alone serves heads for `t.retry`, then the WS is tried again.
/// Deduplicated and monotonic (`monotonic`): a head seen on both sources is yielded once.
pub fn ws_heads(ws: Url, http: Url, t: WsTimers) -> impl Stream<Item = Head> {
    let raw = async_stream::stream! {
        let mut poll = Box::pin(poll_heads(http, POLL_INTERVAL));
        loop {
            // 1. connect + subscribe, polling meanwhile
            let connect = tokio::time::timeout(t.connect, async {
                let p = ProviderBuilder::new().connect_pubsub_with(OneShotWs(WsConnect::new(ws.as_str()))).await?;
                let sub = p.subscribe_blocks().await?;
                Ok::<_, alloy::transports::TransportError>((p, sub))
            });
            let mut connect = std::pin::pin!(connect);
            let sub = loop {
                let ev = tokio::select! {
                    r = &mut connect => Either::Left(r),
                    Some(h) = poll.next() => Either::Right(h),
                };
                match ev {
                    Either::Left(r) => break r,
                    Either::Right(h) => yield h,
                }
            };
            // 2. WS heads; polling goes on until the first one
            match sub {
                Ok(Ok((_p, sub))) => {
                    let mut s = sub.into_stream();
                    let mut delivered = false;
                    let mut deadline = tokio::time::Instant::now() + t.idle;
                    loop {
                        let ev = tokio::select! {
                            h = s.next() => Ev::Ws(h.map(|h| Head::from_rpc(&h))),
                            _ = tokio::time::sleep_until(deadline) => Ev::Ws(None),
                            Some(h) = poll.next(), if !delivered => Ev::Poll(h),
                        };
                        match ev {
                            Ev::Ws(Some(h)) => {
                                delivered = true;
                                deadline = tokio::time::Instant::now() + t.idle;
                                yield h;
                            }
                            Ev::Poll(h) => yield h,
                            _ => break,
                        }
                    }
                    tracing::warn!(idle_s = t.idle.as_secs(), "ws newHeads ended or idle; polling rpc_http");
                }
                Ok(Err(e)) => tracing::warn!(error = %redact(&e, &ws), "ws newHeads failed; polling rpc_http"),
                Err(_) => tracing::warn!("ws connect timed out; polling rpc_http"),
            }
            // 3. polling alone for `t.retry`
            let mut until = std::pin::pin!(tokio::time::sleep(t.retry));
            loop {
                let ev = tokio::select! {
                    _ = &mut until => Ev::Done,
                    Some(h) = poll.next() => Ev::Poll(h),
                };
                match ev {
                    Ev::Poll(h) => yield h,
                    _ => break,
                }
            }
        }
    };
    monotonic(raw)
}

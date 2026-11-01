use bex_backrun::head::{monotonic, poll_heads, ws_heads, WsTimers};
use futures::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;
use wiremock::{matchers::method, Mock, MockServer, Request, Respond, ResponseTemplate};

fn block(n: u64) -> Value {
    let z32 = format!("0x{}", "0".repeat(64));
    json!({
        "hash": format!("0x{:064x}", n), "parentHash": z32, "sha3Uncles": z32,
        "miner": format!("0x{}", "0".repeat(40)), "stateRoot": z32,
        "transactionsRoot": z32, "receiptsRoot": z32,
        "logsBloom": format!("0x{}", "0".repeat(512)), "difficulty": "0x0",
        "number": format!("{n:#x}"), "gasLimit": "0x1c9c380", "gasUsed": "0xe4e1c0",
        "timestamp": "0x64", "extraData": "0x", "mixHash": z32, "nonce": "0x0000000000000000",
        "baseFeePerGas": "0x2540be400", "size": "0x1", "uncles": [], "transactions": []
    })
}

struct Seq(AtomicUsize);
impl Respond for Seq {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let id: Value = serde_json::from_slice::<Value>(&req.body).unwrap()["id"].clone();
        let i = self.0.fetch_add(1, Ordering::SeqCst);
        let n = [10, 10, 9, 11].get(i).copied().unwrap_or(11);
        ResponseTemplate::new(200).set_body_json(json!({"jsonrpc":"2.0","id":id,"result":block(n)}))
    }
}

#[tokio::test]
async fn test_polling_dedups_and_is_monotonic() {
    let srv = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(Seq(AtomicUsize::new(0)))
        .mount(&srv)
        .await;
    let s = monotonic(poll_heads(
        srv.uri().parse().unwrap(),
        Duration::from_millis(20),
    ));
    let got: Vec<_> = tokio::time::timeout(Duration::from_secs(5), s.take(2).collect::<Vec<_>>())
        .await
        .unwrap();
    assert_eq!(got.iter().map(|h| h.number).collect::<Vec<_>>(), [10, 11]);
    assert_eq!(got[0].base_fee, 10_000_000_000);
    assert_eq!(got[0].gas_limit, 30_000_000);
}

/// Answers poll i with `nums[i]`, then counts up from the last one.
struct Nums(Vec<u64>, AtomicUsize);
impl Respond for Nums {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let id: Value = serde_json::from_slice::<Value>(&req.body).unwrap()["id"].clone();
        let i = self.1.fetch_add(1, Ordering::SeqCst);
        let last = *self.0.last().unwrap();
        let n = self
            .0
            .get(i)
            .copied()
            .unwrap_or(last + (i + 1 - self.0.len()) as u64);
        ResponseTemplate::new(200).set_body_json(json!({"jsonrpc":"2.0","id":id,"result":block(n)}))
    }
}

async fn http_nums(nums: &[u64]) -> MockServer {
    let srv = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(Nums(nums.to_vec(), AtomicUsize::new(0)))
        .mount(&srv)
        .await;
    srv
}

fn timers(idle_ms: u64, retry_ms: u64, connect_ms: u64) -> WsTimers {
    WsTimers {
        idle: Duration::from_millis(idle_ms),
        retry: Duration::from_millis(retry_ms),
        connect: Duration::from_millis(connect_ms),
    }
}

/// One WS connection: answers `eth_subscribe`, pushes head `n`, then drops the connection
/// (no close frame).
async fn ws_conn(tcp: tokio::net::TcpStream, n: u64) {
    use tokio_tungstenite::tungstenite::Message;
    let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else {
        return;
    };
    while let Some(Ok(m)) = ws.next().await {
        let Message::Text(t) = m else { continue };
        let v: Value = serde_json::from_str(&t).unwrap();
        if v["method"] == "eth_subscribe" {
            let ack = json!({"jsonrpc":"2.0","id":v["id"],"result":"0x1"});
            let head = json!({"jsonrpc":"2.0","method":"eth_subscription",
                "params":{"subscription":"0x1","result":block(n)}});
            let _ = ws.send(Message::Text(ack.to_string().into())).await;
            // the head lands on a live subscription, then the node dies
            tokio::time::sleep(Duration::from_millis(100)).await;
            let _ = ws.send(Message::Text(head.to_string().into())).await;
            tokio::time::sleep(Duration::from_millis(100)).await;
            return;
        }
    }
}

/// A WS node that serves one connection (head `n`), then refuses every reconnect.
async fn ws_once(n: u64) -> url::Url {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    tokio::spawn(async move {
        let (tcp, _) = l.accept().await.unwrap();
        drop(l);
        ws_conn(tcp, n).await;
    });
    format!("ws://{addr}").parse().unwrap()
}

/// Polling serves head 1 while the WS connects; the WS delivers 5 and drops; polling serves
/// 6, 7 after the idle timeout.
#[tokio::test]
async fn test_ws_drop_falls_back_to_polling() {
    let http = http_nums(&[1, 6]).await;
    let s = ws_heads(
        ws_once(5).await,
        http.uri().parse().unwrap(),
        timers(300, 30_000, 5_000),
    );
    let got: Vec<_> = tokio::time::timeout(
        Duration::from_secs(10),
        s.take_while(|h| futures::future::ready(h.number <= 7))
            .map(|h| h.number)
            .collect::<Vec<_>>(),
    )
    .await
    .expect("heads keep coming after the WS drop");
    assert!(got.ends_with(&[5, 6, 7]), "{got:?}");
}

#[tokio::test]
async fn test_ws_unreachable_polls() {
    let http = http_nums(&[20]).await;
    // nothing listens on port 1
    let s = ws_heads(
        "ws://127.0.0.1:1".parse().unwrap(),
        http.uri().parse().unwrap(),
        timers(300, 30_000, 5_000),
    );
    let got: Vec<_> = tokio::time::timeout(Duration::from_secs(10), s.take(2).collect::<Vec<_>>())
        .await
        .expect("polling serves heads while WS is down");
    assert_eq!(got.iter().map(|h| h.number).collect::<Vec<_>>(), [20, 21]);
}

/// A black-holed WS (TCP accepted, no handshake ever) at startup and again at the retry:
/// polling keeps serving heads every poll interval the whole time, never one connect
/// timeout late.
#[tokio::test]
async fn test_blackholed_ws_never_stalls_polling() {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let ws: url::Url = format!("ws://{}", l.local_addr().unwrap()).parse().unwrap();
    tokio::spawn(async move {
        let mut held = vec![];
        loop {
            held.push(l.accept().await.unwrap().0);
        }
    });
    let http = http_nums(&[1]).await;
    // connect 1.5 s: start-up attempt to 1.5 s, polling alone to 2.0 s, retry to 3.5 s
    let s = ws_heads(ws, http.uri().parse().unwrap(), timers(300, 500, 1_500));
    let mut s = std::pin::pin!(s);
    let t0 = tokio::time::Instant::now();
    let mut at = vec![t0];
    while let Ok(Some(_)) = tokio::time::timeout_at(t0 + Duration::from_secs(4), s.next()).await {
        at.push(tokio::time::Instant::now());
    }
    let gap = at.windows(2).map(|w| w[1] - w[0]).max().unwrap();
    assert!(at.len() > 7, "{} heads", at.len() - 1);
    assert!(gap < Duration::from_millis(800), "longest gap {gap:?}");
}

/// After the retry interval of polling, the bot goes back to a WS node that came back.
#[tokio::test]
async fn test_polling_returns_to_ws_after_retry_interval() {
    let http = http_nums(&[1, 6]).await;
    let ws = ws_once(5).await;
    let addr = format!("{}:{}", ws.host_str().unwrap(), ws.port().unwrap());
    // the node is back on the same port 600 ms later, serving head 100 on every connection
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(600)).await;
        let l = tokio::net::TcpListener::bind(addr).await.unwrap();
        loop {
            let (tcp, _) = l.accept().await.unwrap();
            tokio::spawn(ws_conn(tcp, 100));
        }
    });
    let s = ws_heads(ws, http.uri().parse().unwrap(), timers(300, 1_000, 5_000));
    let mut s = std::pin::pin!(s);
    let mut got = vec![];
    tokio::time::timeout(Duration::from_secs(10), async {
        while let Some(h) = s.next().await {
            got.push(h.number);
            if h.number == 100 {
                break;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("never back on the WS: {got:?}"));
    let pos = |n: u64| got.iter().position(|x| *x == n);
    assert!(
        pos(5).is_some() && pos(5) < pos(6),
        "WS, then polling: {got:?}"
    );
    assert_eq!(got.last(), Some(&100));
    assert!(got.windows(2).all(|w| w[0] < w[1]), "monotonic: {got:?}");
}

/// A WS node that counts TCP connections and serves every one like `ws_conn` (head `n`),
/// except that it keeps the connection open after the head.
async fn ws_counting(n: u64) -> (url::Url, std::sync::Arc<AtomicUsize>) {
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = l.local_addr().unwrap();
    let count = std::sync::Arc::new(AtomicUsize::new(0));
    let c = count.clone();
    tokio::spawn(async move {
        loop {
            let (tcp, _) = l.accept().await.unwrap();
            c.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(ws_conn_open(tcp, n));
        }
    });
    (format!("ws://{addr}").parse().unwrap(), count)
}

async fn ws_conn_open(tcp: tokio::net::TcpStream, n: u64) {
    use tokio_tungstenite::tungstenite::Message;
    let Ok(mut ws) = tokio_tungstenite::accept_async(tcp).await else {
        return;
    };
    while let Some(Ok(m)) = ws.next().await {
        let Message::Text(t) = m else { continue };
        let v: Value = serde_json::from_str(&t).unwrap();
        if v["method"] == "eth_subscribe" {
            let ack = json!({"jsonrpc":"2.0","id":v["id"],"result":"0x1"});
            let head = json!({"jsonrpc":"2.0","method":"eth_subscription",
                "params":{"subscription":"0x1","result":block(n)}});
            let _ = ws.send(Message::Text(ack.to_string().into())).await;
            let _ = ws.send(Message::Text(head.to_string().into())).await;
        }
    }
}

/// One WS head attempt opens exactly one WebSocket connection.
#[tokio::test]
async fn test_one_ws_connection_per_attempt() {
    let http = http_nums(&[1]).await;
    let (ws, count) = ws_counting(5).await;
    let s = ws_heads(
        ws,
        http.uri().parse().unwrap(),
        timers(5_000, 30_000, 5_000),
    );
    let got: Vec<_> = tokio::time::timeout(
        Duration::from_secs(10),
        s.take_while(|h| futures::future::ready(h.number < 5))
            .map(|h| h.number)
            .collect::<Vec<_>>(),
    )
    .await
    .expect("the WS head arrives");
    assert!(!got.is_empty());
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert_eq!(count.load(Ordering::SeqCst), 1);
}

/// Same, when the node drops the connection after the head: alloy must not reconnect behind
/// the bot's back.
#[tokio::test]
async fn test_no_hidden_ws_reconnect_after_drop() {
    let http = http_nums(&[1]).await;
    let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let ws: url::Url = format!("ws://{}", l.local_addr().unwrap()).parse().unwrap();
    let count = std::sync::Arc::new(AtomicUsize::new(0));
    let c = count.clone();
    tokio::spawn(async move {
        loop {
            let (tcp, _) = l.accept().await.unwrap();
            c.fetch_add(1, Ordering::SeqCst);
            tokio::spawn(ws_conn(tcp, 5));
        }
    });
    let mut s = std::pin::pin!(ws_heads(
        ws,
        http.uri().parse().unwrap(),
        timers(300, 30_000, 5_000)
    ));
    // WS head 5, then the drop, then polling alone for the 30 s retry window
    let _ = tokio::time::timeout(Duration::from_secs(3), async {
        while let Some(h) = s.next().await {
            if h.number == 5 {
                break;
            }
        }
    })
    .await;
    let _ = tokio::time::timeout(Duration::from_secs(2), s.next()).await;
    assert_eq!(count.load(Ordering::SeqCst), 1);
}

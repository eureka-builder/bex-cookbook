use alloy::signers::local::PrivateKeySigner;
use bex_backrun::config::BotConfig;
use bex_backrun::cycles::{Cycle, Leg};
use bex_backrun::head::Head;
use bex_backrun::run::{run, run_until};
use bex_backrun::store::MemStore;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::{Duration, Instant};
use wiremock::{matchers::method, Mock, MockServer, Request, Respond, ResponseTemplate};

fn cfg(endpoints: &[String], pending_cap: usize, delay_ms: u64) -> BotConfig {
    cfg_with(endpoints, pending_cap, delay_ms, "")
}

/// `cfg` plus raw toml lines.
fn cfg_with(endpoints: &[String], pending_cap: usize, delay_ms: u64, extra: &str) -> BotConfig {
    let eps = endpoints
        .iter()
        .map(|e| format!("\"{e}\""))
        .collect::<Vec<_>>()
        .join(",");
    toml::from_str(&format!(
        "endpoints = [{eps}]\nrpc_http = \"http://localhost:2\"\n\
         solver = \"0x1111111111111111111111111111111111111111\"\n\
         executor = \"0x2222222222222222222222222222222222222222\"\n\
         weth = \"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\"\n\
         pending_cap = {pending_cap}\nsend_delay_ms = {delay_ms}\n{extra}\n"
    ))
    .unwrap()
}

fn cycles(n: usize) -> Vec<Cycle> {
    let leg = |i: u8, o: u8| Leg {
        version: 3,
        token_in: alloy::primitives::Address::repeat_byte(i),
        token_out: alloy::primitives::Address::repeat_byte(o),
        fee: 500,
        tick_spacing: 10,
    };
    (0..n)
        .map(|i| Cycle {
            name: format!("c{i}"),
            legs: vec![leg(0, 0xaa), leg(0xaa, 0)],
        })
        .collect()
}

fn head(n: u64) -> Head {
    Head {
        number: n,
        base_fee: 1_000_000_000,
        gas_used: 15_000_000,
        gas_limit: 30_000_000,
        timestamp: 0,
    }
}

fn ok_body() -> Value {
    json!({"jsonrpc":"2.0","id":1,"result":{"bundleHash": format!("0x{}", "ab".repeat(32))}})
}

async fn server(delay: Option<Duration>) -> MockServer {
    let s = MockServer::start().await;
    let mut t = ResponseTemplate::new(200).set_body_json(ok_body());
    if let Some(d) = delay {
        t = t.set_delay(d);
    }
    Mock::given(method("POST")).respond_with(t).mount(&s).await;
    s
}

async fn bodies(s: &MockServer) -> Vec<Value> {
    s.received_requests()
        .await
        .unwrap()
        .iter()
        .map(|r| serde_json::from_slice(&r.body).unwrap())
        .collect()
}

fn signer() -> PrivateKeySigner {
    PrivateKeySigner::random()
}

fn heads(hs: Vec<(u64, u64)>) -> impl futures::Stream<Item = Head> {
    async_stream::stream! {
        for (n, wait_ms) in hs {
            tokio::time::sleep(Duration::from_millis(wait_ms)).await;
            yield head(n);
        }
    }
}

#[tokio::test]
async fn test_sends_one_request_per_cycle_per_head_to_every_endpoint() {
    let (a, b) = (server(None).await, server(None).await);
    let cfg = cfg(&[a.uri(), b.uri()], 256, 0);
    let store = Arc::new(MemStore::default());
    let key = signer();
    run(
        &cfg,
        &cycles(3),
        key.clone(),
        heads(vec![(10, 0)]),
        store.clone(),
    )
    .await
    .unwrap();
    for s in [&a, &b] {
        let bs = bodies(s).await;
        assert_eq!(bs.len(), 3);
        let req = |v: &Value| v["params"][0].clone();
        let mut uuids: Vec<_> = bs
            .iter()
            .map(|v| req(v)["replacementUuid"].as_str().unwrap().to_string())
            .collect();
        uuids.sort();
        uuids.dedup();
        assert_eq!(uuids.len(), 3);
        assert!(bs.iter().all(|v| v["method"] == "bex_sendBundle"));
        assert!(bs.iter().all(|v| req(v)["targetBlock"] == 11));
        for r in s.received_requests().await.unwrap() {
            let h = r
                .headers
                .get("x-flashbots-signature")
                .unwrap()
                .to_str()
                .unwrap();
            let (addr, sig) = h.split_once(':').unwrap();
            let digest = format!("{:#x}", alloy::primitives::keccak256(&r.body));
            let sig: alloy::primitives::Signature = sig.parse().unwrap();
            let rec = sig.recover_address_from_msg(digest.as_bytes()).unwrap();
            assert_eq!(rec.to_string(), addr);
            assert_eq!(rec, key.address());
        }
    }
    let recs = store.records();
    assert_eq!(recs.len(), 6);
    assert!(recs
        .iter()
        .all(|r| r.target_block == 11 && r.outcome.is_ok()));
}

/// A 2 s answer is inside the 3 s default timeout: one request, no retry, success.
#[tokio::test]
async fn test_default_send_timeout_allows_a_two_second_answer() {
    let slow = server(Some(Duration::from_secs(2))).await;
    let cfg = cfg(&[slow.uri()], 256, 0);
    let store = Arc::new(MemStore::default());
    run(
        &cfg,
        &cycles(1),
        signer(),
        heads(vec![(10, 0)]),
        store.clone(),
    )
    .await
    .unwrap();
    assert_eq!(bodies(&slow).await.len(), 1);
    assert!(store.records().iter().all(|r| r.outcome.is_ok()));
}

/// `send_timeout_ms` is honoured and named in the error.
#[tokio::test]
async fn test_send_timeout_ms_is_configurable() {
    let slow = server(Some(Duration::from_secs(2))).await;
    let cfg = cfg_with(&[slow.uri()], 256, 0, "send_timeout_ms = 300");
    let store = Arc::new(MemStore::default());
    run(
        &cfg,
        &cycles(1),
        signer(),
        heads(vec![(10, 0)]),
        store.clone(),
    )
    .await
    .unwrap();
    let recs = store.records();
    let err = recs[0].outcome.as_ref().unwrap_err();
    assert!(err.contains("timeout after 300 ms"), "{err}");
}

#[tokio::test]
async fn test_slow_endpoint_does_not_delay_others() {
    let slow = server(Some(Duration::from_secs(5))).await;
    let fast = server(None).await;
    let cfg = cfg(&[slow.uri(), fast.uri()], 256, 0);
    let store = Arc::new(MemStore::default());
    let t0 = Instant::now();
    run(
        &cfg,
        &cycles(1),
        signer(),
        heads(vec![(10, 0), (11, 100)]),
        store.clone(),
    )
    .await
    .unwrap();
    // the fast endpoint got both heads; the run ended on the 3 s timeout plus one retry
    // of the last head (about 6.2 s), not the 5 s hang twice over
    assert_eq!(bodies(&fast).await.len(), 2);
    assert!(
        t0.elapsed() < Duration::from_millis(7_500),
        "{:?}",
        t0.elapsed()
    );
    let recs = store.records();
    assert!(recs
        .iter()
        .any(|r| r.endpoint.as_str().starts_with(&slow.uri()) && r.outcome.is_err()));
}

async fn targets(s: &MockServer) -> Vec<u64> {
    bodies(s)
        .await
        .iter()
        .map(|v| v["params"][0]["targetBlock"].as_u64().unwrap())
        .collect()
}

#[tokio::test]
async fn test_newer_head_supersedes_inflight_batch() {
    // Head 11 arrives while batch 11 is still waiting out send_delay_ms: its sends
    // are cut and recorded `superseded`; only target 12 is ever POSTed.
    let s = server(None).await;
    let cfg = cfg(&[s.uri()], 256, 200);
    let store = Arc::new(MemStore::default());
    run(
        &cfg,
        &cycles(2),
        signer(),
        heads(vec![(10, 0), (11, 10)]),
        store.clone(),
    )
    .await
    .unwrap();
    assert_eq!(targets(&s).await, vec![12, 12]);
    let recs = store.records();
    assert_eq!(recs.len(), 4, "{recs:?}");
    let sup = |t: u64| {
        recs.iter()
            .filter(|r| r.target_block == t && r.outcome == Err("superseded".to_string()))
            .count()
    };
    assert_eq!((sup(11), sup(12)), (2, 0));
}

#[tokio::test]
async fn test_inflight_sends_finish_and_record_after_newer_head() {
    // Delay 0, slow responses: batch 11 is genuinely in flight when head 11 lands.
    let s = server(Some(Duration::from_millis(300))).await;
    let cfg = cfg(&[s.uri()], 256, 0);
    let store = Arc::new(MemStore::default());
    run(
        &cfg,
        &cycles(2),
        signer(),
        heads(vec![(10, 0), (11, 100)]),
        store.clone(),
    )
    .await
    .unwrap();
    // wiremock keeps arrival order: no target-11 POST after the first target-12 POST
    assert_eq!(targets(&s).await, vec![11, 11, 12, 12]);
    let recs = store.records();
    assert_eq!(recs.len(), 4);
    assert!(recs.iter().all(|r| r.outcome.is_ok()), "{recs:?}");
}

#[tokio::test]
async fn test_select_all_refuses_when_cycles_exceed_budget() {
    let s = server(None).await;
    let cfg = cfg_with(&[s.uri()], 2, 0, "select = \"all\"");
    let store = Arc::new(MemStore::default());
    let e = run(&cfg, &cycles(3), signer(), heads(vec![(10, 0)]), store)
        .await
        .unwrap_err()
        .to_string();
    assert!(e.contains("pending_cap"), "{e}");
    assert!(bodies(&s).await.is_empty());
}

/// `select = "top"` (the default): the first `pending_budget()` cycles in file order, the
/// same set for every head (a set that churned would replace live requests).
#[tokio::test]
async fn test_select_top_sends_first_k_cycles_every_head() {
    let s = server(None).await;
    let cfg = cfg(&[s.uri()], 4, 0);
    let k = cfg.pending_budget();
    assert!((1..6).contains(&k), "{k}");
    let store = Arc::new(MemStore::default());
    run(
        &cfg,
        &cycles(6),
        signer(),
        heads(vec![(10, 0), (11, 50)]),
        store.clone(),
    )
    .await
    .unwrap();
    let want: Vec<String> = (0..k).map(|i| format!("c{i}")).collect();
    for t in [11, 12] {
        let mut got: Vec<String> = store
            .records()
            .iter()
            .filter(|r| r.target_block == t)
            .map(|r| r.cycle.clone())
            .collect();
        got.sort();
        assert_eq!(got, want, "target {t}");
    }
    assert_eq!(bodies(&s).await.len(), 2 * k);
}

/// Per cycle: parity mode sends different uuids for consecutive targets, cycle mode one uuid.
#[tokio::test]
async fn test_uuid_mode_across_consecutive_targets() {
    for (extra, distinct) in [("uuid_mode = \"parity\"", 2), ("", 1)] {
        let s = server(None).await;
        let cfg = cfg_with(&[s.uri()], 8, 0, extra);
        run(
            &cfg,
            &cycles(1),
            signer(),
            heads(vec![(10, 0), (11, 50), (12, 50)]),
            Arc::new(MemStore::default()),
        )
        .await
        .unwrap();
        let bs = bodies(&s).await;
        let req = |i: usize| bs[i]["params"][0].clone();
        assert_eq!(bs.len(), 3, "{extra}");
        let uuids: std::collections::HashSet<_> = (0..3)
            .map(|i| req(i)["replacementUuid"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(uuids.len(), distinct, "{extra}");
        // 11 and 13 share a parity: the newer one replaces the older (seq = target)
        assert_eq!(req(0)["replacementUuid"], req(2)["replacementUuid"]);
        assert_eq!(req(2)["replacementSeqNumber"], 13);
    }
}

/// Two targets in flight in parity mode: budget = floor(pending_cap / 2), and 0 refuses.
#[tokio::test]
async fn test_parity_budget_is_half_pending_cap() {
    let s = server(None).await;
    let parity = "uuid_mode = \"parity\"";
    assert_eq!(cfg_with(&[s.uri()], 9, 0, parity).pending_budget(), 4);
    assert_eq!(cfg(&[s.uri()], 9, 0).pending_budget(), 9);
    let e = run(
        &cfg_with(&[s.uri()], 1, 0, parity),
        &cycles(1),
        signer(),
        heads(vec![(10, 0)]),
        Arc::new(MemStore::default()),
    )
    .await
    .unwrap_err()
    .to_string();
    assert!(e.contains("pending budget is 0"), "{e}");
    assert!(bodies(&s).await.is_empty());
}

#[tokio::test]
async fn test_transport_error_recorded_whole_without_url() {
    // nothing listens on port 1
    let cfg = cfg(&["http://127.0.0.1:1/secret-token".to_string()], 8, 0);
    let store = Arc::new(MemStore::default());
    run(
        &cfg,
        &cycles(1),
        signer(),
        heads(vec![(10, 0)]),
        store.clone(),
    )
    .await
    .unwrap();
    let recs = store.records();
    let e = recs[0].outcome.as_ref().unwrap_err();
    assert!(e.starts_with("transport: "), "{e}");
    assert!(e.len() > "transport: ".len() + 10, "the cause is kept: {e}");
    assert!(!e.contains("secret-token"), "{e}");
}

#[tokio::test]
async fn test_stop_drains_inflight_sends_and_records_all() {
    let s = server(Some(Duration::from_millis(300))).await;
    let cfg = cfg(&[s.uri()], 256, 0);
    let store = Arc::new(MemStore::default());
    // head 10, then silence: the only way out of the loop is `stop`
    let hs = async_stream::stream! {
        yield head(10);
        std::future::pending::<()>().await;
    };
    tokio::time::timeout(
        Duration::from_secs(5),
        run_until(
            &cfg,
            &cycles(3),
            signer(),
            hs,
            store.clone(),
            tokio::time::sleep(Duration::from_millis(50)),
        ),
    )
    .await
    .expect("stop path must end the run")
    .unwrap();
    let recs = store.records();
    assert_eq!(recs.len(), 3, "{recs:?}");
    assert!(recs.iter().all(|r| r.outcome.is_ok()), "{recs:?}");
}

#[tokio::test]
async fn test_run_stops_on_unadmitted_signer() {
    let s = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"jsonrpc":"2.0","id":1,
            "error": {"code": -32001, "message": "method bex_sendBundle access rejected. If you need access to this endpoint, contact us at t.me/EurekaBuilder"}})))
        .mount(&s)
        .await;
    let cfg = cfg(&[s.uri()], 8, 0);
    let key = signer();
    // one head, then nothing for a long time: the refusal alone must end the run
    let hs = futures::StreamExt::chain(heads(vec![(10, 0)]), futures::stream::pending());
    let t = Instant::now();
    let e = tokio::time::timeout(
        Duration::from_secs(5),
        run(
            &cfg,
            &cycles(2),
            key.clone(),
            hs,
            Arc::new(MemStore::default()),
        ),
    )
    .await
    .expect("run stops at once")
    .unwrap_err()
    .to_string();
    assert!(t.elapsed() < Duration::from_secs(2));
    assert!(
        e.contains(&key.address().to_string()) && e.contains("not admitted for BEX"),
        "{e}"
    );
    assert!(
        e.contains("t.me/EurekaBuilder"),
        "the builder's contact stays: {e}"
    );
}

/// The first `slow` POSTs hang past the 3,000 ms timeout; the rest answer at once.
struct SlowFirst(std::sync::atomic::AtomicUsize, usize);
impl Respond for SlowFirst {
    fn respond(&self, _: &Request) -> ResponseTemplate {
        let t = ResponseTemplate::new(200).set_body_json(ok_body());
        if self.0.fetch_add(1, std::sync::atomic::Ordering::SeqCst) < self.1 {
            t.set_delay(Duration::from_secs(4))
        } else {
            t
        }
    }
}

async fn slow_first(n: usize) -> MockServer {
    let s = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(SlowFirst(Default::default(), n))
        .mount(&s)
        .await;
    s
}

/// A timed-out send is retried once with the same bytes and signature (same uuid and seq:
/// the builder drops a duplicate), and the record counts the retry.
#[tokio::test]
async fn test_timeout_retried_once_with_same_body() {
    let s = slow_first(1).await;
    let cfg = cfg(&[s.uri()], 8, 0);
    let store = Arc::new(MemStore::default());
    run(
        &cfg,
        &cycles(1),
        signer(),
        heads(vec![(10, 0)]),
        store.clone(),
    )
    .await
    .unwrap();
    let reqs = s.received_requests().await.unwrap();
    assert_eq!(reqs.len(), 2);
    assert_eq!(reqs[0].body, reqs[1].body);
    assert_eq!(
        reqs[0].headers.get("x-flashbots-signature"),
        reqs[1].headers.get("x-flashbots-signature")
    );
    let recs = store.records();
    assert_eq!(recs.len(), 1, "{recs:?}");
    assert!(recs[0].outcome.is_ok(), "{recs:?}");
    assert_eq!(recs[0].retries, 1);
}

/// A JSON-RPC error is the builder's answer, not a lost request: never retried.
#[tokio::test]
async fn test_rpc_error_not_retried() {
    let s = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(
                json!({"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"bad"}}),
            ),
        )
        .mount(&s)
        .await;
    let store = Arc::new(MemStore::default());
    run(
        &cfg(&[s.uri()], 8, 0),
        &cycles(1),
        signer(),
        heads(vec![(10, 0)]),
        store.clone(),
    )
    .await
    .unwrap();
    assert_eq!(bodies(&s).await.len(), 1);
    let recs = store.records();
    assert_eq!(recs[0].retries, 0);
    assert!(recs[0].outcome.is_err());
}

/// No retry once a newer head arrived (the target block is no longer the next one); the
/// record keeps the timeout, not `superseded`. The newest target is retried once, only once.
#[tokio::test]
async fn test_no_retry_after_newer_head() {
    let s = slow_first(usize::MAX).await;
    let store = Arc::new(MemStore::default());
    run(
        &cfg(&[s.uri()], 8, 0),
        &cycles(1),
        signer(),
        heads(vec![(10, 0), (11, 100)]),
        store.clone(),
    )
    .await
    .unwrap();
    let ts = targets(&s).await;
    assert_eq!(ts.iter().filter(|t| **t == 11).count(), 1, "{ts:?}");
    assert_eq!(ts.iter().filter(|t| **t == 12).count(), 2, "{ts:?}");
    let recs = store.records();
    let rec = |t: u64| recs.iter().find(|r| r.target_block == t).unwrap();
    assert_eq!(rec(11).retries, 0);
    assert!(
        rec(11).outcome.as_ref().unwrap_err().starts_with("timeout"),
        "{recs:?}"
    );
    assert_eq!(rec(12).retries, 1);
    assert!(
        rec(12).outcome.as_ref().unwrap_err().starts_with("timeout"),
        "{recs:?}"
    );
}

/// `select = "all"` compares GROUPS to the budget: 3 cycles over a shared pool are one group.
#[tokio::test]
async fn test_select_all_counts_groups_and_sends_one_request_per_group() {
    use bex_backrun::run::select_groups;
    let s = server(None).await;
    let one = cfg_with(&[s.uri()], 2, 0, "select = \"all\"");
    assert!(select_groups(&one, &cycles(3)).is_err());
    let cfg = cfg_with(&[s.uri()], 2, 0, "select = \"all\"\ngroup_size = 4");
    let gs = select_groups(&cfg, &cycles(3)).unwrap();
    assert_eq!(gs.len(), 1);
    assert_eq!(gs[0].name, "c0+3");
    let store = Arc::new(MemStore::default());
    run(
        &cfg,
        &cycles(3),
        signer(),
        heads(vec![(10, 0)]),
        store.clone(),
    )
    .await
    .unwrap();
    let recs = store.records();
    assert_eq!(recs.len(), 1);
    assert_eq!(recs[0].cycle, "c0+3");
    let b = bodies(&s).await;
    assert_eq!(b.len(), 1);
    let cd = b[0]["params"][0]["bex"]["compute"]["calldata"]
        .as_str()
        .unwrap();
    assert!(cd.starts_with("0x12d924e5"), "solveMany selector: {cd}");
}

/// `request_copies` counts against the budget: pending_cap 8, copies 2 -> 4 groups, 8 requests
/// per head, copy k >= 1 named `<group>#k`.
#[tokio::test]
async fn test_request_copies_split_the_budget() {
    use bex_backrun::run::select_groups;
    let s = server(None).await;
    let mut cfg = cfg_with(&[s.uri()], 8, 0, "request_copies = 2");
    cfg.solver = alloy::primitives::Address::ZERO;
    cfg.solver_code_bytes = Some(alloy::primitives::Bytes::from_static(&[0x60, 0x01]));
    let gs = select_groups(&cfg, &cycles(6)).unwrap();
    assert_eq!(gs.len(), 4);
    let all = cfg_with(&[s.uri()], 8, 0, "request_copies = 2\nselect = \"all\"");
    assert!(select_groups(&all, &cycles(5)).is_err());
    assert_eq!(select_groups(&all, &cycles(4)).unwrap().len(), 4);
    let store = Arc::new(MemStore::default());
    run(
        &cfg,
        &cycles(6),
        signer(),
        heads(vec![(10, 0)]),
        store.clone(),
    )
    .await
    .unwrap();
    let mut got: Vec<String> = store.records().iter().map(|r| r.cycle.clone()).collect();
    got.sort();
    let mut want: Vec<String> = (0..4)
        .flat_map(|i| [format!("c{i}"), format!("c{i}#1")])
        .collect();
    want.sort();
    assert_eq!(got, want);
    let b = bodies(&s).await;
    let targets: std::collections::HashSet<_> = b
        .iter()
        .map(|v| {
            v["params"][0]["bex"]["compute"]["to"]
                .as_str()
                .unwrap()
                .to_string()
        })
        .collect();
    assert_eq!(targets.len(), 8, "one code target per copy");
}

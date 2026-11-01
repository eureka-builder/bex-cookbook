use alloy::primitives::{Address, B256, U256};
use alloy::sol_types::{SolCall, SolEvent};
use bex_backrun::abi::{ICycleExecutor::CycleExecuted, ICycleSolver, Plan};
use bex_backrun::config::BotConfig;
use bex_backrun::cycles::{Cycle, Leg};
use bex_backrun::request::cycle_id;
use bex_backrun::status::{probe, status};
use bex_backrun::store::{Record, SqliteStore, Store};
use bex_backrun::track::{track_head, LAST_SCANNED};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use url::Url;
use wiremock::{matchers::method, Mock, MockServer, Request, Respond, ResponseTemplate};

const HASH: &str = "0x00000000000000000000000000000000000000000000000000000000000000aa";
/// A builder endpoint no test calls.
const BUILDER: &str = "http://localhost:1";

fn cfg(builder: &str, el: &str) -> BotConfig {
    toml::from_str(&format!(
        "endpoints = [\"{builder}/secrettoken\"]\nrpc_http = \"{el}\"\n\
         solver = \"0x1111111111111111111111111111111111111111\"\n\
         executor = \"0x2222222222222222222222222222222222222222\"\n\
         weth = \"0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2\"\n"
    ))
    .unwrap()
}

fn cycle(name: &str, tok: u8) -> Cycle {
    let leg = |i: u8, o: u8| Leg {
        version: 3,
        token_in: Address::repeat_byte(i),
        token_out: Address::repeat_byte(o),
        fee: 500,
        tick_spacing: 10,
    };
    Cycle {
        name: name.into(),
        legs: vec![leg(0, tok), leg(tok, 0)],
    }
}

fn tmp_store(name: &str) -> SqliteStore {
    let p = std::env::temp_dir().join(format!("bex-track-{}-{name}.sqlite", std::process::id()));
    let _ = std::fs::remove_file(&p);
    SqliteStore::open(&p).unwrap()
}

fn send(store: &SqliteStore, block: u64, cycle: &str, ep: &str, hash: &str) {
    store.record(Record {
        target_block: block,
        cycle: cycle.into(),
        endpoint: Url::parse(ep).unwrap(),
        outcome: Ok(hash.into()),
        retries: 0,
    });
}

async fn mock(s: &MockServer, r: impl Respond + 'static) {
    Mock::given(method("POST")).respond_with(r).mount(s).await;
}

fn ok(result: Value) -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(json!({"jsonrpc":"2.0","id":1,"result":result}))
}

/// Our tag: `request::tag` of signer 0x..aa.
const TAG: B256 = B256::with_last_byte(0xaa);

/// EL mock: one `CycleExecuted` log at block 10 (hash 0x..b1) carrying `tag`, whatever the
/// filter asked (a node that ignores topics); `getBlockByNumber` answers `chain_hash`.
struct El {
    cycle_id: B256,
    chain_hash: &'static str,
    tag: B256,
}
const LOGGED: &str = "0x00000000000000000000000000000000000000000000000000000000000000b1";
const OTHER: &str = "0x00000000000000000000000000000000000000000000000000000000000000b2";
impl Respond for El {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let b: Value = serde_json::from_slice(&req.body).unwrap();
        match b["method"].as_str().unwrap() {
            "eth_getLogs" => {
                assert_eq!(
                    b["params"][0]["topics"],
                    json!([CycleExecuted::SIGNATURE_HASH, null, TAG]),
                    "the filter asks for our tag only"
                );
                let ev = CycleExecuted {
                    cycleId: self.cycle_id,
                    tag: self.tag,
                    amountIn: U256::from(100u64),
                    profit: U256::from(7u64),
                    paidToCoinbase: U256::from(3u64),
                };
                ok(json!([{
                    "address": "0x2222222222222222222222222222222222222222",
                    "topics": [CycleExecuted::SIGNATURE_HASH, self.cycle_id, self.tag],
                    "data": alloy::hex::encode_prefixed(ev.encode_data()),
                    "blockNumber": "0xa", "blockHash": LOGGED,
                    "transactionHash": "0x00000000000000000000000000000000000000000000000000000000000000c1",
                    "transactionIndex": "0x0", "logIndex": "0x0", "removed": false
                }]))
            }
            "eth_getBlockByNumber" => ok(json!({"hash": self.chain_hash, "number": "0xa"})),
            m => panic!("unexpected {m}"),
        }
    }
}

async fn landed_after(chain_hash: &'static str, name: &str) -> (Option<i64>, u64) {
    landed_with_tag(chain_hash, name, TAG).await
}

/// `(canonical, landed_final)` after heads 10 and 12, for a log carrying `tag`.
async fn landed_with_tag(chain_hash: &'static str, name: &str, tag: B256) -> (Option<i64>, u64) {
    let el = MockServer::start().await;
    let cycles = vec![cycle("c0", 0xaa)];
    mock(
        &el,
        El {
            cycle_id: cycle_id(&cycles[0].legs),
            chain_hash,
            tag,
        },
    )
    .await;
    let cfg = cfg(BUILDER, &el.uri());
    let store = tmp_store(name);
    let client = reqwest::Client::new();
    track_head(&cfg, &client, &store, 10, TAG).await; // landing seen
    if tag != TAG {
        let n: i64 = store
            .with(|c| c.query_row("SELECT COUNT(*) FROM landing", [], |r| r.get(0)))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(n, 0, "another sender's log is not a landing");
        track_head(&cfg, &client, &store, 12, TAG).await;
        return (
            None,
            status(&store, &cycles, 100).await.unwrap()[0].counts[2],
        );
    }
    let after_seen: Option<i64> = store
        .with(|c| c.query_row("SELECT canonical FROM landing", [], |r| r.get(0)))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(after_seen, None, "unchecked before 2 blocks have passed");
    track_head(&cfg, &client, &store, 12, TAG).await; // 2 blocks later
    let canonical = store
        .with(|c| c.query_row("SELECT canonical FROM landing", [], |r| r.get(0)))
        .await
        .unwrap()
        .unwrap();
    let rows = status(&store, &cycles, 100).await.unwrap();
    (canonical, rows[0].counts[2])
}

#[tokio::test]
async fn test_landing_marked_canonical_only_when_hash_matches() {
    assert_eq!(landed_after(OTHER, "reorg").await, (Some(0), 0));
    assert_eq!(landed_after(LOGGED, "canon").await, (Some(1), 1));
}

/// The shared executor logs every sender's cycles: only our tag is a landing.
#[tokio::test]
async fn test_landing_with_another_tag_is_ignored() {
    let other = B256::with_last_byte(0xbb);
    assert_eq!(landed_with_tag(LOGGED, "other-tag", other).await, (None, 0));
    assert_eq!(landed_with_tag(LOGGED, "our-tag", TAG).await, (Some(1), 1));
}

#[tokio::test]
async fn test_status_table_counts() {
    let store = tmp_store("table");
    let cycles = vec![cycle("c0", 0xaa), cycle("c1", 0xbb)];
    let ep = "http://builder.example:80";
    let h = |n: u8| format!("0x{n:064x}");
    for (n, c) in [(1, "c0"), (2, "c0"), (3, "c0"), (4, "c1")] {
        send(&store, 100, c, ep, &h(n));
    }
    let id0 = format!("{:#x}", cycle_id(&cycles[0].legs));
    store
        .with(move |c| {
            // one final, one provisional, one reorged, one unchecked
            for (n, canon, depth) in [
                (1, Some(1), Some(12)),
                (4, Some(1), Some(2)),
                (2, Some(0), None),
                (3, None, None),
            ] {
                c.execute(
                    "INSERT INTO landing VALUES (100, ?, ?, ?, '1', '1', '1', ?, ?)",
                    (format!("0xb{n}"), format!("0xc{n}"), &id0, canon, depth),
                )
                .unwrap();
            }
        })
        .await
        .unwrap();
    let rows = status(&store, &cycles, 100).await.unwrap();
    // sent, landed_final, landed_provisional
    assert_eq!(rows[0].counts, [3, 1, 1]);
    assert_eq!(rows[1].counts, [1, 0, 0]);
    assert!(bex_backrun::status::format_table(&rows).contains("c1"));
}

/// A group name in `sent.cycle` gets its own row after the loaded cycles.
#[tokio::test]
async fn test_status_lists_group_names_from_sent() {
    let store = tmp_store("groups");
    let cycles = vec![cycle("c0", 0xaa), cycle("c1", 0xbb)];
    let ep = "http://builder.example:80";
    send(&store, 100, "c0+2", ep, &format!("0x{:064x}", 1));
    send(&store, 100, "c0+2", ep, &format!("0x{:064x}", 2));
    let rows = status(&store, &cycles, 100).await.unwrap();
    let names: Vec<&str> = rows.iter().map(|r| r.cycle.as_str()).collect();
    assert_eq!(names, ["c0", "c1", "c0+2"]);
    assert_eq!(rows[2].counts[0], 2);
    assert_eq!(rows[0].counts[0], 0);
}

#[tokio::test]
async fn test_probe_decodes_plan_or_selector() {
    const SELECTORS: [&str; 2] = ["0xe39aafee", "0xdeadbeef0000"]; // NoProfit(), unknown
    struct Calls(AtomicUsize);
    impl Respond for Calls {
        fn respond(&self, req: &Request) -> ResponseTemplate {
            let b: Value = serde_json::from_slice(&req.body).unwrap();
            assert_eq!(b["method"], "eth_call");
            assert_eq!(b["params"][1], "latest");
            let data = b["params"][0]["data"].as_str().unwrap();
            assert!(data.starts_with(&alloy::hex::encode_prefixed(
                ICycleSolver::solveCall::SELECTOR
            )));
            let n = self.0.fetch_add(1, Ordering::SeqCst);
            if n == 0 {
                let plan = Plan {
                    amountIn: U256::from(100u64),
                    amountOut: U256::from(130u64),
                    minProfit: U256::ZERO,
                    builderShareBps: 10_000,
                    recipient: Address::ZERO,
                    tag: B256::ZERO,
                    legs: vec![],
                };
                ok(json!(alloy::hex::encode_prefixed(
                    ICycleSolver::solveCall::abi_encode_returns(&plan)
                )))
            } else {
                ResponseTemplate::new(200).set_body_json(json!({"jsonrpc":"2.0","id":1,
                    "error": {"code": 3, "message": "execution reverted", "data": SELECTORS[n - 1]}}))
            }
        }
    }
    let el = MockServer::start().await;
    mock(&el, Calls(AtomicUsize::new(0))).await;
    let cfg = cfg(BUILDER, &el.uri());
    let out = probe(
        &cfg,
        &[cycle("c0", 0xaa), cycle("c1", 0xbb), cycle("c2", 0xcc)],
    )
    .await;
    assert_eq!(
        out,
        vec![
            ("c0".to_string(), "profit 30".to_string()),
            ("c1".to_string(), "revert NoProfit (0xe39aafee)".to_string()),
            ("c2".to_string(), "revert 0xdeadbeef".to_string())
        ]
    );
}

/// EL mock: records `eth_getLogs` ranges, answers `[]`, or a 500 while `fail` is set.
struct Logs {
    ranges: Arc<Mutex<Vec<(u64, u64)>>>,
    fail: Arc<AtomicBool>,
}
impl Respond for Logs {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let b: Value = serde_json::from_slice(&req.body).unwrap();
        assert_eq!(b["method"], "eth_getLogs");
        let n = |k: &str| {
            u64::from_str_radix(
                b["params"][0][k].as_str().unwrap().trim_start_matches("0x"),
                16,
            )
            .unwrap()
        };
        self.ranges
            .lock()
            .unwrap()
            .push((n("fromBlock"), n("toBlock")));
        if self.fail.load(Ordering::SeqCst) {
            ResponseTemplate::new(500)
        } else {
            ok(json!([]))
        }
    }
}

#[tokio::test]
async fn test_landing_cursor_advances_only_on_success_and_fills_gaps() {
    let el = MockServer::start().await;
    let (ranges, fail) = (
        Arc::new(Mutex::new(vec![])),
        Arc::new(AtomicBool::new(false)),
    );
    mock(
        &el,
        Logs {
            ranges: ranges.clone(),
            fail: fail.clone(),
        },
    )
    .await;
    let cfg = cfg(BUILDER, &el.uri());
    let store = tmp_store("cursor");
    let client = reqwest::Client::new();
    let cursor = || async {
        store
            .with(|c| {
                c.query_row(
                    "SELECT value FROM meta WHERE key = ?",
                    [LAST_SCANNED],
                    |r| r.get::<_, i64>(0),
                )
            })
            .await
            .unwrap()
            .unwrap()
    };
    track_head(&cfg, &client, &store, 10, TAG).await; // first head: the recent window
    assert_eq!(cursor().await, 10);
    fail.store(true, Ordering::SeqCst);
    track_head(&cfg, &client, &store, 11, TAG).await;
    assert_eq!(cursor().await, 10, "a failed scan does not move the cursor");
    fail.store(false, Ordering::SeqCst);
    track_head(&cfg, &client, &store, 15, TAG).await; // heads 12..14 skipped
    assert_eq!(cursor().await, 15);
    track_head(&cfg, &client, &store, 260, TAG).await; // far behind: 100-block chunks
    assert_eq!(cursor().await, 260);
    assert_eq!(
        *ranges.lock().unwrap(),
        vec![
            (8, 10),
            (9, 11),
            (11, 15),
            (16, 115),
            (116, 215),
            (216, 260)
        ]
    );
}

#[tokio::test]
async fn test_first_failing_scans_leave_a_lower_bound_cursor() {
    let el = MockServer::start().await;
    let (ranges, fail) = (
        Arc::new(Mutex::new(vec![])),
        Arc::new(AtomicBool::new(true)),
    );
    mock(
        &el,
        Logs {
            ranges: ranges.clone(),
            fail: fail.clone(),
        },
    )
    .await;
    let cfg = cfg(BUILDER, &el.uri());
    let store = tmp_store("lower-bound");
    let client = reqwest::Client::new();
    for h in [100, 101, 102] {
        track_head(&cfg, &client, &store, h, TAG).await;
    }
    fail.store(false, Ordering::SeqCst);
    track_head(&cfg, &client, &store, 103, TAG).await;
    let r = ranges.lock().unwrap().clone();
    assert_eq!(r.last(), Some(&(98, 103)), "{r:?}");
}

#[tokio::test]
async fn test_cursor_seed_from_old_sends_is_capped_at_1000_blocks() {
    let el = MockServer::start().await;
    let ranges = Arc::new(Mutex::new(vec![]));
    mock(
        &el,
        Logs {
            ranges: ranges.clone(),
            fail: Arc::new(AtomicBool::new(false)),
        },
    )
    .await;
    let cfg = cfg(BUILDER, &el.uri());
    let store = tmp_store("seed-cap");
    send(&store, 5_000, "c", "http://e:1", HASH); // far older than head - 1000
    track_head(&cfg, &reqwest::Client::new(), &store, 10_000, TAG).await;
    assert_eq!(ranges.lock().unwrap().first(), Some(&(9_001, 9_100)));
}

#[tokio::test]
async fn test_cursor_seed_from_recent_send_starts_before_it() {
    let el = MockServer::start().await;
    let ranges = Arc::new(Mutex::new(vec![]));
    mock(
        &el,
        Logs {
            ranges: ranges.clone(),
            fail: Arc::new(AtomicBool::new(false)),
        },
    )
    .await;
    let cfg = cfg(BUILDER, &el.uri());
    let store = tmp_store("seed-recent");
    send(&store, 9_900, "c", "http://e:1", HASH);
    track_head(&cfg, &reqwest::Client::new(), &store, 10_000, TAG).await;
    assert_eq!(ranges.lock().unwrap().first(), Some(&(9_899, 9_998)));
}

/// EL mock whose block 10 hash is switchable: logs at 10 (hash b1) always, chain hash `hash`.
struct Switch(Arc<Mutex<&'static str>>, B256);
impl Respond for Switch {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        El {
            cycle_id: self.1,
            chain_hash: *self.0.lock().unwrap(),
            tag: TAG,
        }
        .respond(req)
    }
}

#[tokio::test]
async fn test_landing_reorged_after_depth_2_is_unwound_at_depth_12() {
    let el = MockServer::start().await;
    let cycles = vec![cycle("c0", 0xaa)];
    let chain = Arc::new(Mutex::new(LOGGED));
    mock(&el, Switch(chain.clone(), cycle_id(&cycles[0].legs))).await;
    let cfg = cfg(BUILDER, &el.uri());
    let store = tmp_store("deep-reorg");
    let client = reqwest::Client::new();
    track_head(&cfg, &client, &store, 10, TAG).await;
    track_head(&cfg, &client, &store, 12, TAG).await; // provisional
    assert_eq!(state(&store).await, (Some(1), Some(2), 12));
    let r = status(&store, &cycles, 100).await.unwrap();
    assert_eq!((r[0].counts[1], r[0].counts[2]), (0, 1), "provisional only");
    track_head(&cfg, &client, &store, 21, TAG).await; // depth 11: no re-check yet
    assert_eq!(state(&store).await.1, Some(2));
    *chain.lock().unwrap() = OTHER; // reorg before depth 12
    track_head(&cfg, &client, &store, 22, TAG).await;
    assert_eq!(
        state(&store).await,
        (Some(0), None, 9),
        "cursor at block - 1"
    );
    let r = status(&store, &cycles, 100).await.unwrap();
    assert_eq!(
        (r[0].counts[1], r[0].counts[2]),
        (0, 0),
        "not counted at all"
    );
}

#[tokio::test]
async fn test_landing_still_canonical_at_depth_12_is_final() {
    let el = MockServer::start().await;
    let cycles = vec![cycle("c0", 0xaa)];
    mock(
        &el,
        Switch(Arc::new(Mutex::new(LOGGED)), cycle_id(&cycles[0].legs)),
    )
    .await;
    let cfg = cfg(BUILDER, &el.uri());
    let store = tmp_store("final");
    let client = reqwest::Client::new();
    for h in [10, 12, 22] {
        track_head(&cfg, &client, &store, h, TAG).await;
    }
    let r = status(&store, &cycles, 100).await.unwrap();
    assert_eq!((r[0].counts[1], r[0].counts[2]), (1, 0));
}

/// `(canonical, confirmed_depth, cursor)` of the only landing.
async fn state(s: &SqliteStore) -> (Option<i64>, Option<i64>, i64) {
    s.with(|c| {
        c.query_row(
            "SELECT canonical, confirmed_depth, (SELECT value FROM meta WHERE key = ?) FROM landing",
            [LAST_SCANNED],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
    })
    .await
    .unwrap()
    .unwrap()
}

/// `sent.retries` is stored.
#[tokio::test]
async fn test_sent_retries_column() {
    let p = std::env::temp_dir().join(format!("bex-track-{}-retries.sqlite", std::process::id()));
    let _ = std::fs::remove_file(&p);
    let store = SqliteStore::open(&p).unwrap();
    store.record(Record {
        target_block: 2,
        cycle: "new".into(),
        endpoint: Url::parse("http://h:1").unwrap(),
        outcome: Err("timeout after 1500 ms".into()),
        retries: 1,
    });
    let rows: Vec<(String, i64)> = store
        .with(|c| {
            c.prepare("SELECT cycle, retries FROM sent ORDER BY block")
                .unwrap()
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
                .map(Result::unwrap)
                .collect()
        })
        .await
        .unwrap();
    assert_eq!(rows, vec![("new".into(), 1)]);
}

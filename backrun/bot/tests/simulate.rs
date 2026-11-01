use alloy::primitives::{Address, B256, U256};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol_types::SolCall;
use bex_backrun::abi::{ICycleExecutor, ICycleSolver, Plan, Venues};
use bex_backrun::config::BotConfig;
use bex_backrun::cycles::{Cycle, Leg};
use bex_backrun::head::Head;
use bex_backrun::simulate::simulate;
use bex_backrun::startup::check_venues;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use wiremock::{matchers::method, Mock, MockServer, Request, Respond, ResponseTemplate};

struct Seq(AtomicUsize);
impl Respond for Seq {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let body: Value = serde_json::from_slice(&req.body).unwrap();
        assert_eq!(body["method"], "bex_simulate");
        let plan = Plan {
            amountIn: U256::from(100u64),
            amountOut: U256::from(130u64),
            minProfit: U256::ZERO,
            builderShareBps: 10_000,
            recipient: Address::ZERO,
            tag: B256::ZERO,
            legs: vec![],
        };
        let ret = alloy::hex::encode_prefixed(ICycleSolver::solveCall::abi_encode_returns(&plan));
        let result = match self.0.fetch_add(1, Ordering::SeqCst) {
            0 => json!({"accepted": true, "issues": [],
                "compute": {"returnData": ret, "gasUsed": 1, "readSetSize": 1},
                "execute": {"calldata": "0x", "gasUsed": 1, "coinbaseProfitWei": "0x1"}}),
            1 | 3 => json!({"accepted": false, "issues": ["Compute reverted"]}),
            _ => json!({"accepted": false, "issues": ["Execute reverted", "nonce"]}),
        };
        ResponseTemplate::new(200).set_body_json(json!({"jsonrpc":"2.0","id":1,"result":result}))
    }
}

const WETH: &str = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2";

/// EL mock: `venues()` answers WETH `weth`; the n-th `solve` reverts with `solve_reverts[n]`.
struct El {
    weth: Address,
    /// The executor's `poolManager` (the solver's is zero).
    exec_pm: Address,
    solve_reverts: Vec<&'static str>,
    n: AtomicUsize,
}
impl Respond for El {
    fn respond(&self, req: &Request) -> ResponseTemplate {
        let b: Value = serde_json::from_slice(&req.body).unwrap();
        assert_eq!(b["method"], "eth_call");
        let data = b["params"][0]["data"].as_str().unwrap();
        let rpc = |v: Value| ResponseTemplate::new(200).set_body_json(v);
        if data == alloy::hex::encode_prefixed(ICycleExecutor::venuesCall::SELECTOR) {
            let v = Venues {
                v2Factory: Address::ZERO,
                v2InitHash: B256::ZERO,
                v3Factory: Address::ZERO,
                v3InitHash: B256::ZERO,
                poolManager: if b["params"][0]["to"]
                    .as_str()
                    .unwrap()
                    .ends_with("2222222222222222222222222222222222222222")
                {
                    self.exec_pm
                } else {
                    Address::ZERO
                },
                weth: self.weth,
            };
            let ret =
                alloy::hex::encode_prefixed(ICycleExecutor::venuesCall::abi_encode_returns(&v));
            return rpc(json!({"jsonrpc":"2.0","id":1,"result": ret}));
        }
        assert!(data.starts_with(&alloy::hex::encode_prefixed(
            ICycleSolver::solveCall::SELECTOR
        )));
        let sel = self.solve_reverts[self.n.fetch_add(1, Ordering::SeqCst)];
        rpc(json!({"jsonrpc":"2.0","id":1,
            "error": {"code": 3, "message": "execution reverted", "data": sel}}))
    }
}

async fn el(weth: Address, solve_reverts: Vec<&'static str>) -> MockServer {
    el_pm(weth, Address::ZERO, solve_reverts).await
}

async fn el_pm(weth: Address, exec_pm: Address, solve_reverts: Vec<&'static str>) -> MockServer {
    let s = MockServer::start().await;
    let r = El {
        weth,
        exec_pm,
        solve_reverts,
        n: AtomicUsize::new(0),
    };
    Mock::given(method("POST")).respond_with(r).mount(&s).await;
    s
}

fn cfg(endpoint: &str, rpc: &str) -> BotConfig {
    toml::from_str(&format!(
        "endpoints = [\"{endpoint}\"]\nrpc_http = \"{rpc}\"\n\
         solver = \"0x1111111111111111111111111111111111111111\"\n\
         executor = \"0x2222222222222222222222222222222222222222\"\n\
         weth = \"{WETH}\"\n"
    ))
    .unwrap()
}

#[tokio::test]
async fn test_simulate_classifies_outcomes() {
    let s = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(Seq(AtomicUsize::new(0)))
        .mount(&s)
        .await;
    // rows 1 and 3 are "Compute reverted": solve at latest says NoProfit, then BadLeg
    let el = el(WETH.parse().unwrap(), vec!["0xe39aafee", "0xd49a7cf2"]).await;
    let cfg = cfg(&s.uri(), &el.uri());
    let leg = |i: u8, o: u8| Leg {
        version: 3,
        token_in: Address::repeat_byte(i),
        token_out: Address::repeat_byte(o),
        fee: 500,
        tick_spacing: 10,
    };
    let cycles: Vec<Cycle> = (0..4)
        .map(|i| Cycle {
            name: format!("c{i}"),
            legs: vec![leg(0, 0xaa), leg(0xaa, 0)],
        })
        .collect();
    let head = Head {
        number: 5,
        base_fee: 1,
        gas_used: 0,
        gas_limit: 30_000_000,
        timestamp: 0,
    };
    let v = simulate(
        &cfg,
        &cycles,
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        &head,
        false,
    )
    .await
    .unwrap();
    // accepted; NoProfit -> no-profit; Execute reverted -> failed; BadLeg -> failed
    assert_eq!((v.accepted, v.no_profit, v.failed), (1, 1, 2));
    assert!(!v.ok());
}

#[tokio::test]
async fn test_simulate_no_profit_only_exits_ok() {
    struct Reverted;
    impl Respond for Reverted {
        fn respond(&self, _: &Request) -> ResponseTemplate {
            ResponseTemplate::new(200).set_body_json(json!({"jsonrpc":"2.0","id":1,
                "result": {"accepted": false, "issues": ["Compute reverted"]}}))
        }
    }
    let s = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(Reverted)
        .mount(&s)
        .await;
    let el = el(WETH.parse().unwrap(), vec!["0xe39aafee"]).await;
    let cfg = cfg(&s.uri(), &el.uri());
    let leg = |i: u8, o: u8| Leg {
        version: 3,
        token_in: Address::repeat_byte(i),
        token_out: Address::repeat_byte(o),
        fee: 500,
        tick_spacing: 10,
    };
    let c = Cycle {
        name: "c0".into(),
        legs: vec![leg(0, 0xaa), leg(0xaa, 0)],
    };
    let head = Head {
        number: 5,
        base_fee: 1,
        gas_used: 0,
        gas_limit: 30_000_000,
        timestamp: 0,
    };
    let v = simulate(
        &cfg,
        &[c],
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        &head,
        false,
    )
    .await
    .unwrap();
    assert_eq!((v.accepted, v.no_profit, v.failed), (0, 1, 0));
    assert!(v.ok());
}

#[tokio::test]
async fn test_check_venues_fails_fast_on_mismatch() {
    let good = el(WETH.parse().unwrap(), vec![]).await;
    check_venues(&cfg("http://localhost:1", &good.uri()), None)
        .await
        .unwrap();
    let bad = el(Address::repeat_byte(0x5f), vec![]).await;
    let e = check_venues(&cfg("http://localhost:1", &bad.uri()), None)
        .await
        .unwrap_err()
        .to_string();
    assert!(e.contains("solver") && e.contains("WETH"), "{e}");
}

#[tokio::test]
async fn test_check_venues_fails_on_differing_pool_manager() {
    let split = el_pm(WETH.parse().unwrap(), Address::repeat_byte(0x77), vec![]).await;
    let e = check_venues(&cfg("http://localhost:1", &split.uri()), None)
        .await
        .unwrap_err()
        .to_string();
    assert!(e.contains("poolManager"), "{e}");
}

// ---- code mode, builder refusals and the stack's simulate limits ----

use alloy::primitives::Bytes;
use bex_backrun::request::code_target;
use std::sync::{Arc, Mutex};

fn code_cfg(endpoint: &str, rpc: &str) -> BotConfig {
    let mut c = cfg(endpoint, rpc);
    c.solver = Address::ZERO;
    c.solver_code_bytes = Some(Bytes::from(vec![0x60, 0x01]));
    c
}

/// A block without transactions, gas used at the target (the next basefee equals `base_fee`).
fn header(number: &Value, base_fee: &str) -> Value {
    let z32 = format!("0x{}", "0".repeat(64));
    json!({
        "hash": z32, "parentHash": z32, "sha3Uncles": z32, "miner": format!("0x{}", "0".repeat(40)),
        "stateRoot": z32, "transactionsRoot": z32, "receiptsRoot": z32,
        "logsBloom": format!("0x{}", "0".repeat(512)), "difficulty": "0x0", "number": number,
        "gasLimit": "0x1c9c380", "gasUsed": "0xe4e1c0", "timestamp": "0x64", "extraData": "0x",
        "mixHash": z32, "nonce": "0x0000000000000000", "baseFeePerGas": base_fee,
        "size": "0x1", "uncles": [], "transactions": []
    })
}

fn rpc_ok(v: Value) -> ResponseTemplate {
    ResponseTemplate::new(200).set_body_json(json!({"jsonrpc":"2.0","id":1,"result": v}))
}

fn venues_ret(weth: Address) -> String {
    alloy::hex::encode_prefixed(ICycleExecutor::venuesCall::abi_encode_returns(&Venues {
        v2Factory: Address::ZERO,
        v2InitHash: B256::ZERO,
        v3Factory: Address::ZERO,
        v3InitHash: B256::ZERO,
        poolManager: Address::ZERO,
        weth,
    }))
}

/// EL mock for code mode: per-method answers; every request body is kept.
async fn code_el(
    code: &'static str,
    nonce: &'static str,
    balance: &'static str,
) -> (MockServer, Arc<Mutex<Vec<Value>>>) {
    let seen = Arc::new(Mutex::new(vec![]));
    let s = MockServer::start().await;
    let log = seen.clone();
    Mock::given(method("POST"))
        .respond_with(move |req: &Request| {
            let b: Value = serde_json::from_slice(&req.body).unwrap();
            log.lock().unwrap().push(b.clone());
            match b["method"].as_str().unwrap() {
                "eth_getCode" => rpc_ok(json!(code)),
                "eth_getTransactionCount" => rpc_ok(json!(nonce)),
                "eth_getBalance" => rpc_ok(json!(balance)),
                "eth_call" => rpc_ok(json!(venues_ret(WETH.parse().unwrap()))),
                m => panic!("unexpected {m}"),
            }
        })
        .mount(&s)
        .await;
    (s, seen)
}

#[tokio::test]
async fn test_check_venues_code_mode_installs_code_by_state_override() {
    let (s, seen) = code_el("0x", "0x0", "0x0").await;
    check_venues(&code_cfg("http://localhost:1", &s.uri()), None)
        .await
        .unwrap();
    let calls = seen.lock().unwrap().clone();
    let solver = &calls[0]["params"];
    let to = solver[0]["to"].as_str().unwrap();
    assert_eq!(solver[2][to]["code"], "0x6001", "{solver}");
    let executor = &calls[1]["params"];
    assert_eq!(
        executor[0]["to"],
        "0x2222222222222222222222222222222222222222"
    );
    assert!(
        executor.get(2).is_none(),
        "the executor is a deployed contract"
    );
    // --override-code with executor_code: the executor's venues() runs on its code too
    let code = Bytes::from(vec![0x60, 0x02]);
    check_venues(&code_cfg("http://localhost:1", &s.uri()), Some(&code))
        .await
        .unwrap();
    let executor = seen.lock().unwrap()[3]["params"].clone();
    assert_eq!(
        executor[2]["0x2222222222222222222222222222222222222222"]["code"],
        "0x6002"
    );
}

fn one_cycle() -> Vec<Cycle> {
    let leg = |i: u8, o: u8| Leg {
        version: 3,
        token_in: Address::repeat_byte(i),
        token_out: Address::repeat_byte(o),
        fee: 500,
        tick_spacing: 10,
    };
    vec![Cycle {
        name: "c0".into(),
        legs: vec![leg(0, 0xaa), leg(0xaa, 0)],
    }]
}

fn head5() -> Head {
    Head {
        number: 5,
        base_fee: 1,
        gas_used: 0,
        gas_limit: 30_000_000,
        timestamp: 0,
    }
}

/// Builder mock answering every call with `answers[n]` (the last one repeats).
async fn builder(answers: Vec<Value>) -> (MockServer, Arc<Mutex<Vec<Value>>>) {
    let seen = Arc::new(Mutex::new(vec![]));
    let s = MockServer::start().await;
    let log = seen.clone();
    Mock::given(method("POST"))
        .respond_with(move |req: &Request| {
            let b: Value = serde_json::from_slice(&req.body).unwrap();
            let mut l = log.lock().unwrap();
            l.push(b);
            let a = answers[(l.len() - 1).min(answers.len() - 1)].clone();
            ResponseTemplate::new(200).set_body_json(a)
        })
        .mount(&s)
        .await;
    (s, seen)
}

fn rpc_err(code: i64, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":1,"error":{"code":code,"message":message}})
}

#[tokio::test]
async fn test_simulate_names_compute_code_refusal() {
    let (b, seen) = builder(vec![rpc_err(
        -32602,
        "compute.code is not enabled on this builder",
    )])
    .await;
    let cfg = code_cfg(&b.uri(), "http://localhost:9");
    let v = simulate(
        &cfg,
        &one_cycle(),
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        &head5(),
        false,
    )
    .await
    .unwrap();
    assert_eq!((v.accepted, v.no_profit, v.failed), (0, 0, 1));
    let issues = &v.rows[0].issues;
    assert!(
        issues.contains("builder refuses compute.code") && issues.contains("-32602"),
        "{issues}"
    );
    let body = &seen.lock().unwrap()[0];
    assert_eq!(body["params"][0]["bex"]["compute"]["code"], "0x6001");
}

#[tokio::test]
async fn test_simulate_retries_busy_with_backoff() {
    let busy = rpc_err(-32005, "bex_simulate is busy, retry");
    let ok = json!({"jsonrpc":"2.0","id":1,"result": {"accepted": false, "issues": ["Execute reverted", "x"]}});
    let (b, seen) = builder(vec![busy.clone(), busy.clone(), ok]).await;
    let cfg = cfg(&b.uri(), "http://localhost:9");
    let t = std::time::Instant::now();
    let v = simulate(
        &cfg,
        &one_cycle(),
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        &head5(),
        false,
    )
    .await
    .unwrap();
    assert_eq!(v.rows[0].retries, 2);
    assert_eq!(seen.lock().unwrap().len(), 3);
    assert!(
        t.elapsed() >= std::time::Duration::from_millis(300),
        "100 + 200 ms backoff"
    );
    assert!(bex_backrun::simulate::format_row(&v.rows[0]).contains("busy retries 2"));
    // always busy: 5 tries, then the row fails with the busy error
    let (b, seen) = builder(vec![busy]).await;
    let cfg = cfg_at(&b.uri());
    let v = simulate(
        &cfg,
        &one_cycle(),
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        &head5(),
        false,
    )
    .await
    .unwrap();
    assert_eq!(seen.lock().unwrap().len(), 5);
    assert_eq!((v.failed, v.rows[0].retries), (1, 4));
    assert!(v.rows[0].issues.contains("busy"));
}

fn cfg_at(endpoint: &str) -> BotConfig {
    cfg(endpoint, "http://localhost:9")
}

#[tokio::test]
async fn test_simulate_uses_builder_revert_data() {
    // NoProfit in compute.revertData: no solve-at-latest probe (the EL is unreachable)
    let (b, _) = builder(vec![
        json!({"jsonrpc":"2.0","id":1, "result": {"accepted": false,
        "issues": ["Compute reverted"], "compute": {"gasUsed": 5, "revertData": "0xe39aafee"}}}),
    ])
    .await;
    let cfg = cfg_at(&b.uri());
    let v = simulate(
        &cfg,
        &one_cycle(),
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        &head5(),
        false,
    )
    .await
    .unwrap();
    assert_eq!((v.no_profit, v.failed), (1, 0));
    assert_eq!(v.rows[0].revert_data.as_deref(), Some("0xe39aafee"));
    assert!(bex_backrun::simulate::format_row(&v.rows[0]).contains("NoProfit"));
    // BadLeg is a failure
    let (b, _) = builder(vec![
        json!({"jsonrpc":"2.0","id":1, "result": {"accepted": false,
        "issues": ["Compute reverted"], "compute": {"gasUsed": 5, "revertData": "0xd49a7cf2"}}}),
    ])
    .await;
    let cfg = cfg_at(&b.uri());
    let v = simulate(
        &cfg,
        &one_cycle(),
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        &head5(),
        false,
    )
    .await
    .unwrap();
    assert_eq!((v.no_profit, v.failed), (0, 1));
    assert!(v.rows[0].issues.contains("BadLeg"), "{:?}", v.rows[0]);
}

#[tokio::test]
async fn test_simulate_stops_on_unadmitted_signer() {
    let (b, seen) = builder(vec![rpc_err(
        -32001,
        "method bex_simulate access rejected. If you need access to this endpoint, contact us at t.me/EurekaBuilder",
    )])
    .await;
    let cfg = cfg_at(&b.uri());
    let signer = PrivateKeySigner::random();
    let mut cycles = one_cycle();
    cycles.push(cycles[0].clone());
    let e = simulate(&cfg, &cycles, &cfg.endpoints[0], &signer, &head5(), false)
        .await
        .unwrap_err()
        .to_string();
    assert!(
        e.contains(&signer.address().to_string()) && e.contains("not admitted for BEX"),
        "{e}"
    );
    assert!(e.contains("ask the builder operator"), "{e}");
    assert!(
        e.contains("t.me/EurekaBuilder"),
        "the builder's contact stays: {e}"
    );
    assert_eq!(seen.lock().unwrap().len(), 1, "stops at the first request");
}

// ---- override-simulate (evaluation without a deploy) ----

use bex_backrun::simulate::{append_csv, repeat, Repeat, CSV_HEADER};

fn accepted_answer() -> Value {
    accepted_answer_with_floor(U256::ZERO)
}

/// An accepted answer whose plan carries `min_profit` (the floor the solver applied).
fn accepted_answer_with_floor(min_profit: U256) -> Value {
    let plan = Plan {
        amountIn: U256::from(100u64),
        amountOut: U256::from(130u64),
        minProfit: min_profit,
        builderShareBps: 10_000,
        recipient: Address::ZERO,
        tag: B256::ZERO,
        legs: vec![],
    };
    let ret = alloy::hex::encode_prefixed(ICycleSolver::solveCall::abi_encode_returns(&plan));
    json!({"jsonrpc":"2.0","id":1,"result": {"accepted": true, "issues": [],
        "compute": {"returnData": ret, "gasUsed": 4_000_000, "readSetSize": 9},
        "execute": {"calldata": "0x", "gasUsed": 1_200_000, "coinbaseProfitWei": "30"}}})
}

#[tokio::test]
async fn test_override_code_sends_state_overrides_not_compute_code() {
    let (b, seen) = builder(vec![accepted_answer()]).await;
    let mut cfg = code_cfg(&b.uri(), "http://localhost:9");
    cfg.executor_code_bytes = Some(Bytes::from(vec![0x60, 0x02]));
    let signer = PrivateKeySigner::random();
    let v = simulate(
        &cfg,
        &one_cycle(),
        &cfg.endpoints[0],
        &signer,
        &head5(),
        true,
    )
    .await
    .unwrap();
    assert_eq!(v.accepted, 1);
    let body = seen.lock().unwrap()[0].clone();
    let req = &body["params"][0];
    assert!(req["bex"]["compute"].get("code").is_none(), "{req}");
    let to = format!("{:#x}", code_target(signer.address(), "c0", 6));
    assert_eq!(req["bex"]["compute"]["to"], to.as_str());
    let o = req["stateOverrides"].as_object().unwrap();
    assert_eq!(o.len(), 2);
    assert_eq!(o[&to]["code"], "0x6001");
    assert_eq!(
        o["0x2222222222222222222222222222222222222222"]["code"],
        "0x6002"
    );
    // the row carries the gas and the coinbase profit
    let r = &v.rows[0];
    assert_eq!(
        (r.compute_gas, r.execute_gas),
        (Some(4_000_000), Some(1_200_000))
    );
    assert_eq!(r.coinbase_profit.as_deref(), Some("30"));
    // without executor_code only the solver is overridden; without solver_code it is refused
    cfg.executor_code_bytes = None;
    simulate(
        &cfg,
        &one_cycle(),
        &cfg.endpoints[0],
        &signer,
        &head5(),
        true,
    )
    .await
    .unwrap();
    let o = seen.lock().unwrap()[1]["params"][0]["stateOverrides"].clone();
    assert_eq!(o.as_object().unwrap().len(), 1);
    let e = simulate(
        &cfg_at(&b.uri()),
        &one_cycle(),
        &cfg.endpoints[0],
        &signer,
        &head5(),
        true,
    )
    .await
    .unwrap_err()
    .to_string();
    assert!(e.contains("solver_code"), "{e}");
}

#[tokio::test]
async fn test_repeat_every_k_heads_appends_csv() {
    let (b, seen) = builder(vec![accepted_answer()]).await;
    let cfg = code_cfg(&b.uri(), "http://localhost:9");
    let out = std::env::temp_dir().join(format!("bex-repeat-{}.csv", std::process::id()));
    let _ = std::fs::remove_file(&out);
    let heads: Vec<Head> = [5u64, 6, 6, 7, 8, 9, 10]
        .iter()
        .map(|&n| Head {
            number: n,
            ..head5()
        })
        .collect();
    let opts = Repeat {
        override_code: true,
        runs: 3,
        every: 2,
        out: Some(out.clone()),
    };
    let v = repeat(
        &cfg,
        &one_cycle(),
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        futures::stream::iter(heads),
        &opts,
    )
    .await
    .unwrap();
    assert_eq!(v.accepted, 3);
    let targets: Vec<Value> = seen
        .lock()
        .unwrap()
        .iter()
        .map(|b| b["params"][0]["targetBlock"].clone())
        .collect();
    assert_eq!(
        targets,
        vec![json!(6), json!(8), json!(10)],
        "heads 5, 7, 9"
    );
    let csv = std::fs::read_to_string(&out).unwrap();
    let lines: Vec<&str> = csv.lines().collect();
    assert_eq!(lines[0], CSV_HEADER);
    assert!(!CSV_HEADER.contains("gas_estimate"), "{CSV_HEADER}");
    assert_eq!(lines.len(), 4);
    let cols: Vec<&str> = CSV_HEADER.split(',').collect();
    let row: Vec<&str> = lines[1].split(',').collect();
    assert_eq!(row.len(), cols.len());
    let col = |name: &str| row[cols.iter().position(|c| *c == name).unwrap()];
    assert_eq!(col("head"), "5");
    assert_eq!(col("cycle"), "c0");
    assert_eq!(col("compute_gas"), "4000000");
    assert_eq!(col("execute_gas"), "1200000");
    assert_eq!(col("coinbase_profit_wei"), "30");
    assert_eq!(col("profit"), "30");
    // a second session appends, with no second header
    append_csv(&out, &head5(), &v.rows).unwrap();
    assert_eq!(
        std::fs::read_to_string(&out)
            .unwrap()
            .matches("head,target_block")
            .count(),
        1
    );
}

#[test]
fn test_csv_quotes_issues() {
    let out = std::env::temp_dir().join(format!("bex-quote-{}.csv", std::process::id()));
    let _ = std::fs::remove_file(&out);
    let row = bex_backrun::simulate::Row {
        cycle: "c0".into(),
        status: "rejected",
        amount_in: None,
        amount_out: None,
        compute_gas: None,
        execute_gas: None,
        coinbase_profit: None,
        target_block: 6,
        snapshot_block: None,
        floor_wei: None,
        retries: 0,
        revert_data: None,
        issues: r#"rpc error: {"code":-32602,"message":"x"}"#.into(),
    };
    append_csv(&out, &head5(), &[row]).unwrap();
    let csv = std::fs::read_to_string(&out).unwrap();
    assert!(
        csv.lines()
            .nth(1)
            .unwrap()
            .ends_with(r#","rpc error: {""code"":-32602,""message"":""x""}""#),
        "{csv}"
    );
}

#[tokio::test]
async fn test_simulate_paces_builder_calls() {
    let (b, seen) = builder(vec![accepted_answer()]).await;
    let cfg = cfg_at(&b.uri());
    let cycles: Vec<Cycle> = (0..4).map(|_| one_cycle()[0].clone()).collect();
    let t = std::time::Instant::now();
    simulate(
        &cfg,
        &cycles,
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        &head5(),
        false,
    )
    .await
    .unwrap();
    assert_eq!(seen.lock().unwrap().len(), 4);
    // 5 per second: the 4th call starts no sooner than 600 ms after the 1st
    assert!(
        t.elapsed() >= std::time::Duration::from_millis(600),
        "{:?}",
        t.elapsed()
    );
}

// ---- fix round 1: capability gate, startup, retry pacing, snapshot block ----

use bex_backrun::startup::{check, check_compute_code};
use std::time::Instant;

fn caps(v: Value) -> Value {
    json!({"jsonrpc":"2.0","id":1,"result": v})
}

#[tokio::test]
async fn test_capability_gate() {
    let signer = PrivateKeySigner::random();
    // the stack with the flag on, code fits
    let (ok, seen) = builder(vec![caps(
        json!({"maxCalldataBytes": 1, "computeCodeEnabled": true,
        "maxComputeCodeBytes": 24576}),
    )])
    .await;
    let cfg = code_cfg(&ok.uri(), "http://localhost:9");
    check_compute_code(&cfg, &signer, &cfg.endpoints)
        .await
        .unwrap();
    assert_eq!(seen.lock().unwrap()[0]["method"], "bex_capabilities");
    for (answer, want) in [
        // develop: no field at all
        (
            json!({"maxCalldataBytes": 1, "maxComputeGas": 1, "maxExecuteGas": 1}),
            "computeCodeEnabled absent",
        ),
        (
            json!({"computeCodeEnabled": false, "maxComputeCodeBytes": 24576}),
            "computeCodeEnabled false",
        ),
        // the code is 2 bytes
        (
            json!({"computeCodeEnabled": true, "maxComputeCodeBytes": 1}),
            "up to 1 bytes",
        ),
    ] {
        let (b, _) = builder(vec![caps(answer)]).await;
        let cfg = code_cfg(&b.uri(), "http://localhost:9");
        let e = check_compute_code(&cfg, &signer, &cfg.endpoints)
            .await
            .unwrap_err()
            .to_string();
        let host = b.uri().trim_start_matches("http://").to_string();
        assert!(e.contains(want) && e.contains(&host), "{want}: {e}");
    }
    // every endpoint is asked: the second one refuses
    let (bad, _) = builder(vec![caps(json!({"maxCalldataBytes": 1}))]).await;
    let eps: Vec<url::Url> = vec![ok.uri().parse().unwrap(), bad.uri().parse().unwrap()];
    let e = check_compute_code(&cfg, &signer, &eps)
        .await
        .unwrap_err()
        .to_string();
    assert!(e.contains(bad.uri().trim_start_matches("http://")), "{e}");
    // deployed mode: never asks
    let (none, seen) = builder(vec![caps(json!({}))]).await;
    let plain = cfg_at(&none.uri());
    check_compute_code(&plain, &signer, &plain.endpoints)
        .await
        .unwrap();
    assert!(seen.lock().unwrap().is_empty());
}

/// The first `bex_capabilities` answer comes after the 3 s timeout: the check asks once more.
/// Two slow answers fail it.
#[tokio::test]
async fn test_capability_gate_retries_one_timeout() {
    struct SlowFirst(AtomicUsize, usize);
    impl Respond for SlowFirst {
        fn respond(&self, _: &Request) -> ResponseTemplate {
            let t = ResponseTemplate::new(200).set_body_json(caps(
                json!({"computeCodeEnabled": true, "maxComputeCodeBytes": 24576}),
            ));
            if self.0.fetch_add(1, Ordering::SeqCst) < self.1 {
                t.set_delay(std::time::Duration::from_millis(3_500))
            } else {
                t
            }
        }
    }
    let signer = PrivateKeySigner::random();
    for (slow, ok) in [(1, true), (2, false)] {
        let s = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(SlowFirst(AtomicUsize::new(0), slow))
            .mount(&s)
            .await;
        let cfg = code_cfg(&s.uri(), "http://localhost:9");
        let r = check_compute_code(&cfg, &signer, &cfg.endpoints).await;
        assert_eq!(r.is_ok(), ok, "{slow} slow answers: {r:?}");
    }
}

#[tokio::test]
async fn test_startup_runs_gate_and_venues_override_skips_gate() {
    let signer = PrivateKeySigner::random();
    let (b, bseen) = builder(vec![caps(json!({"computeCodeEnabled": true,
        "maxComputeCodeBytes": 24576}))])
    .await;
    let (el, elseen) = code_el("0x", "0x0", "0x0").await;
    let cfg = code_cfg(&b.uri(), &el.uri());
    check(&cfg, &signer, &cfg.endpoints, false).await.unwrap();
    assert_eq!(bseen.lock().unwrap().len(), 1, "capability gate");
    assert_eq!(
        elseen.lock().unwrap().len(),
        2,
        "venues() on solver and executor"
    );
    // --override-code sends no compute.code: no gate, venues still checked
    check(&cfg, &signer, &cfg.endpoints, true).await.unwrap();
    assert_eq!(
        bseen.lock().unwrap().len(),
        1,
        "no bex_capabilities for --override-code"
    );
    assert_eq!(elseen.lock().unwrap().len(), 4);
    // a refusing builder stops startup before venues
    let (no, _) = builder(vec![caps(json!({}))]).await;
    let cfg = code_cfg(&no.uri(), &el.uri());
    assert!(check(&cfg, &signer, &cfg.endpoints, false).await.is_err());
    assert_eq!(elseen.lock().unwrap().len(), 4);
}

#[tokio::test]
async fn test_retries_are_paced_too() {
    let busy = rpc_err(-32005, "bex_simulate is busy, retry");
    let answers = [busy.clone(), busy.clone(), busy, accepted_answer()];
    let times = Arc::new(Mutex::new(vec![]));
    let t2 = times.clone();
    let front = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(move |_: &Request| {
            let mut t = t2.lock().unwrap();
            t.push(Instant::now());
            ResponseTemplate::new(200).set_body_json(answers[(t.len() - 1).min(3)].clone())
        })
        .mount(&front)
        .await;
    let cfg = cfg_at(&front.uri());
    let cycles: Vec<Cycle> = (0..2).map(|_| one_cycle()[0].clone()).collect();
    simulate(
        &cfg,
        &cycles,
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        &head5(),
        false,
    )
    .await
    .unwrap();
    let t = times.lock().unwrap().clone();
    assert_eq!(t.len(), 5, "3 busy + 1 ok, then the 2nd cycle");
    // ticks are 200 ms apart; arrival jitter is allowed, an unpaced retry (100 ms) is not
    for w in t.windows(2) {
        let gap = w[1] - w[0];
        assert!(
            gap >= std::time::Duration::from_millis(150),
            "gap {gap:?}: over 5 req/s"
        );
    }
}

#[tokio::test]
async fn test_rows_carry_snapshot_block_and_the_plans_floor() {
    let ans = |n: u64, floor: u64| {
        let mut a = accepted_answer_with_floor(U256::from(floor));
        a["result"]["snapshotBlock"] = json!(n);
        a
    };
    let (b, _) = builder(vec![ans(41, 20), ans(41, 20), ans(42, 40)]).await;
    let cfg = cfg(&b.uri(), "http://localhost:9");
    let cycles: Vec<Cycle> = (0..3).map(|_| one_cycle()[0].clone()).collect();
    let v = simulate(
        &cfg,
        &cycles,
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        &head5(),
        false,
    )
    .await
    .unwrap();
    let snap: Vec<_> = v.rows.iter().map(|r| r.snapshot_block).collect();
    assert_eq!(snap, vec![Some(41), Some(41), Some(42)]);
    // floor_wei is the plan's minProfit, whatever the node says
    assert_eq!(v.rows[0].floor_wei, Some(U256::from(20u64)));
    assert_eq!(v.rows[2].floor_wei, Some(U256::from(40u64)));
    let out = std::env::temp_dir().join(format!("bex-snap-{}.csv", std::process::id()));
    let _ = std::fs::remove_file(&out);
    append_csv(&out, &head5(), &v.rows).unwrap();
    let csv = std::fs::read_to_string(&out).unwrap();
    let cols: Vec<&str> = CSV_HEADER.split(',').collect();
    let row: Vec<&str> = csv.lines().nth(3).unwrap().split(',').collect();
    let col = |name: &str| row[cols.iter().position(|c| *c == name).unwrap()];
    assert_eq!((col("head"), col("snapshot_block")), ("5", "42"));
    assert_eq!(col("floor_wei"), "40");
}

#[tokio::test]
async fn test_long_batch_refreshes_head_and_target() {
    let (b, seen) = builder(vec![accepted_answer()]).await;
    // the chain moved on to 12 while the batch started from head 5
    let reads = Arc::new(AtomicUsize::new(0));
    let r2 = reads.clone();
    let el = MockServer::start().await;
    Mock::given(method("POST"))
        .respond_with(move |req: &Request| {
            let b: Value = serde_json::from_slice(&req.body).unwrap();
            assert_eq!(b["method"], "eth_getBlockByNumber");
            assert_eq!(b["params"][0], "latest");
            r2.fetch_add(1, Ordering::SeqCst);
            rpc_ok(header(&json!("0xc"), "0x1"))
        })
        .mount(&el)
        .await;
    let cfg = cfg(&b.uri(), &el.uri());
    let cycles: Vec<Cycle> = (0..6).map(|_| one_cycle()[0].clone()).collect();
    let pacing = bex_backrun::simulate::Pacing {
        min_gap: std::time::Duration::from_millis(30),
        head_refresh: std::time::Duration::from_millis(70),
    };
    let v = bex_backrun::simulate::simulate_paced(
        &cfg,
        &cycles,
        &cfg.endpoints[0],
        &PrivateKeySigner::random(),
        &head5(),
        false,
        &pacing,
    )
    .await
    .unwrap();
    let sent: Vec<u64> = seen
        .lock()
        .unwrap()
        .iter()
        .map(|b| b["params"][0]["targetBlock"].as_u64().unwrap())
        .collect();
    assert_eq!(sent[0], 6, "the first request targets the start head + 1");
    assert_eq!(
        *sent.last().unwrap(),
        13,
        "later requests target the refreshed head + 1"
    );
    let rows: Vec<u64> = v.rows.iter().map(|r| r.target_block).collect();
    assert_eq!(rows, sent, "each row records the target it sent");
    // a few reads for 6 calls, not one per call
    let n = reads.load(Ordering::SeqCst);
    assert!((1..=3).contains(&n), "{n} head reads");
    let out = std::env::temp_dir().join(format!("bex-target-{}.csv", std::process::id()));
    let _ = std::fs::remove_file(&out);
    append_csv(&out, &head5(), &v.rows).unwrap();
    let cols: Vec<&str> = CSV_HEADER.split(',').collect();
    let i = cols.iter().position(|c| *c == "target_block").unwrap();
    let last: Vec<String> = std::fs::read_to_string(&out)
        .unwrap()
        .lines()
        .last()
        .unwrap()
        .split(',')
        .map(str::to_owned)
        .collect();
    assert_eq!((last[0].as_str(), last[i].as_str()), ("5", "13"));
}

use alloy::primitives::{address, keccak256, Address, U256};
use alloy::signers::local::PrivateKeySigner;
use alloy::sol_types::SolCall;
use bex_backrun::abi::ICycleSolver;
use bex_backrun::config::BotConfig;
use bex_backrun::cycles::{Cycle, Leg};
use bex_backrun::request::*;

const WETH: Address = address!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
const USDC: Address = address!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");

const CFG: &str = r#"
endpoints = ["http://localhost:1"]
rpc_http = "http://localhost:2"
solver = "0x1111111111111111111111111111111111111111"
executor = "0x2222222222222222222222222222222222222222"
weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
# the reference vectors below were built at share 10000
builder_share_bps = 10000
min_profit_wei = "0x7"
"#;

/// The `weiPerGas` of every test request.
const WPG: U256 = U256::from_limbs([13, 0, 0, 0]);

fn cfg() -> BotConfig {
    toml::from_str(CFG).unwrap()
}

/// `uuid_mode = "parity"`.
fn cfg_parity() -> BotConfig {
    toml::from_str(&format!("{CFG}uuid_mode = \"parity\"\n")).unwrap()
}

fn cycle() -> Cycle {
    Cycle {
        name: "c1".into(),
        legs: vec![
            Leg {
                version: 3,
                token_in: WETH,
                token_out: USDC,
                fee: 100,
                tick_spacing: 1,
            },
            Leg {
                version: 3,
                token_in: USDC,
                token_out: WETH,
                fee: 500,
                tick_spacing: -10,
            },
        ],
    }
}

#[test]
fn test_request_json_shape() {
    let signer = address!("00000000000000000000000000000000000000aa");
    let req = build_request(&cfg(), &cycle(), 100, WPG, signer);
    let v: serde_json::Value = serde_json::to_value(&req).unwrap();
    assert_eq!(v["targetBlock"], 100);
    assert_eq!(v["replacementSeqNumber"], 100);
    assert_eq!(
        v["replacementUuid"],
        replacement_uuid(signer, "c1").to_string()
    );
    let c = &v["bex"]["compute"];
    assert_eq!(c["to"], "0x1111111111111111111111111111111111111111");
    assert!(c["calldata"].as_str().unwrap().starts_with("0x"));
    let e = &v["bex"]["execute"];
    assert_eq!(e["to"], "0x2222222222222222222222222222222222222222");
    assert_eq!(e["prefixArgs"], "0x");
    assert_eq!(e["appendComputeResult"], true);
    let sel = keccak256(
        "execute((uint256,uint256,uint256,uint16,address,bytes32,(uint8,address,address,uint24,int24)[]))",
    );
    assert_eq!(execute_selector(), sel[..4]);
    assert_eq!(
        e["selector"],
        format!("0x{}", alloy::hex::encode(&sel[..4]))
    );
    assert_eq!(v["bex"].as_object().unwrap().len(), 2);
    assert_eq!(e.as_object().unwrap().len(), 4);
}

#[test]
fn test_solve_calldata_decodes() {
    let t = alloy::primitives::B256::repeat_byte(0x7a);
    let r = address!("00000000000000000000000000000000000000bb");
    let cd = solve_calldata(&cycle().legs, U256::from(9), WPG, 5000, r, t);
    let d = ICycleSolver::solveCall::abi_decode(&cd).unwrap();
    assert_eq!(d.tag, t);
    assert_eq!(d.recipient, r);
    assert_eq!(d.minProfitWei, U256::from(9));
    assert_eq!(d.weiPerGas, WPG);
    assert_eq!(d.builderShareBps, 5000);
    assert_eq!(d.legs.len(), 2);
    assert_eq!(d.legs[0].fee.to::<u32>(), 100);
    assert_eq!(d.legs[1].fee.to::<u32>(), 500);
    assert_eq!(d.legs[1].tickSpacing.as_i32(), -10);
    assert_eq!(d.legs[1].tokenIn, USDC);
}

/// The tag is the signer address left-padded (`bytes32(uint256(uint160(signer)))`), and every
/// request's solve calldata carries it.
#[test]
fn test_request_carries_signer_tag() {
    let signer = address!("00000000000000000000000000000000000000aa");
    let t = tag(signer);
    assert_eq!(t, alloy::primitives::B256::with_last_byte(0xaa));
    let req = build_request(&cfg(), &cycle(), 100, WPG, signer);
    let d = ICycleSolver::solveCall::abi_decode(&req.bex.compute.calldata).unwrap();
    assert_eq!(d.tag, t);
}

/// The plan's recipient is `payout_address`, or the signer without it, in `solve` and `solveMany`.
#[test]
fn test_request_recipient_is_payout_address_or_signer() {
    let signer = address!("00000000000000000000000000000000000000aa");
    let payout = address!("00000000000000000000000000000000000000bb");
    let req = build_request(&cfg(), &cycle(), 100, WPG, signer);
    let d = ICycleSolver::solveCall::abi_decode(&req.bex.compute.calldata).unwrap();
    assert_eq!(d.recipient, signer);
    let mut c = cfg();
    c.payout_address = Some(payout);
    let req = build_request(&c, &cycle(), 100, WPG, signer);
    let d = ICycleSolver::solveCall::abi_decode(&req.bex.compute.calldata).unwrap();
    assert_eq!(d.recipient, payout);
    assert_eq!(d.tag, tag(signer), "the tag stays the signer");
    let req = build_group_request(&c, &two_cycle_group(), 100, WPG, signer);
    let d = ICycleSolver::solveManyCall::abi_decode(&req.bex.compute.calldata).unwrap();
    assert_eq!(d.recipient, payout);
}

#[test]
fn test_signature_matches_reference_vector() {
    // Produced once by an independent implementation of the BEX signature (a devnet's reference
    // code), with key = [1u8; 32] and body = {"jsonrpc":"2.0"}.
    const EXPECTED: &str = "0x1a642f0E3c3aF545E7AcBD38b07251B3990914F1:0x630fec12e3bc192cb2b5f1b5a24d764dbb5e87fcaa8bd69755cb348f49d7c7f653612745a4f27e5f6d62af2d4a6025fc1155596d39ae0a4030b455242911c2bb1c";
    let signer = PrivateKeySigner::from_bytes(&[1u8; 32].into()).unwrap();
    assert_eq!(
        flashbots_signature(&signer, b"{\"jsonrpc\":\"2.0\"}"),
        EXPECTED
    );
}

#[test]
fn test_uuid_stable_per_signer_and_cycle() {
    let a = address!("00000000000000000000000000000000000000aa");
    let b = address!("00000000000000000000000000000000000000bb");
    assert_eq!(replacement_uuid(a, "c1"), replacement_uuid(a, "c1"));
    assert_ne!(replacement_uuid(a, "c1"), replacement_uuid(a, "c2"));
    assert_ne!(replacement_uuid(a, "c1"), replacement_uuid(b, "c1"));
}

/// Vectors from `cast keccak` / `cast abi-encode` (Solidity `keccak256(abi.encode(legs))`).
#[test]
fn test_cycle_id_matches_solidity_vectors() {
    use alloy::primitives::{address, b256};
    use bex_backrun::cycles::Leg;
    assert_eq!(
        bex_backrun::request::cycle_id(&[]),
        b256!("569e75fc77c1a856f6daaf9e69d8a9566ca34aa47f9133711ce065a571af0cfd")
    );
    let leg = Leg {
        version: 3,
        token_in: address!("C02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"),
        token_out: address!("A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"),
        fee: 100,
        tick_spacing: 1,
    };
    assert_eq!(
        bex_backrun::request::cycle_id(&[leg]),
        b256!("e8a67fc9d9d52be809632cc6b0a18137f2f2d10e5c3c0b5c862b2136727d6bd3")
    );
}

/// Regenerated on purpose for `solve(legs, minProfitWei, weiPerGas, builderShareBps, recipient, tag)`
/// (min profit 7, weiPerGas 13): the
/// solve and execute selectors and the calldata changed (recipient = tag = signer 0x..aa). Before
/// that it was regenerated for the tag, and first captured at f973a70 (before `compute.code`). A
/// request without code must not change by a byte unless the ABI does.
const BODY_TAGGED: &str = r#"{"id":1,"jsonrpc":"2.0","method":"bex_sendBundle","params":[{"bex":{"compute":{"calldata":"0x89b20bbc00000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000007000000000000000000000000000000000000000000000000000000000000000d000000000000000000000000000000000000000000000000000000000000271000000000000000000000000000000000000000000000000000000000000000aa00000000000000000000000000000000000000000000000000000000000000aa00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000003000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000003000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000000000000000000000000000000000000000001f4fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff6","to":"0x1111111111111111111111111111111111111111"},"execute":{"appendComputeResult":true,"prefixArgs":"0x","selector":"0x55c63952","to":"0x2222222222222222222222222222222222222222"}},"replacementSeqNumber":100,"replacementUuid":"29d4cc8e-c674-5f1b-8f2c-7b9e719e0a31","targetBlock":100}]}"#;

#[test]
fn test_body_without_code_is_byte_identical() {
    let signer = address!("00000000000000000000000000000000000000aa");
    let req = build_request(&cfg(), &cycle(), 100, WPG, signer);
    let body = bex_backrun::sender::envelope("bex_sendBundle", &req);
    assert_eq!(String::from_utf8(body).unwrap(), BODY_TAGGED);
}

/// Python `uuid.uuid5(uuid.NAMESPACE_OID, "0x00..aa:c1:0")` and `...:c1:1`.
const PARITY_UUID_EVEN: &str = "65bffac8-0af5-5890-aad7-9435a2b5a351";
const PARITY_UUID_ODD: &str = "0c3e1a70-614b-5693-b627-77dbab5c207d";

/// Parity mode changes only `replacementUuid`: the body is `BODY_TAGGED` with it.
#[test]
fn test_body_parity_mode_vector() {
    let signer = address!("00000000000000000000000000000000000000aa");
    let req = build_request(&cfg_parity(), &cycle(), 100, WPG, signer);
    let body = String::from_utf8(bex_backrun::sender::envelope("bex_sendBundle", &req)).unwrap();
    assert_eq!(
        body,
        BODY_TAGGED.replace("29d4cc8e-c674-5f1b-8f2c-7b9e719e0a31", PARITY_UUID_EVEN)
    );
    let odd = build_request(&cfg_parity(), &cycle(), 101, WPG, signer);
    assert_eq!(odd.replacement_uuid, PARITY_UUID_ODD);
    assert_eq!(odd.replacement_seq_number, 101);
}

/// N and N+1 never share a uuid (N+1 does not replace the still-building N); N+2 replaces N.
#[test]
fn test_parity_uuid_alternates_by_target() {
    let a = address!("00000000000000000000000000000000000000aa");
    let b = address!("00000000000000000000000000000000000000bb");
    assert_eq!(parity_uuid(a, "c1", 100), parity_uuid(a, "c1", 102));
    assert_ne!(parity_uuid(a, "c1", 100), parity_uuid(a, "c1", 101));
    assert_ne!(parity_uuid(a, "c1", 100), parity_uuid(a, "c2", 100));
    assert_ne!(parity_uuid(a, "c1", 100), parity_uuid(b, "c1", 100));
    assert_ne!(parity_uuid(a, "c1", 100), replacement_uuid(a, "c1"));
}

#[test]
fn test_body_with_solver_code_carries_file_bytes() {
    let dir = std::env::temp_dir().join(format!("bex-reqcode-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("solver.hex"), "0x6080604052\n").unwrap();
    let p = dir.join("bot.toml");
    std::fs::write(
        &p,
        r#"
endpoints = ["http://localhost:1"]
rpc_http = "http://localhost:2"
executor = "0x2222222222222222222222222222222222222222"
weth = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
solver_code = "solver.hex"
"#,
    )
    .unwrap();
    let cfg = bex_backrun::config::load_bot(&p).unwrap();
    let signer = address!("00000000000000000000000000000000000000aa");
    let req = build_request(&cfg, &cycle(), 100, WPG, signer);
    let v: serde_json::Value = serde_json::to_value(&req).unwrap();
    assert_eq!(v["bex"]["compute"]["code"], "0x6080604052");
    // the target is derived per request, never `solver`
    let to = code_target(signer, "c1", 100);
    assert_eq!(v["bex"]["compute"]["to"], format!("{to:#x}"));
    assert_ne!(to, code_target(signer, "c1", 101));
    assert_ne!(to, code_target(signer, "c2", 100));
    assert_ne!(
        to,
        code_target(
            address!("00000000000000000000000000000000000000bb"),
            "c1",
            100
        )
    );
}

/// `cast keccak $(cast abi-encode "f(string,address,string,uint256)" bex-backrun 0x..aa c1 100)`.
#[test]
fn test_code_target_matches_solidity_abi_encode() {
    let signer = address!("00000000000000000000000000000000000000aa");
    assert_eq!(code_target(signer, "c1", 100), CODE_TARGET_VECTOR);
}
const CODE_TARGET_VECTOR: Address = address!("70537fcbc2482bd6ce301caba15fce2def836a0f");

fn two_cycle_group() -> bex_backrun::groups::Group {
    let mut b = cycle();
    b.name = "c2".into();
    b.legs.reverse();
    bex_backrun::groups::Group {
        name: "c1+2".into(),
        cycles: vec![cycle(), b],
    }
}

/// A one-cycle group (`group_size = 1`) is today's request, byte for byte: the `BODY_TAGGED`
/// vector, and in code mode the target `code_target(signer, cycle name, block)`.
#[test]
fn test_single_cycle_group_equals_build_request() {
    let signer = address!("00000000000000000000000000000000000000aa");
    let g = &bex_backrun::groups::group_cycles(&[cycle()], 1)[0];
    let req = build_group_request(&cfg(), g, 100, WPG, signer);
    let body = bex_backrun::sender::envelope("bex_sendBundle", &req);
    assert_eq!(String::from_utf8(body).unwrap(), BODY_TAGGED);
    let mut code = cfg();
    code.solver_code_bytes = Some(alloy::primitives::Bytes::from_static(&[0x60, 0x01]));
    let req = build_group_request(&code, g, 100, WPG, signer);
    assert_eq!(req.bex.compute.to, code_target(signer, "c1", 100));
}

/// `cast calldata "solveMany((uint8,address,address,uint24,int24)[][],uint256[],uint256,uint16,address,bytes32)"`
/// over `two_cycle_group`, minProfit [7, 7], weiPerGas 13, share 10000, recipient 0x..aa (the signer), tag 0x..aa.
const SOLVE_MANY_VECTOR: &str = "0x12d924e500000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000003e0000000000000000000000000000000000000000000000000000000000000000d000000000000000000000000000000000000000000000000000000000000271000000000000000000000000000000000000000000000000000000000000000aa00000000000000000000000000000000000000000000000000000000000000aa0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000001a000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000003000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000006400000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000003000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000000000000000000000000000000000000000001f4fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000003000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000000000000000000000000000000000000000001f4fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff60000000000000000000000000000000000000000000000000000000000000003000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000a0b86991c6218b36c1d19d4a2e9eb0ce3606eb4800000000000000000000000000000000000000000000000000000000000000640000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000070000000000000000000000000000000000000000000000000000000000000007";

#[test]
fn test_group_request_encodes_solve_many() {
    let signer = address!("00000000000000000000000000000000000000aa");
    let g = two_cycle_group();
    let req = build_group_request(&cfg(), &g, 100, WPG, signer);
    let cd = &req.bex.compute.calldata;
    assert_eq!(
        ICycleSolver::solveManyCall::SELECTOR,
        keccak256(
            "solveMany((uint8,address,address,uint24,int24)[][],uint256[],uint256,uint16,address,bytes32)"
        )[..4]
    );
    assert_eq!(alloy::hex::encode_prefixed(cd), SOLVE_MANY_VECTOR);
    let d = ICycleSolver::solveManyCall::abi_decode(cd).unwrap();
    assert_eq!(d.minProfitWei, vec![U256::from(7); 2]);
    assert_eq!(d.weiPerGas, WPG);
    assert_eq!(d.cycles.len(), 2);
    assert_eq!(d.cycles[0][0].tokenOut, USDC);
    assert_eq!(d.cycles[1][0].tokenIn, USDC);
    assert_eq!(d.cycles[1][0].tickSpacing.as_i32(), -10);
    assert_eq!(d.builderShareBps, 10_000);
    assert_eq!(d.recipient, signer);
    assert_eq!(d.tag, tag(signer));
    // keyed by the group name
    assert_eq!(
        req.replacement_uuid,
        replacement_uuid(signer, "c1+2").to_string()
    );
    let p = build_group_request(&cfg_parity(), &g, 101, WPG, signer);
    assert_eq!(
        p.replacement_uuid,
        parity_uuid(signer, "c1+2", 101).to_string()
    );
    let mut code = cfg();
    code.solver_code_bytes = Some(alloy::primitives::Bytes::from_static(&[0x60, 0x01]));
    let c = build_group_request(&code, &g, 100, WPG, signer);
    assert_eq!(c.bex.compute.to, code_target(signer, "c1+2", 100));
}

/// Copy 0 is the group's request byte for byte; copy k >= 1 differs only in `replacementUuid`
/// and the code-mode compute target, both keyed by `<group name>#k`.
#[test]
fn test_request_copies_differ_only_in_uuid_and_code_target() {
    let signer = address!("00000000000000000000000000000000000000aa");
    let g = two_cycle_group();
    let mut code = cfg();
    code.solver_code_bytes = Some(alloy::primitives::Bytes::from_static(&[0x60, 0x01]));
    for c in [cfg(), cfg_parity(), code] {
        let body = |g: &bex_backrun::groups::Group| {
            bex_backrun::sender::envelope(
                "bex_sendBundle",
                &build_group_request(&c, g, 101, WPG, signer),
            )
        };
        assert_eq!(body(&g.copy(0)), body(&g));
        let v0: serde_json::Value = serde_json::from_slice(&body(&g)).unwrap();
        let mut v1: serde_json::Value = serde_json::from_slice(&body(&g.copy(1))).unwrap();
        let p1 = &mut v1["params"][0];
        let want_uuid = match c.uuid_mode {
            bex_backrun::config::UuidMode::Parity => parity_uuid(signer, "c1+2#1", 101),
            bex_backrun::config::UuidMode::Cycle => replacement_uuid(signer, "c1+2#1"),
        };
        assert_eq!(p1["replacementUuid"], want_uuid.to_string());
        assert_ne!(p1["replacementUuid"], v0["params"][0]["replacementUuid"]);
        let want_to = match c.solver_code_bytes {
            Some(_) => code_target(signer, "c1+2#1", 101),
            None => c.solver,
        };
        assert_eq!(p1["bex"]["compute"]["to"], format!("{want_to:#x}"));
        // with those two fields restored, the copies are equal
        p1["replacementUuid"] = v0["params"][0]["replacementUuid"].clone();
        p1["bex"]["compute"]["to"] = v0["params"][0]["bex"]["compute"]["to"].clone();
        assert_eq!(v1, v0);
    }
}

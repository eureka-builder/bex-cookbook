//! The BEX request body and its `X-Flashbots-Signature` header.
//!
//! One request asks the builder to run a compute step and, if it pays, an execute step:
//!
//! ```text
//! { "targetBlock": N + 1,
//!   "replacementUuid": uuid5(signer, request name), "replacementSeqNumber": N + 1,
//!   "bex": {
//!     "compute": { "to": solver or code target, "calldata": solve(..) or solveMany(..),
//!                  "code": solver runtime code (code mode only) },
//!     "execute": { "to": executor, "selector": execute(Plan), "prefixArgs": "0x",
//!                  "appendComputeResult": true } } }
//! ```
//!
//! The builder `staticcall`s the compute on its block state. `solve` returns `abi.encode(Plan)`,
//! so `selector || return data` is exactly `execute(plan)`. The builder signs that execute with
//! its own key and keeps it only if the coinbase gains more than its gas.
use crate::abi::{self, ICycleExecutor, ICycleSolver};
use crate::config::{BotConfig, UuidMode};
use crate::cycles::{Cycle, Leg};
use crate::groups::Group;
use alloy::primitives::{keccak256, Address, Bytes, FixedBytes, B256, U256};
use alloy::signers::{local::PrivateKeySigner, SignerSync};
use alloy::sol_types::{SolCall, SolValue};
use serde::Serialize;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BexRequest {
    pub target_block: u64,
    pub replacement_uuid: String,
    pub replacement_seq_number: u64,
    pub bex: Bex,
    /// `bex_simulate` only: a state override map (address -> `{code, balance, ...}`), a top-level
    /// sibling of the bundle fields.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state_overrides: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Bex {
    pub compute: Compute,
    pub execute: Execute,
}

#[derive(Debug, Clone, Serialize)]
pub struct Compute {
    pub to: Address,
    pub calldata: Bytes,
    /// Runtime code the builder installs at `to` for the compute call (code mode).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<Bytes>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Execute {
    pub to: Address,
    pub selector: FixedBytes<4>,
    pub prefix_args: Bytes,
    pub append_compute_result: bool,
}

/// `execute(Plan)`'s selector. The builder puts it before the compute's return data.
pub fn execute_selector() -> [u8; 4] {
    ICycleExecutor::executeCall::SELECTOR
}

pub fn abi_legs(legs: &[Leg]) -> Vec<abi::Leg> {
    legs.iter()
        .map(|l| abi::Leg {
            version: l.version,
            tokenIn: l.token_in,
            tokenOut: l.token_out,
            // Widths are enforced by `load_cycles`; a Cycle built by hand must obey them too.
            fee: l.fee.try_into().expect("fee fits uint24"),
            tickSpacing: l.tick_spacing.try_into().expect("tick_spacing fits int24"),
        })
        .collect()
}

/// The bot's tag on the shared executor: the signer address, left-padded to 32 bytes. The solver
/// echoes it into the plan and the executor emits it as `CycleExecuted` topic 2. Self-declared:
/// anyone can send the same tag, so it attributes landings in stats only.
pub fn tag(signer: Address) -> B256 {
    signer.into_word()
}

/// `solve(legs, minProfitWei, weiPerGas, builderShareBps, recipient, tag)`: one cycle. The solver
/// prices the plan's gas itself: its floor is `max(minProfitWei, weiPerGas * gas(plan), 1)`.
/// `recipient` gets the profit after the builder's share (`address(0)`: the caller of `execute`,
/// under BEX the builder's operator key).
pub fn solve_calldata(
    legs: &[Leg],
    min_profit: U256,
    wei_per_gas: U256,
    share: u16,
    recipient: Address,
    tag: B256,
) -> Bytes {
    ICycleSolver::solveCall {
        legs: abi_legs(legs),
        minProfitWei: min_profit,
        weiPerGas: wei_per_gas,
        builderShareBps: share,
        recipient,
        tag,
    }
    .abi_encode()
    .into()
}

/// `solveMany`: one leg array per cycle, in group order, each with the same `min_profit`.
pub fn solve_many_calldata(
    cycles: &[Cycle],
    min_profit: U256,
    wei_per_gas: U256,
    share: u16,
    recipient: Address,
    tag: B256,
) -> Bytes {
    ICycleSolver::solveManyCall {
        cycles: cycles.iter().map(|c| abi_legs(&c.legs)).collect(),
        minProfitWei: vec![min_profit; cycles.len()],
        weiPerGas: wei_per_gas,
        builderShareBps: share,
        recipient,
        tag,
    }
    .abi_encode()
    .into()
}

/// `Pools.cycleId`: `keccak256(abi.encode(legs))`, the `cycleId` of `CycleExecuted`.
pub fn cycle_id(legs: &[Leg]) -> B256 {
    keccak256(abi_legs(legs).abi_encode())
}

/// `uuid_mode = "cycle"`: `uuid5(signer, name)`. With `seq = target_block`, each block's request
/// replaces the one before.
pub fn replacement_uuid(signer: Address, cycle_name: &str) -> Uuid {
    Uuid::new_v5(
        &Uuid::NAMESPACE_OID,
        format!("{signer:#x}:{cycle_name}").as_bytes(),
    )
}

/// `uuid_mode = "parity"`: `uuid5(signer, cycle, target_block mod 2)`. With `seq = target_block`,
/// a resend for the same target or the request for N+2 replaces N; the request for N+1 does not.
pub fn parity_uuid(signer: Address, cycle_name: &str, target_block: u64) -> Uuid {
    Uuid::new_v5(
        &Uuid::NAMESPACE_OID,
        format!("{signer:#x}:{cycle_name}:{}", target_block % 2).as_bytes(),
    )
}

/// Code mode: the compute target of one request, fresh per (signer, cycle, block):
/// `address(keccak256(abi.encode("bex-backrun", signer, cycle_name, target_block)))`.
/// The builder drops a code request whose target has code, a nonce or a balance
/// (`ComputeTargetExists`), so a fixed target is killed by anyone sending it 1 wei.
pub fn code_target(signer: Address, cycle_name: &str, target_block: u64) -> Address {
    let enc = (
        "bex-backrun".to_string(),
        signer,
        cycle_name.to_string(),
        U256::from(target_block),
    )
        .abi_encode_params();
    Address::from_slice(&keccak256(enc)[12..])
}

/// Where `eth_call` reaches the solver: `solver`, or in code mode a fixed address the code
/// is installed at with a state override (`status::solver_call`).
pub fn solver_for_calls(cfg: &BotConfig) -> Address {
    match cfg.solver_code_bytes {
        Some(_) => code_target(Address::ZERO, "eth_call", 0),
        None => cfg.solver,
    }
}

/// The request for one cycle alone, as `simulate` sends it: a group of one, named by the cycle.
pub fn build_request(
    cfg: &BotConfig,
    cycle: &Cycle,
    target_block: u64,
    wei_per_gas: U256,
    signer: Address,
) -> BexRequest {
    let g = Group {
        name: cycle.name.clone(),
        cycles: vec![cycle.clone()],
    };
    build_group_request(cfg, &g, target_block, wei_per_gas, signer)
}

/// One request for a group, keyed (uuid, code target) by the group name. A one-cycle group sends
/// `solve`, the same bytes as `build_request`. A larger one sends `solveMany` with the same
/// `min_profit` for every cycle. The plan's recipient is `payout_address`, or the signer.
pub fn build_group_request(
    cfg: &BotConfig,
    g: &Group,
    target_block: u64,
    wei_per_gas: U256,
    signer: Address,
) -> BexRequest {
    let recipient = cfg.payout_address.unwrap_or(signer);
    let calldata = match g.cycles.as_slice() {
        [c] => solve_calldata(
            &c.legs,
            cfg.min_profit_wei,
            wei_per_gas,
            cfg.builder_share_bps,
            recipient,
            tag(signer),
        ),
        cs => solve_many_calldata(
            cs,
            cfg.min_profit_wei,
            wei_per_gas,
            cfg.builder_share_bps,
            recipient,
            tag(signer),
        ),
    };
    BexRequest {
        target_block,
        replacement_uuid: match cfg.uuid_mode {
            UuidMode::Parity => parity_uuid(signer, &g.name, target_block),
            UuidMode::Cycle => replacement_uuid(signer, &g.name),
        }
        .to_string(),
        replacement_seq_number: target_block,
        state_overrides: None,
        bex: Bex {
            compute: Compute {
                to: match cfg.solver_code_bytes {
                    Some(_) => code_target(signer, &g.name, target_block),
                    None => cfg.solver,
                },
                calldata,
                code: cfg.solver_code_bytes.clone(),
            },
            execute: Execute {
                to: cfg.executor,
                selector: execute_selector().into(),
                prefix_args: Bytes::new(),
                append_compute_result: true,
            },
        },
    }
}

/// `<signer address>:<0x sig>`: EIP-191 `personal_sign` over the hex string of keccak256(body).
pub fn flashbots_signature(signer: &PrivateKeySigner, body: &[u8]) -> String {
    let digest = format!("{:#x}", keccak256(body));
    let sig = signer
        .sign_message_sync(digest.as_bytes())
        .expect("a local key signs any message");
    format!(
        "{}:{}",
        signer.address(),
        alloy::hex::encode_prefixed(sig.as_bytes())
    )
}

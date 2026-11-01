#!/usr/bin/env python3
"""Check one landed CycleExecutor `execute` on chain. Prints one line per check and exits 1 if one fails.

Usage:
    BEX_RPC_HTTP=<rpc url> ops/verify_landing.py <tx hash> [--executor 0x..] [--operator 0x..]
    ops/verify_landing.py --self-test      # checks the payout logic, no RPC

The RPC must answer debug_traceTransaction with the callTracer, and eth_call at the landing block.
--executor (or BEX_EXECUTOR) defaults to the shared mainnet executor. --operator (or BEX_OPERATOR)
is the builder key that signed the execute. Without it the sender check is skipped, and the
transaction's sender is the operator for the other checks.

Checks:
    the receipt has status 1 and the transaction goes to the executor (and from the operator, with --operator)
    the receipt has a CycleExecuted log from the executor
    block.coinbase receives exactly paidToCoinbase, and paidToCoinbase = profit * builderShareBps / 10000
    the plan's recipient (the operator when it is address(0)) receives exactly profit - paidToCoinbase
    (0 at share 10000)
    profit >= the plan's minProfit, and amountIn is the plan's
    no internal call errors
    ETH value goes only to the coinbase, the recipient, the executor, the V4 PoolManager, a swapped pool
    or WETH deposit()
    no approve call and no Approval log
    the next transaction refills the operator: coinbase -> operator, value = gasUsed * basefee
    the executor holds no token and no ETH after the block
Stdlib only.
"""
import argparse
import json
import os
import sys
import urllib.request

MAINNET_EXECUTOR = "0x12eae402fa25b6b656c65fdff06990f29298449b"
POOL_MANAGER = "0x000000000004444c5dc75cb358380d2e3de08a90"
WETH = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
CYCLE_EXECUTED = "0x436429f727d9a96965fa98c786955984649cccc7c00a9472c175c36a327ea358"
APPROVAL = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"
EXECUTE = "0x55c63952"  # execute((uint256,uint256,uint256,uint16,address,bytes32,(uint8,address,address,uint24,int24)[]))
DEPOSIT, APPROVE, TRANSFER, BALANCE_OF = "0xd0e30db0", "0x095ea7b3", "0xa9059cbb", "0x70a08231"
SWAPS = {"0x128acb08", "0x022c0d9f", "0x48c89491"}  # V3 swap, V2 swap, V4 unlock


class Rpc:
    def __init__(self, url):
        self.url = url

    def __call__(self, method, params):
        body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
        req = urllib.request.Request(self.url, data=body,
                                     headers={"content-type": "application/json", "user-agent": "bex-backrun-verify/1.0"})
        try:
            reply = json.load(urllib.request.urlopen(req, timeout=90))
        except Exception as e:  # the URL may hold a key: name the method, never the URL
            sys.exit(f"{method}: RPC call failed ({type(e).__name__})")
        if "error" in reply:
            sys.exit(f"{method}: {reply['error'].get('message', reply['error'])}")
        return reply["result"]


def words(hexdata):
    """32-byte words of 0x-hex data, as ints."""
    data = hexdata[2:]
    return [int(data[i:i + 64], 16) for i in range(0, len(data), 64)]


def plan_of(tx_input):
    """amountIn, minProfit, builderShareBps and recipient of the Plan in execute(Plan) calldata."""
    if not tx_input.startswith(EXECUTE):
        return None
    w = words("0x" + tx_input[10:])
    head = w[0] // 32  # the Plan tuple is dynamic: word 0 is its offset
    return {"amount_in": w[head], "min_profit": w[head + 2], "share_bps": w[head + 3],
            "recipient": "0x%040x" % w[head + 4]}


def flatten(call, out=None):
    """Every call of a callTracer tree, depth first: (from, to, value, selector, error)."""
    out = [] if out is None else out
    to = (call.get("to") or "").lower()
    out.append((call.get("from", "").lower(), to, int(call.get("value", "0x0"), 16), (call.get("input") or "")[:10],
                call.get("error")))
    for child in call.get("calls", []):
        flatten(child, out)
    return out


def payee_of(plan, operator):
    """Who the remainder goes to: the plan's recipient, or the operator (the caller) at address(0)."""
    return operator if int(plan["recipient"], 16) == 0 else plan["recipient"]


def payouts(calls, executor, coinbase, payee, profit, paid, share_bps):
    """The executor's value transfers to the coinbase and to the payee (the recipient, or the caller),
    and whether each one matches the plan. Share 0 sends nothing to the coinbase, share 10000 nothing
    to the payee. Value to anyone else (WETH deposit, the PoolManager) is the stray-value check's job.
    A recipient equal to the coinbase gets two transfers and fails both checks: not a BEX case."""
    sent_to = lambda addr: [v for frm, to, v, _, _ in calls if frm == executor and to == addr and v > 0]
    to_coinbase, to_payee = sent_to(coinbase), sent_to(payee)
    remainder = profit - paid
    coinbase_ok = to_coinbase == ([paid] if paid else []) and paid == profit * share_bps // 10_000
    payee_ok = to_payee == ([remainder] if remainder else [])
    return coinbase_ok, payee_ok, to_coinbase, to_payee


def self_test():
    ex, cb, op, rc = "0xe", "0xc", "0xo", "0x" + "ab" * 20
    call = lambda to, v: (ex, to, v, "0x", None)
    assert payouts([call(cb, 100)], ex, cb, op, 100, 100, 10_000)[:2] == (True, True)
    assert payouts([call(cb, 50), call(op, 50)], ex, cb, op, 100, 50, 5_000)[:2] == (True, True)
    assert payouts([call(op, 100)], ex, cb, op, 100, 0, 0)[:2] == (True, True)
    assert payouts([call(cb, 100)], ex, cb, op, 100, 50, 5_000)[:2] == (False, False)
    # a recipient: the remainder goes there, and a transfer to the operator instead is a failure
    assert payee_of({"recipient": "0x" + "0" * 40}, op) == op
    assert payee_of({"recipient": rc}, op) == rc
    assert payouts([call(cb, 50), call(rc, 50)], ex, cb, rc, 100, 50, 5_000)[:2] == (True, True)
    assert payouts([call(cb, 50), call(op, 50)], ex, cb, rc, 100, 50, 5_000)[:2] == (True, False)
    assert payouts([call(cb, 100), call(rc, 1)], ex, cb, rc, 100, 100, 10_000)[:2] == (True, False)
    # a wrap or a V4 settle sends value elsewhere: not this check's business
    assert payouts([call(cb, 50), call(WETH, 7), call(POOL_MANAGER, 9), call(rc, 50)], ex, cb, rc, 100, 50, 5_000)[:2] == (True, True)
    print("self-test OK")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("tx", nargs="?")
    ap.add_argument("--self-test", action="store_true", help="check the payout logic and exit")
    ap.add_argument("--executor", default=os.environ.get("BEX_EXECUTOR", MAINNET_EXECUTOR))
    ap.add_argument("--operator", default=os.environ.get("BEX_OPERATOR"))
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if not args.tx:
        ap.error("give a transaction hash")
    url = os.environ.get("BEX_RPC_HTTP")
    if not url:
        sys.exit("set BEX_RPC_HTTP to an Ethereum JSON-RPC URL with debug_traceTransaction")
    rpc = Rpc(url)
    executor = args.executor.lower()
    failed = []

    def check(ok, msg):
        print(("OK   " if ok else "FAIL ") + msg)
        if not ok:
            failed.append(msg)

    receipt = rpc("eth_getTransactionReceipt", [args.tx])
    if receipt is None:
        sys.exit(f"no receipt for {args.tx}: not mined, or the node does not have it")
    tx = rpc("eth_getTransactionByHash", [args.tx])
    block_tag = receipt["blockNumber"]
    block = rpc("eth_getBlockByNumber", [block_tag, True])
    coinbase, basefee = block["miner"].lower(), int(block["baseFeePerGas"], 16)
    operator = (args.operator or tx["from"]).lower()
    index = int(receipt["transactionIndex"], 16)

    # 1. Receipt, sender and the CycleExecuted log.
    check(int(receipt["status"], 16) == 1,
          f"receipt status 1, block {int(block_tag, 16)}, index {index} of {len(block['transactions'])}")
    if args.operator:
        check(tx["from"].lower() == operator, f"from the operator {operator}")
    else:
        print(f"INFO from-operator: not checked (no --operator), sender {operator}")
    check((tx["to"] or "").lower() == executor, f"to the executor {executor}")
    logs = [l for l in receipt["logs"] if l["address"].lower() == executor and l["topics"][:1] == [CYCLE_EXECUTED]]
    check(len(logs) == 1, "one CycleExecuted log from the executor")
    if not logs:
        sys.exit(1)
    amount_in, profit, paid = words(logs[0]["data"])
    plan = plan_of(tx["input"])
    check(plan is not None, "the transaction calls execute(Plan)")
    if plan is None:
        sys.exit(1)

    # 2. Payment against the plan.
    calls = flatten(rpc("debug_traceTransaction", [args.tx, {"tracer": "callTracer"}]))
    payee = payee_of(plan, operator)
    who = "operator (plan recipient 0)" if payee == operator else f"recipient {payee}"
    coinbase_ok, payee_ok, to_coinbase, to_payee = payouts(
        calls, executor, coinbase, payee, profit, paid, plan["share_bps"])
    check(coinbase_ok, f"coinbase received {to_coinbase} = paidToCoinbase {paid} = profit {profit} x {plan['share_bps']} bps")
    check(payee_ok, f"{who} received {to_payee} = profit - paidToCoinbase = {profit - paid}")
    check(profit >= plan["min_profit"] and amount_in == plan["amount_in"],
          f"profit {profit} >= plan minProfit {plan['min_profit']}, amountIn {amount_in} = plan amountIn")
    check(not any(err for *_, err in calls), "no internal call error")

    # 3. Where value went, and no approvals.
    swapped = {to for _, to, _, sel, _ in calls if sel in SWAPS}
    allowed = {coinbase, payee, executor, POOL_MANAGER} | swapped
    stray = [(to, value, sel) for _, to, value, sel, _ in calls
             if value > 0 and to not in allowed and not (to == WETH and sel == DEPOSIT)]
    check(not stray, f"no ETH value outside the pools, the PoolManager, WETH deposit(), the payee and the coinbase {stray}")
    check(not any(sel == APPROVE for *_, sel, _ in calls) and not any(l["topics"][:1] == [APPROVAL] for l in receipt["logs"]),
          "no approve call and no Approval log")

    # 4. The operator refill right after the execute.
    gas_used = int(receipt["gasUsed"], 16)
    refills = [(int(t["transactionIndex"], 16), int(t["value"], 16)) for t in block["transactions"]
               if t["from"].lower() == coinbase and (t["to"] or "").lower() == operator]
    ours = [value for i, value in refills if i == index + 1]  # two executes in a block have two refills
    check(ours == [gas_used * basefee],
          f"refill at index {index + 1} = gasUsed {gas_used} x basefee {basefee} = {gas_used * basefee} wei; all refills {refills}")

    # 5. Nothing left in the executor.
    tokens = sorted({to for _, to, _, sel, _ in calls if sel in (BALANCE_OF, TRANSFER, APPROVE)})
    dust = {t: int(rpc("eth_call", [{"to": t, "data": BALANCE_OF + executor[2:].rjust(64, "0")}, block_tag]) or "0x0", 16)
            for t in tokens}
    dust["ETH"] = int(rpc("eth_getBalance", [executor, block_tag]), 16)
    check(all(v == 0 for v in dust.values()), f"executor balances after the block: {dust}")

    print(f"INFO amountIn {amount_in / 1e18} ETH, cycleId {logs[0]['topics'][1]}, tag {logs[0]['topics'][2]}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()

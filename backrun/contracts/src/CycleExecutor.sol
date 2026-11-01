// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Leg, Plan, V2, V4, Venues, BadLeg, ProfitBelowPlan, UnexpectedCallback} from "./Types.sol";
import {Pools} from "./lib/Pools.sol";
import {V2Reader} from "./lib/V2Reader.sol";
import {V4Reader} from "./lib/V4Reader.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";

error TipFailed();
error RemainderFailed();

/// Runs a Uniswap cycle of at least 2 legs without capital: the first leg is a flash swap repaid from the
/// last leg's output. Checks the realised profit against the plan, pays the builder's share to
/// block.coinbase and the rest to the plan's recipient (the caller when it is address(0)), in ETH.
/// ETH and WETH are one asset throughout.
///
/// No owner, no pause. The contract keeps no profit between transactions; what a partial fill leaves here
/// goes to block.coinbase with `sweep`.
///
/// Flash chain: leg i runs, and legs i+1.. run from inside the first leg's callback (V2/V3 swap
/// callback, or the PoolManager unlock for V4), which repays the first leg last.
///
/// Each leg is funded with what the previous leg actually delivered: this contract's balance increase in
/// the output token, never the pool's nominal amount. A balance already here (a partial fill's leftover)
/// can never fund a leg, and a token that loses some of a transfer in transit passes on what arrived.
contract CycleExecutor is IUnlockCallback {
    using V4Reader for IPoolManager;

    // EIP-1153 transient slots.
    uint256 private constant T_EXPECTED_SENDER = 0; // the only address whose callback is accepted next
    uint256 private constant T_RUNNING = 1; // the cycle id while `execute` runs, else 0 (re-entrancy guard)
    uint256 private constant T_LEG = 2; // the leg whose callback is pending
    uint256 private constant T_OUT_BEFORE = 3; // the first V2/V3 leg's output balance before its swap

    address private immutable V2_FACTORY;
    bytes32 private immutable V2_INIT_HASH;
    address private immutable V3_FACTORY;
    bytes32 private immutable V3_INIT_HASH;
    IPoolManager public immutable poolManager;
    address private immutable WETH;

    /// `tag` is the plan's, as the caller chose it: for attribution and stats, not authenticated.
    event CycleExecuted(
        bytes32 indexed cycleId, bytes32 indexed tag, uint256 amountIn, uint256 profit, uint256 paidToCoinbase
    );

    constructor(Venues memory v) {
        V2_FACTORY = v.v2Factory;
        V2_INIT_HASH = v.v2InitHash;
        V3_FACTORY = v.v3Factory;
        V3_INIT_HASH = v.v3InitHash;
        poolManager = IPoolManager(v.poolManager);
        WETH = v.weth;
    }

    function venues() external view returns (Venues memory) {
        return _venues();
    }

    function _venues() private view returns (Venues memory) {
        return Venues(V2_FACTORY, V2_INIT_HASH, V3_FACTORY, V3_INIT_HASH, address(poolManager), WETH);
    }

    receive() external payable {}

    /// Sends this contract's whole balance of `token` (address(0) is ETH) to block.coinbase, so a
    /// partial fill's leftover never stays stuck. Anyone may call it. Reverts UnexpectedCallback while
    /// a cycle runs.
    function sweep(address token) external {
        if (_tload(T_RUNNING) != 0) revert UnexpectedCallback();
        Currency c = Currency.wrap(token);
        c.transfer(block.coinbase, c.balanceOfSelf());
    }

    /// Runs the plan's cycle and pays out the profit. Anyone may call it: the plan names who is paid.
    /// Reverts BadLeg (bad shape, share or pool), UnexpectedCallback (re-entry), ProfitBelowPlan
    /// (profit under minProfit), TipFailed or RemainderFailed (a payee refuses ETH).
    function execute(Plan calldata plan) external {
        if (_tload(T_RUNNING) != 0) revert UnexpectedCallback();
        Leg[] memory legs = plan.legs;
        Pools.validate(_venues(), legs);
        if (plan.builderShareBps > 10_000 || plan.amountIn > type(uint128).max) revert BadLeg();
        _checkPools(legs);

        bytes32 id = Pools.cycleId(legs);
        _tstore(T_RUNNING, uint256(id));
        uint256 before = _holdings();
        _runFrom(0, plan.amountIn, legs, false);
        uint256 afterwards = _holdings();
        if (afterwards < before + plan.minProfit) revert ProfitBelowPlan();

        uint256 profit = afterwards - before;
        uint256 tip = profit * plan.builderShareBps / 10_000;
        uint256 eth = address(this).balance;
        if (eth < profit) IWETH(WETH).withdraw(profit - eth);
        // Both payouts run with the re-entrancy guard still set: neither payee can re-enter `execute` or `sweep`.
        if (tip != 0) {
            (bool ok,) = block.coinbase.call{value: tip}("");
            if (!ok) revert TipFailed();
        }
        if (profit != tip) {
            // A recipient that refuses ETH reverts the whole cycle: it is the sender's own choice.
            address payee = plan.recipient == address(0) ? msg.sender : plan.recipient;
            (bool ok,) = payee.call{value: profit - tip}("");
            if (!ok) revert RemainderFailed();
        }
        _tstore(T_RUNNING, 0);
        _tstore(T_LEG, 0); // T_EXPECTED_SENDER is already 0: every callback spends it
        _tstore(T_OUT_BEFORE, 0);
        emit CycleExecuted(id, plan.tag, plan.amountIn, profit, tip);
    }

    // ---- callbacks ----

    function uniswapV2Call(address sender, uint256, uint256, bytes calldata data) external {
        if (sender != address(this)) revert UnexpectedCallback();
        (, uint256 amountIn, Leg[] memory legs) = _consume(data); // only the first leg sends data
        _closeLoop(legs, _next(0, _receivedByFirstLeg(legs), legs, false), amountIn);
        Currency.wrap(legs[0].tokenIn).transfer(msg.sender, amountIn);
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external {
        (uint256 i,, Leg[] memory legs) = _consume(data);
        bool zfo = Pools.zeroForOne(legs[i]);
        // A partial fill at the price limit asks less than amountIn; the unspent intermediate token stays
        // here (anyone can `sweep` it to block.coinbase). ETH+WETH accounting is unaffected.
        uint256 owed = uint256(zfo ? amount0Delta : amount1Delta);
        if (i == 0) _closeLoop(legs, _next(0, _receivedByFirstLeg(legs), legs, false), owed);
        Currency.wrap(legs[i].tokenIn).transfer(msg.sender, owed);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (uint256 i, uint256 amountIn, Leg[] memory legs) = _consume(data);
        return abi.encode(_v4Leg(i, amountIn, legs));
    }

    // ---- chain ----

    /// Runs legs i.. on `amountIn` of leg i's tokenIn and returns the final output (0 when leg i is
    /// the first V2/V3 leg: its callback runs and repays the chain).
    function _runFrom(uint256 i, uint256 amountIn, Leg[] memory legs, bool inUnlock) private returns (uint256) {
        Leg memory leg = legs[i];
        if (leg.version == V4) {
            if (inUnlock) return _v4Leg(i, amountIn, legs);
            _expect(address(poolManager), i);
            return abi.decode(poolManager.unlock(abi.encode(i, amountIn, legs)), (uint256));
        }
        bool zfo = Pools.zeroForOne(leg);
        address pool = _pool(leg);
        uint256 before = _balance(leg.tokenOut);
        if (i == 0) _tstore(T_OUT_BEFORE, before); // the first leg's callback measures against it
        if (leg.version == V2) {
            (uint256 rIn, uint256 rOut) = V2Reader.reserves(pool, zfo);
            uint256 out = V2Reader.amountOut(amountIn, rIn, rOut);
            bytes memory data;
            if (i == 0) {
                _expect(pool, 0);
                data = abi.encode(i, amountIn, legs);
            } else {
                Currency.wrap(leg.tokenIn).transfer(pool, amountIn);
            }
            (uint256 out0, uint256 out1) = zfo ? (uint256(0), out) : (out, uint256(0));
            IUniswapV2Pair(pool).swap(out0, out1, address(this), data);
        } else {
            _expect(pool, i);
            IUniswapV3Pool(pool).swap(address(this), zfo, int256(amountIn), _limit(zfo), abi.encode(i, amountIn, legs));
        }
        return i == 0 ? 0 : _next(i, _balance(leg.tokenOut) - before, legs, inUnlock);
    }

    /// Inside unlock: swap, take the output, and settle the input — after the rest of the chain
    /// for the first leg, straight away for a later one.
    function _v4Leg(uint256 i, uint256 amountIn, Leg[] memory legs) private returns (uint256 last) {
        Leg memory leg = legs[i];
        bool zfo = Pools.zeroForOne(leg);
        BalanceDelta d = poolManager.swap(Pools.v4Key(leg), SwapParams(zfo, -int256(amountIn), _limit(zfo)), "");
        (int128 dIn, int128 dOut) = zfo ? (d.amount0(), d.amount1()) : (d.amount1(), d.amount0());
        uint256 owed = uint128(-dIn); // < amountIn on a partial fill: the rest stays here, as for V3
        uint256 out = _balance(leg.tokenOut);
        poolManager.take(Currency.wrap(leg.tokenOut), address(this), uint128(dOut));
        out = _balance(leg.tokenOut) - out;
        if (i == 0) {
            last = _next(0, out, legs, true);
            _closeLoop(legs, last, owed);
            _settle(leg.tokenIn, owed);
        } else {
            _settle(leg.tokenIn, owed);
            last = _next(i, out, legs, true);
        }
    }

    /// Hands leg i's output to leg i+1, converting between ETH and WETH when the forms differ.
    function _next(uint256 i, uint256 out, Leg[] memory legs, bool inUnlock) private returns (uint256) {
        if (i + 1 == legs.length) return out;
        _convert(legs[i].tokenOut, legs[i + 1].tokenIn, out);
        return _runFrom(i + 1, out, legs, inUnlock);
    }

    /// Before the first leg is repaid: the chain must have returned at least what it owes, in its form.
    function _closeLoop(Leg[] memory legs, uint256 last, uint256 owed) private {
        if (last < owed) revert ProfitBelowPlan();
        _convert(legs[legs.length - 1].tokenOut, legs[0].tokenIn, owed);
    }

    function _settle(address token, uint256 amount) private {
        if (token == address(0)) {
            poolManager.settle{value: amount}();
            return;
        }
        Currency c = Currency.wrap(token);
        poolManager.sync(c);
        c.transfer(address(poolManager), amount);
        poolManager.settle();
    }

    /// `validate` guarantees from and to are the same asset, so differing means one is ETH, the other WETH.
    function _convert(address from, address to, uint256 amount) private {
        if (from == to) return;
        if (from == address(0)) IWETH(WETH).deposit{value: amount}();
        else IWETH(WETH).withdraw(amount);
    }

    // ---- checks and state ----

    /// Every leg's pool exists before any call is made to one.
    function _checkPools(Leg[] memory legs) private view {
        for (uint256 i; i < legs.length; ++i) {
            Leg memory leg = legs[i];
            if (leg.version == V4) {
                (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(Pools.v4Id(Pools.v4Key(leg)));
                if (sqrtPriceX96 == 0) revert BadLeg();
            } else if (_pool(leg).code.length == 0) {
                revert BadLeg();
            }
        }
    }

    function _pool(Leg memory leg) private view returns (address) {
        Venues memory v = _venues();
        return leg.version == V2
            ? Pools.v2Pair(v, leg.tokenIn, leg.tokenOut)
            : Pools.v3Pool(v, leg.tokenIn, leg.tokenOut, leg.fee);
    }

    function _limit(bool zfo) private pure returns (uint160) {
        return zfo ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    /// Inside the first V2/V3 leg's callback: what its pool's transfer added here.
    function _receivedByFirstLeg(Leg[] memory legs) private view returns (uint256) {
        return _balance(legs[0].tokenOut) - _tload(T_OUT_BEFORE);
    }

    function _balance(address token) private view returns (uint256) {
        return Currency.wrap(token).balanceOfSelf();
    }

    function _holdings() private view returns (uint256) {
        return address(this).balance + IWETH(WETH).balanceOf(address(this));
    }

    /// Checks the caller is the pool this contract is waiting on and spends that expectation.
    function _consume(bytes calldata data) private returns (uint256 i, uint256 amountIn, Leg[] memory legs) {
        if (msg.sender != address(uint160(_tload(T_EXPECTED_SENDER)))) revert UnexpectedCallback();
        _tstore(T_EXPECTED_SENDER, 0);
        (i, amountIn, legs) = abi.decode(data, (uint256, uint256, Leg[]));
        if (i != _tload(T_LEG)) revert UnexpectedCallback();
    }

    function _expect(address pool, uint256 i) private {
        _tstore(T_EXPECTED_SENDER, uint160(pool));
        _tstore(T_LEG, i);
    }

    function _tload(uint256 slot) private view returns (uint256 v) {
        assembly {
            v := tload(slot)
        }
    }

    function _tstore(uint256 slot, uint256 v) private {
        assembly {
            tstore(slot, v)
        }
    }
}

// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ForkTest, _v, WETH} from "./Fork.t.sol";
import {IUniswapV2Router} from "./IQuoters.sol";
import {IQuoterV2, QuoteParams, IV4Quoter, QuoteExactSingleParams} from "./IQuoters.sol";
import {LegSim} from "../src/lib/LegSim.sol";
import {LegProbe} from "./LegProbe.sol";
import {Pools} from "../src/lib/Pools.sol";
import {V2Reader} from "../src/lib/V2Reader.sol";
import {Quote, RateFilter} from "../src/lib/RateFilter.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {FeeToken, IV3FactoryCreate, IV3PoolSeed} from "./CycleExecutor.t.sol";
import {Leg, V2, V3, V4, TooManyCrossings} from "../src/Types.sol";

contract LegSimHarness {
    function amountOut(Leg memory l, uint256 x) external view returns (uint256 o, uint8 c) {
        return LegProbe.amountOut(_v(), l, x);
    }

    function cycleOut(Leg[] memory l, uint256 x) external view returns (uint256 o, uint8 c) {
        return LegProbe.cycleOut(_v(), l, x);
    }

    function tryCycleOut(Leg[] memory l, uint256 x) external view returns (uint256 o, uint8 c, uint8 s, bool f) {
        return LegSim.tryCycleOut(_v(), l, x);
    }
}

contract LegSimTest is ForkTest {
    using StateLibrary for IPoolManager;

    address constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;
    address constant V4_QUOTER = 0x52F0E24D1c21C8A0cB1e5a5dD6198556BD9E1203;

    address constant V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    LegSimHarness h;
    uint256 feasibleCount;

    function setUp() public override {
        super.setUp();
        h = new LegSimHarness();
    }

    /// True when the leg is within MAX_TICK_CROSSINGS; otherwise asserts LegSim refuses.
    function _feasible(Leg memory l, uint256 x) internal view returns (bool ok) {
        (,, ok) = _try(l, x);
    }

    function _v3Check(Leg memory l, uint256 x, string memory tag) internal {
        (uint256 theirs,, uint32 crossed,) =
            IQuoterV2(QUOTER_V2).quoteExactInputSingle(QuoteParams(l.tokenIn, l.tokenOut, x, l.fee, 0));
        if (!_feasible(l, x)) {
            // the quoter itself crosses (about) as many ticks as our bound forbids
            assertGe(crossed, LegSim.MAX_TICK_CROSSINGS, "refused but quoter crossed few");
            return;
        }
        feasibleCount++;
        (uint256 ours,) = LegProbe.amountOut(_v(), l, x);
        assertEq(ours, theirs, tag);
    }

    function _sweep(uint24 fee, int24 spacing) internal {
        uint256[6] memory ins = [uint256(0.01 ether), 0.1 ether, 1 ether, 10 ether, 50 ether, 200 ether];
        for (uint256 i; i < 6; i++) {
            _v3Check(Leg(V3, WETH, USDC, fee, spacing), ins[i], "weth->usdc");
            _v3Check(Leg(V3, USDC, WETH, fee, spacing), ins[i] * 3000e6 / 1e18, "usdc->weth");
        }
    }

    function test_v3_matchesQuoterV2_bothDirections_sweep() public {
        _sweep(100, 1);
        // 200 ETH crosses 31 / 49 ticks: only 50 ETH-class and 200 ETH weth->usdc fit under 32
        assertEq(feasibleCount, 11, "feasible sizes compared exactly");
    }

    function test_v3_spacing10_matchesQuoterV2() public {
        _sweep(500, 10);
    }

    function _v4Check(bool zfo, uint256 x) internal {
        Leg memory l = zfo ? Leg(V4, address(0), USDC, 100, 1) : Leg(V4, USDC, address(0), 100, 1);
        PoolKey memory key = Pools.v4Key(l);
        assertTrue(_feasible(l, x), "v4 size must be feasible");
        (uint256 ours,) = LegProbe.amountOut(_v(), l, x);
        (uint256 theirs,) = IV4Quoter(V4_QUOTER).quoteExactInputSingle(QuoteExactSingleParams(key, zfo, uint128(x), ""));
        assertEq(ours, theirs, zfo ? "eth->usdc" : "usdc->eth");
    }

    function test_v4_matchesV4Quoter() public {
        _v4Check(true, 1 ether);
        _v4Check(true, 20 ether);
        _v4Check(false, 3000e6);
        _v4Check(false, 60000e6);
    }

    /// V4 swaps at the LP fee combined with the protocol fee of the swap direction. At FORK_BLOCK the
    /// ETH/USDC pool charges 25 pips both ways (102425), which cannot tell the directions apart; here the
    /// controller sets 250 pips zeroForOne and 500 oneForZero (packed oneForZero << 12 | zeroForOne).
    function test_v4_protocolFeePerDirection_matchesV4Quoter() public {
        IPoolManager pm = IPoolManager(POOL_MANAGER);
        uint24 fee = (500 << 12) | 250;
        vm.prank(pm.protocolFeeController());
        pm.setProtocolFee(Pools.v4Key(Leg(V4, address(0), USDC, 100, 1)), fee);
        (,, uint24 set,) = pm.getSlot0(PoolId.wrap(ETH_USDC_V4_ID));
        assertEq(set, fee);

        _v4Check(true, 1 ether);
        _v4Check(true, 20 ether);
        _v4Check(false, 3000e6);
        _v4Check(false, 60000e6);
    }

    function test_v2_matchesRouterGetAmountsOut() public view {
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = GTC;
        uint256[3] memory ins = [uint256(1 ether), 0.01 ether, 25 ether];
        for (uint256 i; i < 3; i++) {
            uint256[] memory amts = IUniswapV2Router(V2_ROUTER).getAmountsOut(ins[i], path);
            (uint256 out,) = LegProbe.amountOut(_v(), Leg(V2, WETH, GTC, 3000, 0), ins[i]);
            assertEq(out, amts[1]);
        }
    }

    function test_v3_wrongLegSpacing_stillMatchesQuoter() public {
        // the pool's own spacing (1) governs, not the leg's
        uint256[3] memory ins = [uint256(1 ether), 10 ether, 50 ether];
        for (uint256 i; i < 3; i++) {
            _v3Check(Leg(V3, WETH, USDC, 100, 60), ins[i], "weth->usdc bad spacing");
            _v3Check(Leg(V3, USDC, WETH, 100, 60), ins[i] * 3000e6 / 1e18, "usdc->weth bad spacing");
        }
        assertEq(feasibleCount, 6);
    }

    function test_steps_boundCoversCrossings() public pure {
        assertGe(LegSim.MAX_STEPS, LegSim.MAX_TICK_CROSSINGS);
    }

    function test_crossings_pinnedToQuoter_1bp() public {
        Leg memory l = Leg(V3, WETH, USDC, 100, 1);
        (, uint8 c) = LegProbe.amountOut(_v(), l, 200 ether);
        (,, uint32 q,) = IQuoterV2(QUOTER_V2).quoteExactInputSingle(QuoteParams(WETH, USDC, 200 ether, 100, 0));
        assertEq(c, 31);
        assertEq(q, 31);
    }

    function test_crossings_vsQuoter_spacing10() public {
        uint256[4] memory ins = [uint256(1 ether), 50 ether, 500 ether, 2000 ether];
        uint256 agree;
        for (uint256 i; i < 4; i++) {
            Leg memory l = Leg(V3, WETH, USDC, 500, 10);
            (,, uint32 q,) = IQuoterV2(QUOTER_V2).quoteExactInputSingle(QuoteParams(WETH, USDC, ins[i], 500, 0));
            (, uint8 c, bool ok) = _try(l, ins[i]);
            if (!ok) continue;
            // on this pool the quoter's count is ours + 1 at every size (it also counts the initialized tick at the start range)
            assertEq(uint256(c) + 1, q, "crossings + 1 == quoter");
            agree++;
        }
        assertEq(agree, 3);
    }

    /// One leg against its own bounds (not the cycle budgets); a refusal must be TooManyCrossings.
    function _try(Leg memory l, uint256 x) internal view returns (uint256 o, uint8 c, bool ok) {
        try h.amountOut(l, x) returns (uint256 o_, uint8 c_) {
            return (o_, c_, true);
        } catch (bytes memory e) {
            assertEq(bytes4(e), TooManyCrossings.selector, "refusal is TooManyCrossings");
        }
    }

    /// The cycle budget is on the weighted sum over the legs: at the largest input the 2-leg cycle fits,
    /// each leg still fits on its own at 1 ether more input, the cycle does not.
    function test_cycleBudget_sumsCrossingsOverLegs() public {
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V3, USDC, WETH, 500, 10);
        Leg[] memory first = new Leg[](1);
        first[0] = legs[0];
        Leg[] memory second = new Leg[](1);
        second[0] = legs[1];

        (uint256 mid, uint8 c0,) = _try(legs[0], 100 ether);
        (, uint8 c1,) = _try(legs[1], mid);
        (, uint8 c,, bool ok) = h.tryCycleOut(legs, 100 ether);
        assertTrue(ok, "100 ETH fits");
        assertEq(c, c0 + c1, "crossings are summed");

        (uint256 lo, uint256 hi) = (100 ether, 10_000 ether);
        while (hi - lo > 1 ether) {
            uint256 m = (lo + hi) / 2;
            (,,, ok) = h.tryCycleOut(legs, m);
            if (ok) lo = m;
            else hi = m;
        }
        uint256 x = hi + 1 ether;
        (,,, ok) = h.tryCycleOut(first, x);
        assertTrue(ok, "leg 0 alone fits");
        (mid,) = h.amountOut(legs[0], x);
        (,,, ok) = h.tryCycleOut(second, mid);
        assertTrue(ok, "leg 1 alone fits");
        (,,, ok) = h.tryCycleOut(legs, x);
        assertFalse(ok, "together they do not");
        vm.expectRevert(TooManyCrossings.selector);
        h.cycleOut(legs, x);
    }

    function test_crossings_countedAndBounded() public {
        Leg memory l = Leg(V3, WETH, USDC, 100, 1);
        (, uint8 c1) = LegProbe.amountOut(_v(), l, 0.001 ether);
        assertEq(c1, 0);
        vm.expectRevert(TooManyCrossings.selector);
        h.amountOut(l, 5000 ether);
    }

    function test_tryCycleOut_infeasibleInsteadOfRevert() public view {
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V3, WETH, USDC, 100, 1);
        legs[1] = Leg(V3, USDC, WETH, 500, 10);
        (, uint8 c,, bool ok) = h.tryCycleOut(legs, 0.001 ether);
        assertTrue(ok);
        assertEq(c, 0);
        (,,, ok) = h.tryCycleOut(legs, 5000 ether);
        assertFalse(ok);
        (uint256 out,) = h.cycleOut(legs, 1 ether);
        (uint256 mid,) = LegProbe.amountOut(_v(), legs[0], 1 ether);
        (uint256 end,) = LegProbe.amountOut(_v(), legs[1], mid);
        assertEq(out, end);
    }

    function test_virtualReserves_reproduceSmallSwap() public view {
        (uint256 rin, uint256 rout, uint256 g) = LegProbe.virtualReserves(_v(), Leg(V3, WETH, USDC, 100, 1));
        uint256 x = 0.001 ether;
        uint256 cp = (rout * g * x) / (rin * 1e6 + g * x);
        (uint256 exact,) = LegProbe.amountOut(_v(), Leg(V3, WETH, USDC, 100, 1), x);
        assertApproxEqRel(cp, exact, 1e13);
    }

    /// Advancing in pieces lands within a few wei of one exact swap of the total, with the same units.
    /// The cycle starts in USDC so that the intermediate token (WETH) is fine-grained. Through USDC, a
    /// 1-unit rounding difference would become about 3e8 wei of WETH (at about 3000 USDC per WETH).
    function test_advance_piecesMatchOneSwap() public view {
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V3, USDC, WETH, 100, 1);
        legs[1] = Leg(V3, WETH, USDC, 500, 10);
        uint256 x = 100_000e6;
        (uint256 exact, uint8 c, uint8 steps, bool ok) = LegSim.tryCycleOut(_v(), legs, x);
        assertTrue(ok, "exact swap feasible");
        assertGe(c, 2, "crosses at least 2 initialized ticks");

        LegSim.Walk memory w = LegSim.startWalk(RateFilter.quotes(_v(), legs));
        assertTrue(LegSim.advance(_v(), legs, w, x / 3));
        assertTrue(LegSim.advance(_v(), legs, w, x - x / 3));
        assertEq(w.x, x);
        assertApproxEqAbs(w.out, exact, 10 * legs.length);
        assertEq(uint256(w.crossings[0]) + w.crossings[1], c, "same crossings");
        // Neither leg of the exact swap ends exactly on a boundary here, so no +1 allowance is needed.
        assertEq(LegSim.units(w), uint256(LegSim.W_CROSS) * c + steps, "same budget units");
    }

    /// V2 continuation from the effective reserves equals one swap of the total.
    function test_advance_v2EndState_isUnbiased() public view {
        Leg[] memory legs = new Leg[](2);
        legs[0] = Leg(V2, WETH, USDC, 3000, 0);
        legs[1] = Leg(V3, USDC, WETH, 500, 10);
        Quote[] memory q = RateFilter.quotes(_v(), legs);
        (uint256 y1, uint256 y2) = (7.3 ether, 41.9 ether);
        LegSim.Walk memory w = LegSim.startWalk(q);
        assertTrue(LegSim.advance(_v(), legs, w, y1));
        assertTrue(LegSim.advance(_v(), legs, w, y2));
        assertApproxEqAbs(
            q[0].rout - w.ends[0].rout, V2Reader.amountOut(y1 + y2, q[0].rin, q[0].rout), 2, "leg 0 total"
        );
        assertEq(w.boundaries[0], 0, "V2 has no boundaries");
    }

    /// A zero-liquidity gap past the first initialized tick: the advance lands exactly on c + 10 (its
    /// input is used up there), then the gap rule moves the leg to c + 20 and crosses it. The leg ends
    /// with the deep range's liquidity, and both crossings are counted.
    function test_advance_crossesZeroLiquidityGap() public {
        address t = address(0x7e57); // below WETH: token0, so WETH -> t is oneForZero
        vm.etch(t, address(new FeeToken()).code);
        vm.deal(address(this), 1000 ether);
        IWETH(WETH).deposit{value: 1000 ether}();
        int24 c = -69080;
        address pool = IV3FactoryCreate(_v().v3Factory).createPool(t, WETH, 500);
        IV3PoolSeed(pool).initialize(TickMath.getSqrtPriceAtTick(c));
        IV3PoolSeed(pool).mint(address(this), c - 100, c + 10, 5e20, abi.encode(t));
        IV3PoolSeed(pool).mint(address(this), c + 20, c + 5000, 1.5e23, abi.encode(t));

        Leg[] memory legs = new Leg[](1);
        legs[0] = Leg(V3, WETH, t, 500, 10);
        // the input whose swap step reaches c + 10 with nothing left (computeSwapStep's exact-in rounding)
        uint256 a = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(c), TickMath.getSqrtPriceAtTick(c + 10), 5e20, true
        );
        uint256 dx = a + FullMath.mulDivRoundingUp(a, 500, 1e6 - 500);

        LegSim.Walk memory w = LegSim.startWalk(RateFilter.quotes(_v(), legs));
        assertTrue(LegSim.advance(_v(), legs, w, dx));
        assertEq(w.ends[0].liquidity, 1.5e23, "past the gap, deep liquidity");
        assertEq(w.ends[0].sqrtPriceX96, TickMath.getSqrtPriceAtTick(c + 20), "at the gap's far tick");
        assertEq(w.crossings[0], 2, "both ticks crossed");
        assertEq(w.boundaries[0], 2);
        assertEq(LegSim.units(w), 2 + 1 + 2 * uint256(LegSim.W_CROSS));
    }

    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata data) external {
        address t = abi.decode(data, (address));
        (uint256 owedT, uint256 owedWeth) = t < WETH ? (owed0, owed1) : (owed1, owed0);
        FeeToken(t).mint(msg.sender, owedT);
        IERC20(WETH).transfer(msg.sender, owedWeth);
    }
}

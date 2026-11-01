// SPDX-License-Identifier: BSD-3-Clause-Clear
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {V3Reader} from "../src/lib/V3Reader.sol";

/// Hand-computed bitmap math for negative ticks and word boundaries (no fork).
contract TickWordTest is Test {
    function test_negativeTick_spacing60_wordAndBit() public pure {
        // tick -100, spacing 60: compressed = floor(-100/60) = -2; word = -2 >> 8 = -1; bit = 254
        assertEq(V3Reader.wordPosition(-100, 60, true), -1);
        // lte: word with bit 254 and bit 250 set -> highest set bit <= 254 is 254 -> compressed -2 -> tick -120
        uint256 word = (1 << 254) | (1 << 250);
        (int24 next, bool init) = V3Reader.resolve(word, -100, 60, true);
        assertEq(next, -120);
        assertTrue(init);
        // only bit 250 set -> compressed -6 -> tick -360
        (next, init) = V3Reader.resolve(1 << 250, -100, 60, true);
        assertEq(next, -360);
        assertTrue(init);
        // empty word -> word start: compressed - bitPos = -256 -> tick -15360, not initialized
        (next, init) = V3Reader.resolve(0, -100, 60, true);
        assertEq(next, -15360);
        assertFalse(init);
        // gt: compressed+1 = -1 -> word -1, bit 255; bit 255 set -> tick -60
        assertEq(V3Reader.wordPosition(-100, 60, false), -1);
        (next, init) = V3Reader.resolve(1 << 255, -100, 60, false);
        assertEq(next, -60);
        assertTrue(init);
        // gt, empty word: compressed -1 + (255-255) = -1 -> tick -60, not initialized
        (next, init) = V3Reader.resolve(0, -100, 60, false);
        assertEq(next, -60);
        assertFalse(init);
    }

    function test_wordBoundary() public pure {
        // spacing 1: tick 255 is last of word 0, tick 256 first of word 1, tick -1 last of word -1, -256 first of -1, -257 in -2
        assertEq(V3Reader.wordPosition(255, 1, true), 0);
        assertEq(V3Reader.wordPosition(256, 1, true), 1);
        assertEq(V3Reader.wordPosition(-1, 1, true), -1);
        assertEq(V3Reader.wordPosition(-256, 1, true), -1);
        assertEq(V3Reader.wordPosition(-257, 1, true), -2);
        // gt at 255 searches from 256 -> word 1; gt at -1 searches from 0 -> word 0
        assertEq(V3Reader.wordPosition(255, 1, false), 1);
        assertEq(V3Reader.wordPosition(-1, 1, false), 0);
        // gt at tick 255, word 1 with bit 0 set -> tick 256 initialized
        (int24 next, bool init) = V3Reader.resolve(1, 255, 1, false);
        assertEq(next, 256);
        assertTrue(init);
        // lte at tick 256 (bit 0 of word 1), bit 0 set -> 256
        (next, init) = V3Reader.resolve(1, 256, 1, true);
        assertEq(next, 256);
        assertTrue(init);
        // lte at -256, empty word: bit 0 -> -256, not initialized
        (next, init) = V3Reader.resolve(0, -256, 1, true);
        assertEq(next, -256);
        assertFalse(init);
    }
}

// SPDX-FileCopyrightText: © 2026 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";

import { Sky } from "sky/Sky.sol";
import { MkrSky } from "sky/MkrSky.sol";
import { MkrSkyFeeStepper } from "src/MkrSkyFeeStepper.sol";

contract Mkr is Sky {}

contract MkrSkyFeeStepperTest is DssTest {
    Mkr              mkr;
    Sky              sky;
    MkrSky           mkrSky;
    MkrSkyFeeStepper stepper;

    uint256 constant RATE        = 24_000;
    uint256 constant SEP_10_2026 = 1_788_998_400; // 2026-09-10 00:00:00 UTC
    uint256 constant FEE         = 5 * WAD / 100; // 5%
    uint256 constant STEP        = 1 * WAD / 100; // 1%
    uint256 constant TAU         = 91 days;

    event Tick(uint256 n, uint256 fee);

    function setUp() public {
        vm.warp(SEP_10_2026);

        mkr    = new Mkr();
        sky    = new Sky();
        mkrSky = new MkrSky(address(mkr), address(sky), RATE);
        mkr.mint(address(this), 1_000_000 * WAD);
        sky.mint(address(mkrSky), 1_000_000 * WAD * RATE);
        mkrSky.file("fee", FEE);

        stepper = new MkrSkyFeeStepper(address(mkrSky));
        stepper.file("step", STEP);
        stepper.file("cap",  WAD);
        stepper.file("tau",  TAU);
        stepper.file("rho",  SEP_10_2026);
        mkrSky.rely(address(stepper));
    }

    function testConstructor() public {
        vm.warp(SEP_10_2026 + 123);
        vm.expectEmit(true, true, true, true);
        emit Rely(address(this));
        MkrSkyFeeStepper s = new MkrSkyFeeStepper(address(mkrSky));
        assertEq(address(s.mkrSky()), address(mkrSky));
        assertEq(s.wards(address(this)), 1);
        assertEq(s.rho(), SEP_10_2026 + 123);
        assertEq(s.step(), 0);
        assertEq(s.cap(), 0);
        assertEq(s.tau(), 0);
        assertEq(s.bad(), 0);
    }

    function testAuth() public {
        checkAuth(address(stepper), "MkrSkyFeeStepper");
    }

    function testFile() public {
        stepper.file("cap", WAD / 2); // checkFileUint files value + 1, keep it below WAD
        checkFileUint(address(stepper), "MkrSkyFeeStepper", ["step", "cap", "tau", "rho", "bad"]);

        vm.expectRevert("MkrSkyFeeStepper/step-exceeds-wad");
        stepper.file("step", WAD + 1);
        vm.expectRevert("MkrSkyFeeStepper/cap-exceeds-wad");
        stepper.file("cap", WAD + 1);
        vm.expectRevert("MkrSkyFeeStepper/invalid-bad-value");
        stepper.file("bad", 2);

        // Boundaries
        stepper.file("step", WAD);
        assertEq(stepper.step(), WAD);
        stepper.file("cap", WAD);
        assertEq(stepper.cap(), WAD);
        stepper.file("bad", 1);
        assertEq(stepper.bad(), 1);
        stepper.file("bad", 0);
        assertEq(stepper.bad(), 0);
    }

    function testUnconfigured() public {
        MkrSkyFeeStepper s = new MkrSkyFeeStepper(address(mkrSky));
        mkrSky.rely(address(s));
        vm.warp(SEP_10_2026 + 100 * 365 days);
        vm.expectRevert("MkrSkyFeeStepper/tau-not-set");
        s.tick();

        s.file("tau", TAU);
        vm.expectRevert("MkrSkyFeeStepper/nothing-to-step"); // step and cap are still 0
        s.tick();
        assertEq(mkrSky.fee(), FEE);
        assertEq(s.rho(), SEP_10_2026);
    }

    function testTickTooSoon() public {
        vm.expectRevert("MkrSkyFeeStepper/too-soon");
        stepper.tick();

        vm.warp(SEP_10_2026 + TAU - 1);
        vm.expectRevert("MkrSkyFeeStepper/too-soon");
        stepper.tick();

        vm.warp(SEP_10_2026 + TAU);
        assertEq(stepper.tick(), 6 * WAD / 100);
    }

    function testTick() public {
        vm.warp(SEP_10_2026 + TAU);

        vm.expectEmit(true, true, true, true, address(mkrSky));
        emit File("fee", 6 * WAD / 100);
        vm.expectEmit(true, true, true, true, address(stepper));
        emit Tick(1, 6 * WAD / 100);
        uint256 fee = stepper.tick();

        assertEq(fee, 6 * WAD / 100);
        assertEq(mkrSky.fee(), 6 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + TAU);

        // The new fee applies to conversions
        mkr.approve(address(mkrSky), 100 * WAD);
        mkrSky.mkrToSky(address(this), 100 * WAD);
        assertEq(sky.balanceOf(address(this)), 100 * WAD * RATE * 94 / 100);
        assertEq(mkrSky.take(), 100 * WAD * RATE * 6 / 100);

        // Not twice in the same period
        vm.warp(SEP_10_2026 + 2 * TAU - 1);
        vm.expectRevert("MkrSkyFeeStepper/too-soon");
        stepper.tick();

        vm.warp(SEP_10_2026 + 2 * TAU);
        vm.expectEmit(true, true, true, true, address(stepper));
        emit Tick(1, 7 * WAD / 100);
        stepper.tick();
        assertEq(mkrSky.fee(), 7 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + 2 * TAU);
    }

    function testTickPermissionless() public {
        vm.warp(SEP_10_2026 + TAU);
        vm.prank(address(0xBEEF));
        stepper.tick();
        assertEq(mkrSky.fee(), 6 * WAD / 100);
    }

    function testTickLateStaysOnGrid() public {
        // Poked 5 days late: rho snaps to the grid, not to the poke time
        vm.warp(SEP_10_2026 + TAU + 5 days);
        stepper.tick();
        assertEq(mkrSky.fee(), 6 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + TAU);

        // The next step is due at the scheduled time even though less than tau has passed since the poke
        vm.warp(SEP_10_2026 + 2 * TAU);
        stepper.tick();
        assertEq(mkrSky.fee(), 7 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + 2 * TAU);
    }

    function testTickCatchUp() public {
        // Three full periods and a bit missed: all of them are applied at once
        vm.warp(SEP_10_2026 + 3 * TAU + 1);
        vm.expectEmit(true, true, true, true, address(stepper));
        emit Tick(3, 8 * WAD / 100);
        stepper.tick();
        assertEq(mkrSky.fee(), 8 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + 3 * TAU);

        vm.expectRevert("MkrSkyFeeStepper/too-soon");
        stepper.tick();

        vm.warp(SEP_10_2026 + 4 * TAU);
        stepper.tick();
        assertEq(mkrSky.fee(), 9 * WAD / 100);
    }

    function testTickCap() public {
        stepper.file("cap", 7 * WAD / 100);

        vm.warp(SEP_10_2026 + 5 * TAU);
        vm.expectEmit(true, true, true, true, address(stepper));
        emit Tick(5, 7 * WAD / 100);
        stepper.tick();
        assertEq(mkrSky.fee(), 7 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + 5 * TAU);

        vm.warp(SEP_10_2026 + 6 * TAU);
        vm.expectRevert("MkrSkyFeeStepper/nothing-to-step");
        stepper.tick();
        assertEq(mkrSky.fee(), 7 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + 5 * TAU);

        // Raising the cap resumes the schedule from where it stopped
        stepper.file("cap", 10 * WAD / 100);
        stepper.tick();
        assertEq(mkrSky.fee(), 8 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + 6 * TAU);
    }

    function testTickCapAtWad() public {
        mkrSky.file("fee", WAD - 1);
        vm.warp(SEP_10_2026 + TAU);
        stepper.tick();
        assertEq(mkrSky.fee(), WAD);

        vm.warp(SEP_10_2026 + 2 * TAU);
        vm.expectRevert("MkrSkyFeeStepper/nothing-to-step");
        stepper.tick();
    }

    function testTickNeverLowersFee() public {
        // Governance set the fee above the cap: the stepper does nothing
        mkrSky.file("fee", 50 * WAD / 100);
        stepper.file("cap", 10 * WAD / 100);

        vm.warp(SEP_10_2026 + 3 * TAU);
        vm.expectRevert("MkrSkyFeeStepper/nothing-to-step");
        stepper.tick();
        assertEq(mkrSky.fee(), 50 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026);
    }

    function testTickAfterManualFeeChange() public {
        // Governance changes the fee directly mid-period: the stepper keeps stepping from there
        vm.warp(SEP_10_2026 + 10 days);
        mkrSky.file("fee", 10 * WAD / 100);

        vm.warp(SEP_10_2026 + TAU);
        stepper.tick();
        assertEq(mkrSky.fee(), 11 * WAD / 100);
    }

    function testTickStepZero() public {
        stepper.file("step", 0);
        vm.warp(SEP_10_2026 + TAU);
        vm.expectRevert("MkrSkyFeeStepper/nothing-to-step");
        stepper.tick();
    }

    function testTickHalted() public {
        stepper.file("bad", 1);
        vm.warp(SEP_10_2026 + TAU);
        vm.expectRevert("MkrSkyFeeStepper/halted");
        stepper.tick();
        assertEq(mkrSky.fee(), FEE);

        // Resuming after two missed periods catches up
        vm.warp(SEP_10_2026 + 2 * TAU);
        stepper.file("bad", 0);
        stepper.tick();
        assertEq(mkrSky.fee(), 7 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + 2 * TAU);
    }

    function testTickHaltedResumeWithNewRho() public {
        stepper.file("bad", 1);
        vm.warp(SEP_10_2026 + 2 * TAU + 3 days);

        // Governance re-anchors the schedule when resuming: no catch-up
        stepper.file("bad", 0);
        stepper.file("rho", block.timestamp);
        vm.expectRevert("MkrSkyFeeStepper/too-soon");
        stepper.tick();

        vm.warp(block.timestamp + TAU);
        stepper.tick();
        assertEq(mkrSky.fee(), 6 * WAD / 100);
    }

    function testTickTauNotSet() public {
        stepper.file("tau", 0);
        vm.warp(SEP_10_2026 + TAU);
        vm.expectRevert("MkrSkyFeeStepper/tau-not-set");
        stepper.tick();
    }

    function testTickTauChange() public {
        vm.warp(SEP_10_2026 + TAU);
        stepper.tick();
        assertEq(mkrSky.fee(), 6 * WAD / 100);

        // Switch to monthly steps: the next step is due 30 days after the last one
        stepper.file("tau", 30 days);
        vm.warp(SEP_10_2026 + TAU + 30 days - 1);
        vm.expectRevert("MkrSkyFeeStepper/too-soon");
        stepper.tick();
        vm.warp(SEP_10_2026 + TAU + 30 days);
        stepper.tick();
        assertEq(mkrSky.fee(), 7 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + TAU + 30 days);
    }

    function testTickRhoInFuture() public {
        stepper.file("rho", SEP_10_2026 + 30 days);

        vm.warp(SEP_10_2026 + TAU);
        vm.expectRevert("MkrSkyFeeStepper/too-soon");
        stepper.tick();

        vm.warp(SEP_10_2026 + 30 days + TAU);
        stepper.tick();
        assertEq(mkrSky.fee(), 6 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + 30 days + TAU);
    }

    function testTickNotAuthorizedOnMkrSky() public {
        mkrSky.deny(address(stepper));
        vm.warp(SEP_10_2026 + TAU);
        vm.expectRevert("MkrSky/not-authorized");
        stepper.tick();
    }

    function testSchedule() public {
        // 5% on 2026-09-10, +1% per period until 100% is reached 95 periods later
        for (uint256 k = 1; k <= 95; k++) {
            vm.warp(SEP_10_2026 + k * TAU + (k % 5) * 1 days); // poked up to 4 days late
            vm.expectEmit(true, true, true, true, address(stepper));
            emit Tick(1, FEE + k * STEP);
            stepper.tick();
            assertEq(mkrSky.fee(), FEE + k * STEP);
            assertEq(stepper.rho(), SEP_10_2026 + k * TAU);
        }
        assertEq(mkrSky.fee(), WAD);
        assertLt(block.timestamp, SEP_10_2026 + 25 * 365 days);

        vm.warp(SEP_10_2026 + 96 * TAU);
        vm.expectRevert("MkrSkyFeeStepper/nothing-to-step");
        stepper.tick();

        // At 100% every converted MKR is taken as fee
        mkr.approve(address(mkrSky), 100 * WAD);
        mkrSky.mkrToSky(address(this), 100 * WAD);
        assertEq(sky.balanceOf(address(this)), 0);
        assertEq(mkrSky.take(), 100 * WAD * RATE);
    }

    function testFuzzTick(uint256 fee0, uint256 step_, uint256 cap_, uint256 tau_, uint256 elapsed) public {
        fee0    = bound(fee0,    0, WAD);
        step_   = bound(step_,   0, WAD);
        cap_    = bound(cap_,    0, WAD);
        tau_    = bound(tau_,    1, 10 * 365 days);
        elapsed = bound(elapsed, 0, 50 * 365 days);

        mkrSky.file("fee", fee0);
        stepper.file("step", step_);
        stepper.file("cap",  cap_);
        stepper.file("tau",  tau_);

        vm.warp(SEP_10_2026 + elapsed);

        uint256 n = elapsed / tau_;
        if (n == 0) {
            vm.expectRevert("MkrSkyFeeStepper/too-soon");
            stepper.tick();
            return;
        }

        uint256 expected = fee0 + n * step_;
        if (expected > cap_) expected = cap_;
        if (expected <= fee0) {
            vm.expectRevert("MkrSkyFeeStepper/nothing-to-step");
            stepper.tick();
            assertEq(mkrSky.fee(), fee0);
            assertEq(stepper.rho(), SEP_10_2026);
            return;
        }

        vm.expectEmit(true, true, true, true, address(stepper));
        emit Tick(n, expected);
        assertEq(stepper.tick(), expected);
        assertEq(mkrSky.fee(), expected);
        assertLe(mkrSky.fee(), cap_);
        assertEq(stepper.rho(), SEP_10_2026 + n * tau_);
        assertLe(stepper.rho(), block.timestamp);
        assertGt(stepper.rho() + tau_, block.timestamp);

        vm.expectRevert("MkrSkyFeeStepper/too-soon");
        stepper.tick();
    }
}

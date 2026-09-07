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
import { MkrSkyFeeStepperJob } from "src/MkrSkyFeeStepperJob.sol";
import { SequencerMock } from "test/mocks/SequencerMock.sol";

contract Mkr is Sky {}

contract MkrSkyFeeStepperJobTest is DssTest {
    Mkr                 mkr;
    Sky                 sky;
    MkrSky              mkrSky;
    MkrSkyFeeStepper    stepper;
    MkrSkyFeeStepperJob job;
    SequencerMock       sequencer;

    uint256 constant SEP_10_2026 = 1_788_998_400;
    uint256 constant FEE         = 5 * WAD / 100;
    uint256 constant STEP        = 1 * WAD / 100;
    uint256 constant TAU         = 91 days;

    bytes32 constant NET = "NTWK";

    event Work(bytes32 indexed network, uint256 fee);

    function setUp() public {
        vm.warp(SEP_10_2026);

        mkr    = new Mkr();
        sky    = new Sky();
        mkrSky = new MkrSky(address(mkr), address(sky), 24_000);
        mkrSky.file("fee", FEE);

        stepper = new MkrSkyFeeStepper(address(mkrSky));
        stepper.file("step", STEP);
        stepper.file("cap",  WAD);
        stepper.file("tau",  TAU);
        mkrSky.rely(address(stepper));

        sequencer = new SequencerMock();
        sequencer.setMaster(NET, true);
        job = new MkrSkyFeeStepperJob(address(sequencer), address(stepper));
    }

    function testConstructor() public view {
        assertEq(address(job.sequencer()), address(sequencer));
        assertEq(address(job.stepper()), address(stepper));
    }

    function _assertNotWorkable(string memory reason) internal view {
        (bool canWork, bytes memory args) = job.workable(NET);
        assertTrue(!canWork);
        assertEq(string(args), reason);
    }

    function testWorkableNotMaster() public {
        vm.warp(SEP_10_2026 + TAU);
        sequencer.setMaster(NET, false);
        _assertNotWorkable("Network is not master");
    }

    function testWorkableHalted() public {
        vm.warp(SEP_10_2026 + TAU);
        stepper.file("bad", 1);
        _assertNotWorkable("Stepper is halted");
    }

    function testWorkableTauNotSet() public {
        vm.warp(SEP_10_2026 + TAU);
        stepper.file("tau", 0);
        _assertNotWorkable("Period is not set");
    }

    function testWorkableTooSoon() public {
        _assertNotWorkable("Timer hasn't elapsed");
        vm.warp(SEP_10_2026 + TAU - 1);
        _assertNotWorkable("Timer hasn't elapsed");
    }

    function testWorkableNothingToStep() public {
        vm.warp(SEP_10_2026 + TAU);
        stepper.file("step", 0);
        _assertNotWorkable("Nothing to step");

        stepper.file("step", STEP);
        stepper.file("cap", FEE);
        _assertNotWorkable("Nothing to step");
    }

    function testWorkable() public {
        vm.warp(SEP_10_2026 + TAU);
        (bool canWork, bytes memory args) = job.workable(NET);
        assertTrue(canWork);
        assertEq(args.length, 0);
    }

    function testWorkNotMaster() public {
        vm.warp(SEP_10_2026 + TAU);
        sequencer.setMaster(NET, false);
        vm.expectRevert(abi.encodeWithSelector(MkrSkyFeeStepperJob.NotMaster.selector, NET));
        job.work(NET, "");
    }

    function testWorkTooSoon() public {
        vm.expectRevert("MkrSkyFeeStepper/too-soon");
        job.work(NET, "");
    }

    function testWork() public {
        vm.warp(SEP_10_2026 + 2 * TAU);
        vm.expectEmit(true, true, true, true, address(job));
        emit Work(NET, 7 * WAD / 100);
        job.work(NET, "");
        assertEq(mkrSky.fee(), 7 * WAD / 100);
        assertEq(stepper.rho(), SEP_10_2026 + 2 * TAU);
        _assertNotWorkable("Timer hasn't elapsed");
    }

    // work() reverts iff workable() is false
    function testFuzzWorkableMatchesWork(uint256 fee0, uint256 step_, uint256 cap_, uint256 tau_, uint256 elapsed, uint256 bad) public {
        fee0    = bound(fee0,    0, WAD);
        step_   = bound(step_,   0, WAD);
        cap_    = bound(cap_,    0, WAD);
        tau_    = bound(tau_,    0, 10 * 365 days);
        elapsed = bound(elapsed, 0, 50 * 365 days);
        bad     = bound(bad,     0, 1);

        mkrSky.file("fee", fee0);
        stepper.file("step", step_);
        stepper.file("cap",  cap_);
        stepper.file("tau",  tau_);
        stepper.file("bad",  bad);
        vm.warp(SEP_10_2026 + elapsed);

        (bool canWork,) = job.workable(NET);
        try job.work(NET, "") {
            assertTrue(canWork);
        } catch {
            assertTrue(!canWork);
        }
    }
}

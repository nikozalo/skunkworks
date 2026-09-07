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

contract Handler is Test {
    MkrSky              public mkrSky;
    MkrSkyFeeStepper    public stepper;
    MkrSkyFeeStepperJob public job;
    bytes32             public net;

    uint256 public ghost_lastFee;
    uint256 public ghost_govBumps;
    uint256 public ghost_ticks;
    uint256 public ghost_periods;
    bool    public ghost_monotonic = true;
    bool    public ghost_consistent = true; // work() reverts iff workable() is false

    constructor(MkrSky mkrSky_, MkrSkyFeeStepper stepper_, MkrSkyFeeStepperJob job_, bytes32 net_) {
        mkrSky  = mkrSky_;
        stepper = stepper_;
        job     = job_;
        net     = net_;
        ghost_lastFee = mkrSky.fee();
    }

    function warp(uint256 secs) external {
        secs = bound(secs, 0, 2 * 365 days);
        vm.warp(block.timestamp + secs);
    }

    function tick() external {
        uint256 fee_ = mkrSky.fee();
        uint256 rho_ = stepper.rho();
        (bool canWork,) = job.workable(net);

        try stepper.tick() returns (uint256 fee) {
            if (!canWork) ghost_consistent = false;
            uint256 n = (block.timestamp - rho_) / stepper.tau();
            uint256 expected = fee_ + n * stepper.step();
            if (expected > stepper.cap()) expected = stepper.cap();
            assertEq(fee, expected);
            assertEq(mkrSky.fee(), expected);
            ghost_ticks++;
            ghost_periods += n;
        } catch {
            if (canWork) ghost_consistent = false;
            assertEq(mkrSky.fee(), fee_);
            assertEq(stepper.rho(), rho_);
        }

        _record();
    }

    // Governance raising the fee directly by up to one step (never above the cap)
    function govBump(uint256 amt) external {
        uint256 fee_ = mkrSky.fee();
        uint256 cap_ = stepper.cap();
        if (fee_ >= cap_) return;
        uint256 max = cap_ - fee_;
        if (max > stepper.step()) max = stepper.step();
        amt = bound(amt, 0, max);
        mkrSky.file("fee", fee_ + amt);
        ghost_govBumps += amt;

        _record();
    }

    function _record() internal {
        uint256 fee = mkrSky.fee();
        if (fee < ghost_lastFee) ghost_monotonic = false;
        ghost_lastFee = fee;
    }
}

contract MkrSkyFeeStepperInvariantTest is DssTest {
    Mkr                 mkr;
    Sky                 sky;
    MkrSky              mkrSky;
    MkrSkyFeeStepper    stepper;
    MkrSkyFeeStepperJob job;
    SequencerMock       sequencer;
    Handler             handler;

    uint256 constant SEP_10_2026 = 1_788_998_400;
    uint256 constant FEE         = 5 * WAD / 100;
    uint256 constant STEP        = 1 * WAD / 100;
    uint256 constant TAU         = 91 days;
    bytes32 constant NET         = "NTWK";

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

        handler = new Handler(mkrSky, stepper, job, NET);
        mkrSky.rely(address(handler));

        targetContract(address(handler));
    }

    function invariant_feeNeverExceedsCap() public view {
        assertLe(mkrSky.fee(), stepper.cap());
    }

    function invariant_feeNeverDecreases() public view {
        assertTrue(handler.ghost_monotonic());
    }

    function invariant_rhoOnGrid() public view {
        uint256 rho = stepper.rho();
        assertGe(rho, SEP_10_2026);
        assertLe(rho, block.timestamp);
        assertEq((rho - SEP_10_2026) % TAU, 0);
        assertEq((rho - SEP_10_2026) / TAU, handler.ghost_periods());
    }

    function invariant_feeFollowsSchedule() public view {
        uint256 expected = FEE + handler.ghost_govBumps() + STEP * ((stepper.rho() - SEP_10_2026) / TAU);
        if (expected > stepper.cap()) expected = stepper.cap();
        assertEq(mkrSky.fee(), expected);
    }

    function invariant_feeBoundedByElapsedTime() public view {
        uint256 bound_ = FEE + handler.ghost_govBumps() + STEP * ((block.timestamp - SEP_10_2026) / TAU);
        if (bound_ > stepper.cap()) bound_ = stepper.cap();
        assertLe(mkrSky.fee(), bound_);
    }

    function invariant_workableMatchesTick() public view {
        assertTrue(handler.ghost_consistent());
    }
}

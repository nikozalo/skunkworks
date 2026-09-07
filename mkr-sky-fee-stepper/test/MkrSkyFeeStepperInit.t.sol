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
import { ChainlogAbstract } from "dss-interfaces/dss/ChainlogAbstract.sol";

import { Sky } from "sky/Sky.sol";
import { MkrSky } from "sky/MkrSky.sol";
import { MkrSkyFeeStepper } from "src/MkrSkyFeeStepper.sol";
import { MkrSkyFeeStepperMom } from "src/MkrSkyFeeStepperMom.sol";
import { MkrSkyFeeStepperJob } from "src/MkrSkyFeeStepperJob.sol";
import { MkrSkyFeeStepperDeploy } from "deploy/MkrSkyFeeStepperDeploy.sol";
import { MkrSkyFeeStepperInit, MkrSkyFeeStepperConfig } from "deploy/MkrSkyFeeStepperInit.sol";
import { MkrSkyFeeStepperInstance } from "deploy/MkrSkyFeeStepperInstance.sol";
import { ChainlogMock } from "test/mocks/ChainlogMock.sol";
import { SequencerMock } from "test/mocks/SequencerMock.sol";
import { AuthorityMock } from "test/mocks/AuthorityMock.sol";

contract Mkr is Sky {}

// Runs the deploy library from its own address so that ownership hand-over is exercised
contract Deployer {
    function deploy(address owner, address mkrSky, address sequencer) external returns (MkrSkyFeeStepperInstance memory) {
        return MkrSkyFeeStepperDeploy.deploy(address(this), owner, mkrSky, sequencer);
    }
}

// The test contract plays the role of the pause proxy
contract MkrSkyFeeStepperInitTest is DssTest {
    Mkr           mkr;
    Sky           sky;
    MkrSky        mkrSky;
    ChainlogMock  chainlog;
    SequencerMock sequencer;
    AuthorityMock chief;
    Deployer      deployer;

    DssInstance dss;
    MkrSkyFeeStepperInstance instance;
    MkrSkyFeeStepperConfig   cfg;

    uint256 constant SEP_10_2026 = 1_788_998_400;
    uint256 constant FEE         = 5 * WAD / 100;
    uint256 constant STEP        = 1 * WAD / 100;
    uint256 constant TAU         = 91 days;

    function setUp() public {
        vm.warp(SEP_10_2026 + 4 days);

        mkr    = new Mkr();
        sky    = new Sky();
        mkrSky = new MkrSky(address(mkr), address(sky), 24_000);
        mkrSky.file("fee", FEE);

        chainlog  = new ChainlogMock();
        sequencer = new SequencerMock();
        chief     = new AuthorityMock();
        chainlog.setAddress("MKR_SKY",        address(mkrSky));
        chainlog.setAddress("CRON_SEQUENCER", address(sequencer));
        chainlog.setAddress("MCD_ADM",        address(chief));
        dss.chainlog = ChainlogAbstract(address(chainlog));

        deployer = new Deployer();
        instance = deployer.deploy(address(this), address(mkrSky), address(sequencer));

        cfg = MkrSkyFeeStepperConfig({
            step: STEP,
            cap:  WAD,
            tau:  TAU,
            rho:  SEP_10_2026
        });
    }

    function init(MkrSkyFeeStepperInstance memory instance_, MkrSkyFeeStepperConfig memory cfg_) external {
        MkrSkyFeeStepperInit.init(dss, instance_, cfg_);
    }

    function testDeploy() public view {
        MkrSkyFeeStepper    stepper = MkrSkyFeeStepper(instance.stepper);
        MkrSkyFeeStepperMom mom     = MkrSkyFeeStepperMom(instance.mom);
        MkrSkyFeeStepperJob job     = MkrSkyFeeStepperJob(instance.job);

        assertEq(address(stepper.mkrSky()), address(mkrSky));
        assertEq(stepper.wards(address(this)), 1);
        assertEq(stepper.wards(address(deployer)), 0);
        assertEq(stepper.rho(), block.timestamp);
        assertEq(stepper.step(), 0);
        assertEq(stepper.cap(), 0);
        assertEq(stepper.tau(), 0);
        assertEq(stepper.bad(), 0);

        assertEq(address(mom.stepper()), instance.stepper);
        assertEq(mom.owner(), address(this));
        assertEq(mom.authority(), address(0));

        assertEq(address(job.sequencer()), address(sequencer));
        assertEq(address(job.stepper()), instance.stepper);
    }

    function testInit() public {
        MkrSkyFeeStepper    stepper = MkrSkyFeeStepper(instance.stepper);
        MkrSkyFeeStepperMom mom     = MkrSkyFeeStepperMom(instance.mom);

        MkrSkyFeeStepperInit.init(dss, instance, cfg);

        assertEq(stepper.step(), STEP);
        assertEq(stepper.cap(),  WAD);
        assertEq(stepper.tau(),  TAU);
        assertEq(stepper.rho(),  SEP_10_2026);
        assertEq(stepper.bad(),  0);
        assertEq(stepper.wards(instance.mom), 1);
        assertEq(mom.authority(), address(chief));
        assertEq(mkrSky.wards(instance.stepper), 1);
        assertTrue(sequencer.hasJob(instance.job));
        assertEq(chainlog.getAddress("MKR_SKY_FEE_STEPPER"),          instance.stepper);
        assertEq(chainlog.getAddress("MKR_SKY_FEE_STEPPER_MOM"),      instance.mom);
        assertEq(chainlog.getAddress("CRON_MKR_SKY_FEE_STEPPER_JOB"), instance.job);

        // The whole thing works end to end
        vm.warp(SEP_10_2026 + TAU - 1);
        vm.expectRevert("MkrSkyFeeStepper/too-soon");
        stepper.tick();
        vm.warp(SEP_10_2026 + TAU);
        stepper.tick();
        assertEq(mkrSky.fee(), FEE + STEP);
    }

    function testInitMkrSkyMismatch() public {
        MkrSkyFeeStepperInstance memory bad = instance;
        bad.stepper = address(new MkrSkyFeeStepper(address(0x123)));
        vm.expectRevert("MkrSkyFeeStepperInit/mkr-sky-mismatch");
        this.init(bad, cfg);
    }

    function testInitMomMismatch() public {
        MkrSkyFeeStepperInstance memory bad = instance;
        bad.mom = address(new MkrSkyFeeStepperMom(address(0x123)));
        vm.expectRevert("MkrSkyFeeStepperInit/mom-stepper-mismatch");
        this.init(bad, cfg);
    }

    function testInitJobMismatch() public {
        MkrSkyFeeStepperInstance memory bad = instance;
        bad.job = address(new MkrSkyFeeStepperJob(address(sequencer), address(0x123)));
        vm.expectRevert("MkrSkyFeeStepperInit/job-stepper-mismatch");
        this.init(bad, cfg);

        bad.job = address(new MkrSkyFeeStepperJob(address(0x123), instance.stepper));
        vm.expectRevert("MkrSkyFeeStepperInit/job-sequencer-mismatch");
        this.init(bad, cfg);
    }

    function testInitInvalidConfig() public {
        MkrSkyFeeStepperConfig memory bad = cfg;

        bad.step = 0;
        vm.expectRevert("MkrSkyFeeStepperInit/invalid-step");
        this.init(instance, bad);
        bad.step = WAD + 1;
        vm.expectRevert("MkrSkyFeeStepperInit/invalid-step");
        this.init(instance, bad);

        bad = cfg;
        bad.cap = FEE - 1;
        vm.expectRevert("MkrSkyFeeStepperInit/invalid-cap");
        this.init(instance, bad);
        bad.cap = WAD + 1;
        vm.expectRevert("MkrSkyFeeStepperInit/invalid-cap");
        this.init(instance, bad);

        bad = cfg;
        bad.tau = 0;
        vm.expectRevert("MkrSkyFeeStepperInit/invalid-tau");
        this.init(instance, bad);

        bad = cfg;
        bad.rho = 0;
        vm.expectRevert("MkrSkyFeeStepperInit/invalid-rho");
        this.init(instance, bad);
        bad.rho = block.timestamp + TAU + 1;
        vm.expectRevert("MkrSkyFeeStepperInit/invalid-rho");
        this.init(instance, bad);

        // Boundaries are accepted
        bad = cfg;
        bad.cap = FEE;
        bad.rho = block.timestamp + TAU;
        this.init(instance, bad);
    }
}

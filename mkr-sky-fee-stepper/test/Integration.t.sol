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

import { MkrSkyFeeStepper } from "src/MkrSkyFeeStepper.sol";
import { MkrSkyFeeStepperMom } from "src/MkrSkyFeeStepperMom.sol";
import { MkrSkyFeeStepperJob } from "src/MkrSkyFeeStepperJob.sol";
import { MkrSkyFeeStepperDeploy } from "deploy/MkrSkyFeeStepperDeploy.sol";
import { MkrSkyFeeStepperInit, MkrSkyFeeStepperConfig } from "deploy/MkrSkyFeeStepperInit.sol";
import { MkrSkyFeeStepperInstance } from "deploy/MkrSkyFeeStepperInstance.sol";

interface MkrSkyLike {
    function wards(address) external view returns (uint256);
    function fee() external view returns (uint256);
    function mkr() external view returns (address);
    function mkrToSky(address usr, uint256 mkrAmt) external;
}

interface SequencerLike {
    function hasJob(address) external view returns (bool);
    function getMaster() external view returns (bytes32);
}

interface ChiefLike {
    function hat() external view returns (address);
}

interface GemLike {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

// Mainnet fork test: requires ETH_RPC_URL, skipped otherwise
contract IntegrationTest is DssTest {
    address constant LOG = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;

    DssInstance   dss;
    address       pauseProxy;
    MkrSkyLike    mkrSky;
    SequencerLike sequencer;
    ChiefLike     chief;

    MkrSkyFeeStepperInstance instance;
    MkrSkyFeeStepper         stepper;
    MkrSkyFeeStepperMom      mom;
    MkrSkyFeeStepperJob      job;

    uint256 constant STEP = 1 * WAD / 100;
    uint256 constant TAU  = 91 days;

    uint256 fee0;
    uint256 rho0;
    bool    forked;

    function setUp() public {
        string memory rpc = vm.envOr("ETH_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        forked = true;
        vm.createSelectFork(rpc);

        dss        = MCD.loadFromChainlog(LOG);
        pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");
        mkrSky     = MkrSkyLike(dss.chainlog.getAddress("MKR_SKY"));
        sequencer  = SequencerLike(dss.chainlog.getAddress("CRON_SEQUENCER"));
        chief      = ChiefLike(dss.chainlog.getAddress("MCD_ADM"));

        instance = MkrSkyFeeStepperDeploy.deploy(address(this), pauseProxy, address(mkrSky), address(sequencer));
        stepper  = MkrSkyFeeStepper(instance.stepper);
        mom      = MkrSkyFeeStepperMom(instance.mom);
        job      = MkrSkyFeeStepperJob(instance.job);

        fee0 = mkrSky.fee();
        rho0 = block.timestamp;

        vm.startPrank(pauseProxy);
        MkrSkyFeeStepperInit.init(dss, instance, MkrSkyFeeStepperConfig({
            step: STEP,
            cap:  WAD,
            tau:  TAU,
            rho:  rho0
        }));
        vm.stopPrank();
    }

    modifier onlyFork() {
        vm.skip(!forked);
        _;
    }

    function testInit() public onlyFork {
        assertEq(stepper.wards(pauseProxy), 1);
        assertEq(stepper.wards(address(this)), 0);
        assertEq(stepper.wards(instance.mom), 1);
        assertEq(stepper.step(), STEP);
        assertEq(stepper.cap(), WAD);
        assertEq(stepper.tau(), TAU);
        assertEq(stepper.rho(), rho0);
        assertEq(stepper.bad(), 0);
        assertEq(mom.owner(), pauseProxy);
        assertEq(mom.authority(), address(chief));
        assertEq(mkrSky.wards(instance.stepper), 1);
        assertTrue(sequencer.hasJob(instance.job));
        assertEq(dss.chainlog.getAddress("MKR_SKY_FEE_STEPPER"), instance.stepper);
        assertEq(dss.chainlog.getAddress("MKR_SKY_FEE_STEPPER_MOM"), instance.mom);
        assertEq(dss.chainlog.getAddress("CRON_MKR_SKY_FEE_STEPPER_JOB"), instance.job);
    }

    function testTick() public onlyFork {
        vm.expectRevert("MkrSkyFeeStepper/too-soon");
        stepper.tick();

        vm.warp(rho0 + TAU);
        stepper.tick();
        assertEq(mkrSky.fee(), fee0 + STEP);
        assertEq(stepper.rho(), rho0 + TAU);

        // The new fee applies to conversions
        GemLike mkr = GemLike(mkrSky.mkr());
        GodMode.setBalance(address(mkr), address(this), WAD);
        mkr.approve(address(mkrSky), WAD);
        mkrSky.mkrToSky(address(this), WAD);
        GemLike sky = GemLike(dss.chainlog.getAddress("SKY"));
        assertEq(sky.balanceOf(address(this)), 24_000 * WAD * (WAD - fee0 - STEP) / WAD);
    }

    function testKeeperJob() public onlyFork {
        bytes32 network = sequencer.getMaster();
        (bool canWork,) = job.workable(network);
        assertTrue(!canWork);

        vm.warp(rho0 + 2 * TAU);
        (canWork,) = job.workable(network);
        assertTrue(canWork);
        job.work(network, "");
        assertEq(mkrSky.fee(), fee0 + 2 * STEP);
    }

    function testMomHalt() public onlyFork {
        vm.prank(chief.hat());
        mom.halt();
        assertEq(stepper.bad(), 1);

        vm.warp(rho0 + TAU);
        vm.expectRevert("MkrSkyFeeStepper/halted");
        stepper.tick();
        (bool canWork, bytes memory args) = job.workable(sequencer.getMaster());
        assertTrue(!canWork);
        assertEq(string(args), "Stepper is halted");
    }
}

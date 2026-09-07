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

pragma solidity >=0.8.0;

import { DssInstance } from "dss-test/MCD.sol";
import { MkrSkyFeeStepperInstance } from "./MkrSkyFeeStepperInstance.sol";

interface StepperLike {
    function mkrSky() external view returns (address);
    function rely(address) external;
    function file(bytes32, uint256) external;
}

interface MomLike {
    function stepper() external view returns (address);
    function setAuthority(address) external;
}

interface JobLike {
    function sequencer() external view returns (address);
    function stepper() external view returns (address);
}

interface MkrSkyLike {
    function fee() external view returns (uint256);
    function rely(address) external;
}

interface SequencerLike {
    function addJob(address) external;
}

struct MkrSkyFeeStepperConfig {
    uint256 step; // [wad]       Fee increase per period (1% = 0.01 * WAD)
    uint256 cap;  // [wad]       Max fee the stepper may file (100% = WAD)
    uint256 tau;  // [seconds]   Period length
    uint256 rho;  // [timestamp] Schedule anchor: the first step happens at rho + tau
}

// Initialize a MkrSkyFeeStepper instance (expected to be called from the pause proxy)
library MkrSkyFeeStepperInit {
    uint256 constant WAD = 10 ** 18;

    function init(
        DssInstance memory dss,
        MkrSkyFeeStepperInstance memory instance,
        MkrSkyFeeStepperConfig memory cfg
    ) internal {
        address mkrSky    = dss.chainlog.getAddress("MKR_SKY");
        address sequencer = dss.chainlog.getAddress("CRON_SEQUENCER");

        require(StepperLike(instance.stepper).mkrSky() == mkrSky,   "MkrSkyFeeStepperInit/mkr-sky-mismatch");
        require(MomLike(instance.mom).stepper() == instance.stepper, "MkrSkyFeeStepperInit/mom-stepper-mismatch");
        require(JobLike(instance.job).stepper() == instance.stepper, "MkrSkyFeeStepperInit/job-stepper-mismatch");
        require(JobLike(instance.job).sequencer() == sequencer,      "MkrSkyFeeStepperInit/job-sequencer-mismatch");

        require(cfg.step > 0 && cfg.step <= WAD,              "MkrSkyFeeStepperInit/invalid-step");
        require(cfg.cap >= MkrSkyLike(mkrSky).fee() && cfg.cap <= WAD, "MkrSkyFeeStepperInit/invalid-cap");
        require(cfg.tau > 0,                                  "MkrSkyFeeStepperInit/invalid-tau");
        require(cfg.rho > 0 && cfg.rho <= block.timestamp + cfg.tau, "MkrSkyFeeStepperInit/invalid-rho");

        StepperLike(instance.stepper).file("step", cfg.step);
        StepperLike(instance.stepper).file("cap",  cfg.cap);
        StepperLike(instance.stepper).file("tau",  cfg.tau);
        StepperLike(instance.stepper).file("rho",  cfg.rho);

        StepperLike(instance.stepper).rely(instance.mom);
        MomLike(instance.mom).setAuthority(dss.chainlog.getAddress("MCD_ADM"));

        MkrSkyLike(mkrSky).rely(instance.stepper);
        SequencerLike(sequencer).addJob(instance.job);

        dss.chainlog.setAddress("MKR_SKY_FEE_STEPPER",      instance.stepper);
        dss.chainlog.setAddress("MKR_SKY_FEE_STEPPER_MOM",  instance.mom);
        dss.chainlog.setAddress("CRON_MKR_SKY_FEE_STEPPER_JOB", instance.job);
    }
}

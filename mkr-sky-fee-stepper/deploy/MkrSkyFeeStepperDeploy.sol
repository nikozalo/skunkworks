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

import { ScriptTools } from "dss-test/ScriptTools.sol";
import { MkrSkyFeeStepperInstance } from "./MkrSkyFeeStepperInstance.sol";
import { MkrSkyFeeStepper } from "src/MkrSkyFeeStepper.sol";
import { MkrSkyFeeStepperMom } from "src/MkrSkyFeeStepperMom.sol";
import { MkrSkyFeeStepperJob } from "src/MkrSkyFeeStepperJob.sol";

// Deploy a MkrSkyFeeStepper instance (stepper, mom and keeper job)
library MkrSkyFeeStepperDeploy {
    function deploy(
        address deployer,
        address owner,
        address mkrSky,
        address sequencer
    ) internal returns (MkrSkyFeeStepperInstance memory instance) {
        instance.stepper = address(new MkrSkyFeeStepper(mkrSky));
        ScriptTools.switchOwner(instance.stepper, deployer, owner);

        instance.mom = address(new MkrSkyFeeStepperMom(instance.stepper));
        MkrSkyFeeStepperMom(instance.mom).setOwner(owner);

        instance.job = address(new MkrSkyFeeStepperJob(sequencer, instance.stepper));
    }
}

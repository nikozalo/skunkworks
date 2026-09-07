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

import "forge-std/Script.sol";

import { ScriptTools } from "dss-test/ScriptTools.sol";
import { MCD, DssInstance } from "dss-test/MCD.sol";
import { MkrSkyFeeStepperDeploy } from "deploy/MkrSkyFeeStepperDeploy.sol";
import { MkrSkyFeeStepperInstance } from "deploy/MkrSkyFeeStepperInstance.sol";

contract DeployScript is Script {
    string constant NAME = "mkr-sky-fee-stepper";

    address constant LOG = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;

    function run() external {
        DssInstance memory dss = MCD.loadFromChainlog(LOG);
        address pauseProxy = dss.chainlog.getAddress("MCD_PAUSE_PROXY");
        address mkrSky     = dss.chainlog.getAddress("MKR_SKY");
        address sequencer  = dss.chainlog.getAddress("CRON_SEQUENCER");

        vm.startBroadcast();
        MkrSkyFeeStepperInstance memory instance = MkrSkyFeeStepperDeploy.deploy(
            msg.sender,
            pauseProxy,
            mkrSky,
            sequencer
        );
        vm.stopBroadcast();

        ScriptTools.exportContract(NAME, "stepper", instance.stepper);
        ScriptTools.exportContract(NAME, "mom",     instance.mom);
        ScriptTools.exportContract(NAME, "job",     instance.job);
    }
}

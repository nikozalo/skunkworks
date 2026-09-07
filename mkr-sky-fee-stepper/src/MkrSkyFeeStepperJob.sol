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

interface SequencerLike {
    function isMaster(bytes32 network) external view returns (bool);
}

interface StepperLike {
    function mkrSky() external view returns (address);
    function step() external view returns (uint256);
    function cap() external view returns (uint256);
    function tau() external view returns (uint256);
    function rho() external view returns (uint256);
    function bad() external view returns (uint256);
    function tick() external returns (uint256);
}

interface MkrSkyLike {
    function fee() external view returns (uint256);
}

/// MkrSkyFeeStepperJob.sol -- dss-cron job that ticks the MkrSkyFeeStepper
//
// Implements the Maker Keeper Network `IJob` interface (see makerdao/dss-cron) so the
// existing keeper networks step the fee as soon as a period elapses, without a spell.

contract MkrSkyFeeStepperJob {
    SequencerLike public immutable sequencer;
    StepperLike   public immutable stepper;

    // --- Errors ---
    error NotMaster(bytes32 network);

    // --- Events ---
    event Work(bytes32 indexed network, uint256 fee);

    constructor(address _sequencer, address _stepper) {
        sequencer = SequencerLike(_sequencer);
        stepper   = StepperLike(_stepper);
    }

    function work(bytes32 network, bytes calldata) external {
        if (!sequencer.isMaster(network)) revert NotMaster(network);

        uint256 fee = stepper.tick();

        emit Work(network, fee);
    }

    // Mirrors the checks in MkrSkyFeeStepper.tick() so that it never reverts
    function workable(bytes32 network) external view returns (bool, bytes memory) {
        if (!sequencer.isMaster(network)) return (false, bytes("Network is not master"));
        if (stepper.bad() != 0) return (false, bytes("Stepper is halted"));
        uint256 tau = stepper.tau();
        if (tau == 0) return (false, bytes("Period is not set"));
        uint256 rho = stepper.rho();
        if (block.timestamp < rho || block.timestamp - rho < tau) return (false, bytes("Timer hasn't elapsed"));
        uint256 fee_ = MkrSkyLike(stepper.mkrSky()).fee();
        uint256 fee  = fee_ + (block.timestamp - rho) / tau * stepper.step();
        uint256 cap  = stepper.cap();
        if (fee > cap) fee = cap;
        if (fee <= fee_) return (false, bytes("Nothing to step"));

        return (true, "");
    }
}

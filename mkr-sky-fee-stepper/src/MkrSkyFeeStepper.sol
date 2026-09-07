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

interface MkrSkyLike {
    function fee() external view returns (uint256);
    function file(bytes32, uint256) external;
}

/// MkrSkyFeeStepper.sol -- Steps up the MkrSky delayed upgrade penalty on a fixed schedule
//
// Every `tau` seconds the MKR->SKY conversion fee (`MkrSky.fee`) is increased by `step`,
// up to `cap`. `tick()` is permissionless: it files `fee + n * step` on MkrSky, where `n` is
// the number of whole periods elapsed since the last step (`rho`), so missed periods are
// caught up in a single call and the schedule never drifts, no matter when it is poked.
// This contract must be a ward on MkrSky.

contract MkrSkyFeeStepper {
    // --- Data ---
    mapping (address => uint256) public wards;

    uint256 public step; // [wad]       Fee increase applied per period
    uint256 public cap;  // [wad]       Max fee this contract will ever file
    uint256 public tau;  // [seconds]   Period length
    uint256 public rho;  // [timestamp] Time of the last step (start of the current period)
    uint256 public bad;  // [flag]      Circuit breaker (1 = halted)

    MkrSkyLike public immutable mkrSky;

    uint256 constant WAD = 10 ** 18;

    // --- Events ---
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event File(bytes32 indexed what, uint256 data);
    event Tick(uint256 n, uint256 fee);

    modifier auth {
        require(wards[msg.sender] == 1, "MkrSkyFeeStepper/not-authorized");
        _;
    }

    constructor(address mkrSky_) {
        mkrSky = MkrSkyLike(mkrSky_);
        rho    = block.timestamp; // Never catch up from the epoch if `rho` is not filed

        wards[msg.sender] = 1;
        emit Rely(msg.sender);
    }

    // --- Administration ---
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }

    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }

    function file(bytes32 what, uint256 data) external auth {
        if (what == "step") {
            require(data <= WAD, "MkrSkyFeeStepper/step-exceeds-wad");
            step = data;
        } else if (what == "cap") {
            require(data <= WAD, "MkrSkyFeeStepper/cap-exceeds-wad");
            cap = data;
        } else if (what == "tau") {
            tau = data;
        } else if (what == "rho") {
            rho = data;
        } else if (what == "bad") {
            require(data <= 1, "MkrSkyFeeStepper/invalid-bad-value");
            bad = data;
        } else revert("MkrSkyFeeStepper/file-unrecognized-param");
        emit File(what, data);
    }

    // --- Stepping ---
    function tick() external returns (uint256 fee) {
        require(bad == 0, "MkrSkyFeeStepper/halted");
        uint256 tau_ = tau;
        require(tau_ > 0, "MkrSkyFeeStepper/tau-not-set");
        uint256 rho_ = rho;
        require(block.timestamp >= rho_ + tau_, "MkrSkyFeeStepper/too-soon");

        uint256 n    = (block.timestamp - rho_) / tau_; // Whole periods elapsed since the last step
        uint256 fee_ = mkrSky.fee();
        uint256 cap_ = cap;
        fee = fee_ + n * step;
        if (fee > cap_) fee = cap_;
        require(fee > fee_, "MkrSkyFeeStepper/nothing-to-step");

        rho = rho_ + n * tau_; // Stay on the schedule grid regardless of when tick is called
        mkrSky.file("fee", fee);
        emit Tick(n, fee);
    }
}

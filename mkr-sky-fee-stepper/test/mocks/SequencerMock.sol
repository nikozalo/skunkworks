// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

// Minimal stand-in for makerdao/dss-cron Sequencer
contract SequencerMock {
    mapping (bytes32 => bool) public isMaster;
    mapping (address => bool) public hasJob;
    uint256 public numJobs;

    function setMaster(bytes32 network, bool master) external {
        isMaster[network] = master;
    }

    function addJob(address job) external {
        require(!hasJob[job], "SequencerMock/job-exists");
        hasJob[job] = true;
        numJobs++;
    }
}

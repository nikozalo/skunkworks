// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

// Minimal stand-in for the MCD chainlog
contract ChainlogMock {
    mapping (bytes32 => address) addrs;

    function setAddress(bytes32 key, address addr) external {
        addrs[key] = addr;
    }

    function getAddress(bytes32 key) external view returns (address addr) {
        addr = addrs[key];
        require(addr != address(0), "dss-chain-log/invalid-key");
    }
}

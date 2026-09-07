// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.21;

// Minimal stand-in for the chief (DSAuthority)
contract AuthorityMock {
    mapping (address => bool) public allowed;

    function allow(address src, bool ok) external {
        allowed[src] = ok;
    }

    function canCall(address src, address, bytes4) external view returns (bool) {
        return allowed[src];
    }
}

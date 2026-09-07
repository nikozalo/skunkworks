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

import { Sky } from "sky/Sky.sol";
import { MkrSky } from "sky/MkrSky.sol";
import { MkrSkyFeeStepper } from "src/MkrSkyFeeStepper.sol";
import { MkrSkyFeeStepperMom } from "src/MkrSkyFeeStepperMom.sol";
import { AuthorityMock } from "test/mocks/AuthorityMock.sol";

contract Mkr is Sky {}

contract MkrSkyFeeStepperMomTest is DssTest {
    Mkr                 mkr;
    Sky                 sky;
    MkrSky              mkrSky;
    MkrSkyFeeStepper    stepper;
    MkrSkyFeeStepperMom mom;
    AuthorityMock       authority;

    uint256 constant SEP_10_2026 = 1_788_998_400;
    uint256 constant TAU         = 91 days;

    address constant HAT   = address(0x4a7);
    address constant OTHER = address(0xBEEF);

    event SetOwner(address indexed _owner);
    event SetAuthority(address indexed _authority);
    event Halt();

    function setUp() public {
        vm.warp(SEP_10_2026);

        mkr    = new Mkr();
        sky    = new Sky();
        mkrSky = new MkrSky(address(mkr), address(sky), 24_000);
        mkrSky.file("fee", 5 * WAD / 100);

        stepper = new MkrSkyFeeStepper(address(mkrSky));
        stepper.file("step", 1 * WAD / 100);
        stepper.file("cap",  WAD);
        stepper.file("tau",  TAU);
        mkrSky.rely(address(stepper));

        mom = new MkrSkyFeeStepperMom(address(stepper));
        stepper.rely(address(mom));

        authority = new AuthorityMock();
        authority.allow(HAT, true);
    }

    function testConstructor() public {
        vm.expectEmit(true, true, true, true);
        emit SetOwner(address(this));
        MkrSkyFeeStepperMom m = new MkrSkyFeeStepperMom(address(stepper));
        assertEq(address(m.stepper()), address(stepper));
        assertEq(m.owner(), address(this));
        assertEq(m.authority(), address(0));
    }

    function testSetOwner() public {
        vm.expectEmit(true, true, true, true);
        emit SetOwner(OTHER);
        mom.setOwner(OTHER);
        assertEq(mom.owner(), OTHER);

        vm.expectRevert("MkrSkyFeeStepperMom/only-owner");
        mom.setOwner(address(this));

        vm.prank(OTHER);
        mom.setOwner(address(this));
        assertEq(mom.owner(), address(this));
    }

    function testSetAuthority() public {
        vm.expectEmit(true, true, true, true);
        emit SetAuthority(address(authority));
        mom.setAuthority(address(authority));
        assertEq(mom.authority(), address(authority));

        vm.prank(OTHER);
        vm.expectRevert("MkrSkyFeeStepperMom/only-owner");
        mom.setAuthority(address(0));
    }

    function testHaltByOwner() public {
        assertEq(stepper.bad(), 0);
        vm.expectEmit(true, true, true, true, address(stepper));
        emit File("bad", 1);
        vm.expectEmit(true, true, true, true, address(mom));
        emit Halt();
        mom.halt();
        assertEq(stepper.bad(), 1);

        vm.warp(SEP_10_2026 + TAU);
        vm.expectRevert("MkrSkyFeeStepper/halted");
        stepper.tick();

        // Halting is idempotent
        mom.halt();
        assertEq(stepper.bad(), 1);
    }

    function testHaltByAuthority() public {
        mom.setAuthority(address(authority));
        mom.setOwner(address(0));

        vm.prank(OTHER);
        vm.expectRevert("MkrSkyFeeStepperMom/not-authorized");
        mom.halt();

        vm.prank(HAT);
        mom.halt();
        assertEq(stepper.bad(), 1);

        // Governance (with delay) can resume
        stepper.file("bad", 0);
        vm.warp(SEP_10_2026 + TAU);
        stepper.tick();
        assertEq(mkrSky.fee(), 6 * WAD / 100);
    }

    function testHaltNoAuthority() public {
        mom.setOwner(address(0));
        vm.prank(OTHER);
        vm.expectRevert("MkrSkyFeeStepperMom/not-authorized");
        mom.halt();
    }

    function testHaltNotRelied() public {
        stepper.deny(address(mom));
        vm.expectRevert("MkrSkyFeeStepper/not-authorized");
        mom.halt();
    }
}

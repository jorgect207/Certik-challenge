// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MockERC20} from "src/mocks/MockERC20.sol";
import {BaseTest} from "test/helpers/BaseTest.sol";

contract MockERC20Test is BaseTest {
    function testConstructorSetsMetadata() public {
        MockERC20 token = new MockERC20("Mock USD", "mUSD", 6);

        assertEq(token.name(), "Mock USD");
        assertEq(token.symbol(), "mUSD");
        assertEq(token.decimals(), 6);
    }

    function testMintWorksOnlyForOwner() public {
        MockERC20 token = deployMockToken("MOCK", 18);

        vm.prank(owner);
        token.mint(alice, 1e18);
        assertEq(token.balanceOf(alice), 1e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.mint(alice, 1);
    }

    function testBurnWorksOnlyForOwner() public {
        MockERC20 token = deployMockToken("MOCK", 18);

        vm.prank(owner);
        token.mint(alice, 2e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.burn(alice, 1e18);

        vm.prank(owner);
        token.burn(alice, 5e17);
        assertEq(token.balanceOf(alice), 15e17);
    }

    function testDecimalsOverrideReturnsConstructorValue() public {
        MockERC20 token = deployMockToken("WBTC", 8);

        assertEq(token.decimals(), 8);
    }
}

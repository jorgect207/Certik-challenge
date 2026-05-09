// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20} from "src/mocks/MockERC20.sol";

abstract contract BaseTest is Test {
    uint256 internal constant SECONDS_PER_BLOCK = 12;

    address internal owner;
    address internal alice;
    address internal bob;
    address internal charlie;
    address internal feeRecipient;

    function setUp() public virtual {
        owner = makeAddr("owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        charlie = makeAddr("charlie");
        feeRecipient = makeAddr("feeRecipient");
    }

    function deployMockToken(string memory symbol, uint8 decimals_) internal returns (MockERC20 token) {
        vm.prank(owner);
        token = new MockERC20(symbol, symbol, decimals_);
    }

    function mintAndApprove(MockERC20 token, address user, address spender, uint256 amount) internal {
        vm.prank(owner);
        token.mint(user, amount);

        vm.prank(user);
        token.approve(spender, amount);
    }

    function warp(uint256 seconds_) internal {
        advanceSeconds(seconds_);
    }

    function advanceBlocks(uint256 n) internal {
        if (n == 0) return;

        vm.roll(block.number + n);
        vm.warp(block.timestamp + (n * SECONDS_PER_BLOCK));
    }

    function advanceSeconds(uint256 s) internal {
        if (s == 0) return;

        vm.warp(block.timestamp + s);
        vm.roll(block.number + ((s + SECONDS_PER_BLOCK - 1) / SECONDS_PER_BLOCK));
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20, Ownable {
    uint8 private immutable _DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) Ownable(msg.sender) {
        _DECIMALS = decimals_;
    }

    /// @notice Returns the token decimals configured at deployment.
    /// @return decimals_ The token decimals.
    function decimals() public view override returns (uint8 decimals_) {
        return _DECIMALS;
    }

    /// @notice Mints tokens to an account.
    /// @param to The recipient.
    /// @param amount The amount to mint.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Burns tokens from an account.
    /// @param from The token holder.
    /// @param amount The amount to burn.
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}

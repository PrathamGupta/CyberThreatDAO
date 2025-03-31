// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Import the standard OpenZeppelin ERC20 implementation
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract CyberToken is ERC20 {
    constructor(uint256 initialSupply) ERC20("CyberToken", "CTK") {
        _mint(msg.sender, initialSupply);
    }
}


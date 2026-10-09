// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// Stands in for the IMD token.
contract MockImd is ERC20 {
    constructor() ERC20("Mock IMD", "IMD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// Burns 1% of every transfer: the escrow must refuse it.
contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Taxed", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 tax = value / 100;
            super._update(from, address(0), tax);
            value -= tax;
        }
        super._update(from, to, value);
    }
}

/// A receiver that refuses ETH: it must only ever block itself.
contract RejectsEth {
    receive() external payable {
        revert("no");
    }
}

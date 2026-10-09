// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";

/// @notice Signs with DEPLOYER_PRIVATE_KEY from .env when it is set,
/// otherwise with whatever forge was given (--account for a keystore).
abstract contract Deployer is Script {
    /// @return deployer the address that will actually send the transactions.
    function _start() internal returns (address deployer) {
        // Hex, with or without the 0x a wallet export may leave off.
        string memory raw = vm.envOr("DEPLOYER_PRIVATE_KEY", string(""));
        if (bytes(raw).length != 0) {
            bytes memory b = bytes(raw);
            bool prefixed = b.length > 1 && b[0] == "0" && (b[1] == "x" || b[1] == "X");
            vm.startBroadcast(vm.parseUint(prefixed ? raw : string.concat("0x", raw)));
        } else {
            vm.startBroadcast();
        }
        (, deployer,) = vm.readCallers();
    }
}

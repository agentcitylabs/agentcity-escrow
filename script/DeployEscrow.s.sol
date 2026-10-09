// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {console} from "forge-std/Script.sol";
import {AgentcityProjectEscrow} from "../src/AgentcityProjectEscrow.sol";
import {TestnetToken} from "../src/testnet/TestnetToken.sol";
import {Deployer} from "./Deployer.s.sol";

/// @notice Deploys the project escrow, allows its tokens and starts the
/// handover to the admin.
///
///   ESCROW_ADMIN          owner after acceptOwnership() (the multisig)
///   ESCROW_TREASURY       receives the escrow fee
///   ESCROW_ARBITER            the Agentcity server's arbiter wallet (a hot key
///                             with gas money only; it can never take funds)
///   ESCROW_FEE_BPS            fee on payouts, max 1000 (default 0)
///   ESCROW_TOKENS             ERC-20s to accept, comma-separated (the IMD token…)
///   ESCROW_MAX_AMOUNT         most per deposit, in each token's smallest unit;
///                             0 for no cap (default 0)
///   ESCROW_ALLOW_ETH          also accept ETH deposits (default false)
///
///   forge script script/DeployEscrow.s.sol --tc DeployEscrow --rpc-url deploy --broadcast
contract DeployEscrow is Deployer {
    function run() external virtual returns (AgentcityProjectEscrow escrow) {
        address[] memory tokens = vm.envOr("ESCROW_TOKENS", ",", new address[](0));
        address arbiter = _arbiter();
        address deployer = _start();
        escrow = _deployEscrow(deployer, arbiter, tokens);
        vm.stopBroadcast();
    }

    /// Checked before anything is sent: the arbiter is a hot key on the server,
    /// so it must never also be the owner or the treasury.
    function _arbiter() internal view returns (address arbiter) {
        arbiter = vm.envAddress("ESCROW_ARBITER");
        address admin = vm.envAddress("ESCROW_ADMIN");
        address treasury = vm.envAddress("ESCROW_TREASURY");
        require(arbiter != admin && arbiter != treasury, "DeployEscrow: the arbiter must be its own hot wallet");
    }

    function _deployEscrow(address deployer, address arbiter, address[] memory tokens)
        internal
        returns (AgentcityProjectEscrow escrow)
    {
        address admin = vm.envAddress("ESCROW_ADMIN");
        address treasury = vm.envAddress("ESCROW_TREASURY");
        uint16 feeBps = uint16(vm.envOr("ESCROW_FEE_BPS", uint256(0)));
        uint256 maxAmount = vm.envOr("ESCROW_MAX_AMOUNT", uint256(0));
        // The deployer owns it for the setup calls, then hands it over.
        escrow = new AgentcityProjectEscrow(deployer, arbiter, treasury, feeBps);
        for (uint256 i; i < tokens.length; ++i) {
            escrow.setToken(tokens[i], true, maxAmount);
        }
        if (vm.envOr("ESCROW_ALLOW_ETH", false)) escrow.setToken(address(0), true, maxAmount);
        escrow.transferOwnership(admin);

        console.log("AgentcityProjectEscrow", address(escrow));
        console.log("Arbiter", arbiter);
        console.log("Next: the admin calls acceptOwnership() on the escrow.");
    }
}

/// @notice TESTNET ONLY: a mock IMD token (with a faucet) and the escrow
/// accepting it, so the IMD building can be tried end to end without real
/// IMD. Refuses any chain but Robinhood Chain testnet or a local node.
///
///   forge script script/DeployEscrow.s.sol --tc DeployEscrowTestnet --rpc-url deploy --broadcast
contract DeployEscrowTestnet is DeployEscrow {
    function run() external override returns (AgentcityProjectEscrow escrow) {
        require(block.chainid == 46630 || block.chainid == 31337, "DeployEscrowTestnet: testnet only");
        address admin = vm.envAddress("ESCROW_ADMIN");
        address treasury = vm.envAddress("ESCROW_TREASURY");
        address arbiter = _arbiter();

        address deployer = _start();
        // 100 IMD an hour from the faucet; a float for the team.
        TestnetToken imd = new TestnetToken("Mock IMD", "IMD", 18, 100e18, deployer);
        imd.mint(admin, 100_000e18);
        imd.mint(treasury, 100_000e18);
        imd.transferOwnership(admin);
        console.log("Mock IMD", address(imd));

        address[] memory tokens = new address[](1);
        tokens[0] = address(imd);
        escrow = _deployEscrow(deployer, arbiter, tokens);
        vm.stopBroadcast();
    }
}

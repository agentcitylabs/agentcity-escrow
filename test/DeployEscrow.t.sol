// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentcityProjectEscrow} from "../src/AgentcityProjectEscrow.sol";
import {DeployEscrowTestnet} from "../script/DeployEscrow.s.sol";

contract DeployEscrowTest is Test {
    uint256 constant KEY = 0xA11CE;
    address admin = makeAddr("admin");
    address treasury = makeAddr("treasury");
    address arbiter = makeAddr("arbiter");

    function setUp() public {
        vm.chainId(31337);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(bytes32(KEY)));
        vm.setEnv("ESCROW_ADMIN", vm.toString(admin));
        vm.setEnv("ESCROW_TREASURY", vm.toString(treasury));
        vm.setEnv("ESCROW_ARBITER", vm.toString(arbiter));
        vm.setEnv("ESCROW_MAX_AMOUNT", "1000000000000000000000");
    }

    // One test: vm.setEnv is process-wide, so parallel tests would race on it.
    function test_testnetDeployWiresTheEscrow() public {
        // The arbiter must be its own hot wallet, never the admin.
        vm.setEnv("ESCROW_ARBITER", vm.toString(admin));
        DeployEscrowTestnet refused = new DeployEscrowTestnet();
        vm.expectRevert("DeployEscrow: the arbiter must be its own hot wallet");
        refused.run();

        vm.setEnv("ESCROW_ARBITER", vm.toString(arbiter));
        AgentcityProjectEscrow escrow = new DeployEscrowTestnet().run();
        assertEq(escrow.arbiter(), arbiter);
        assertEq(escrow.treasury(), treasury);
        assertEq(escrow.feeBps(), 0);
        assertEq(escrow.pendingOwner(), admin);
        (bool ethAllowed,) = escrow.tokenRules(address(0));
        assertFalse(ethAllowed, "ETH stays off unless asked for");
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AgentcityProjectEscrow as Escrow} from "../src/AgentcityProjectEscrow.sol";
import {FeeOnTransferToken, MockImd, RejectsEth} from "./Mocks.sol";

/// Withdraws again from inside the ETH it receives.
contract Reenterer {
    Escrow public escrow;
    bytes32 public id;
    uint256 public calls;

    constructor(Escrow escrow_) {
        escrow = escrow_;
    }

    function deposit(bytes32 ref, address payee, uint64 acceptBy, uint64 deliverBy) external payable {
        id = escrow.deposit{value: msg.value}(ref, payee, address(0), msg.value, acceptBy, deliverBy);
    }

    function cancel() external {
        escrow.cancel(id);
    }

    function withdraw() external {
        escrow.withdraw(address(0));
    }

    receive() external payable {
        if (calls++ == 0) escrow.withdraw(address(0));
    }
}

contract AgentcityProjectEscrowTest is Test {
    Escrow escrow;
    MockImd imd;
    address admin = makeAddr("admin");
    address arbiter = makeAddr("arbiter");
    address treasury = makeAddr("treasury");
    address client = makeAddr("client");
    address payee = makeAddr("payee");
    address stranger = makeAddr("stranger");
    bytes32 constant REF = keccak256("agentcity:project:p1");
    uint256 constant AMOUNT = 100 ether;
    uint64 acceptBy;
    uint64 deliverBy;

    function setUp() public {
        escrow = new Escrow(admin, arbiter, treasury, 250);
        imd = new MockImd();
        vm.startPrank(admin);
        escrow.setToken(address(imd), true, 1_000 ether);
        escrow.setToken(address(0), true, 0);
        vm.stopPrank();
        imd.mint(client, 10_000 ether);
        vm.deal(client, 100 ether);
        vm.prank(client);
        imd.approve(address(escrow), type(uint256).max);
        acceptBy = uint64(block.timestamp + 1 days);
        deliverBy = uint64(block.timestamp + 8 days);
    }

    function _deposit() internal returns (bytes32 id) {
        vm.prank(client);
        id = escrow.deposit(REF, payee, address(imd), AMOUNT, acceptBy, deliverBy);
    }

    function _status(bytes32 id) internal view returns (Escrow.Status) {
        return escrow.deals(id).status;
    }

    // ------------------------------------------------------------- deposit

    function test_depositHoldsTheOfferWithItsTerms() public {
        bytes32 id = _deposit();
        assertEq(id, escrow.dealId(client, REF));
        Escrow.Deal memory d = escrow.deals(id);
        assertEq(d.client, client);
        assertEq(d.payee, payee);
        assertEq(d.token, address(imd));
        assertEq(d.amount, AMOUNT);
        assertEq(d.feeBps, 250);
        assertEq(uint8(d.status), uint8(Escrow.Status.Funded));
        assertEq(imd.balanceOf(address(escrow)), AMOUNT);
        assertEq(escrow.held(address(imd)), AMOUNT);
    }

    function test_depositEmitsWhatTheServerChecks() public {
        vm.expectEmit(address(escrow));
        emit Escrow.Deposited(escrow.dealId(client, REF), REF, client, payee, address(imd), AMOUNT, acceptBy, deliverBy);
        _deposit();
    }

    function test_depositRefusesBadTerms() public {
        vm.startPrank(client);
        vm.expectRevert(Escrow.BadAddress.selector);
        escrow.deposit(REF, address(0), address(imd), AMOUNT, acceptBy, deliverBy);
        vm.expectRevert(Escrow.BadAddress.selector);
        escrow.deposit(REF, client, address(imd), AMOUNT, acceptBy, deliverBy);
        vm.expectRevert(Escrow.TokenNotAllowed.selector);
        escrow.deposit(REF, payee, makeAddr("other"), AMOUNT, acceptBy, deliverBy);
        vm.expectRevert(Escrow.BadAmount.selector);
        escrow.deposit(REF, payee, address(imd), 0, acceptBy, deliverBy);
        vm.expectRevert(Escrow.BadAmount.selector);
        escrow.deposit(REF, payee, address(imd), 1_001 ether, acceptBy, deliverBy);
        vm.expectRevert(Escrow.BadDeadline.selector);
        escrow.deposit(REF, payee, address(imd), AMOUNT, uint64(block.timestamp), deliverBy);
        vm.expectRevert(Escrow.BadDeadline.selector);
        escrow.deposit(REF, payee, address(imd), AMOUNT, uint64(block.timestamp + 31 days), deliverBy + 31 days);
        vm.expectRevert(Escrow.BadDeadline.selector);
        escrow.deposit(REF, payee, address(imd), AMOUNT, acceptBy, acceptBy + 1 hours);
        vm.expectRevert(Escrow.BadDeadline.selector);
        escrow.deposit(REF, payee, address(imd), AMOUNT, acceptBy, acceptBy + 91 days);
        // A token deposit carries no ETH.
        vm.expectRevert(Escrow.BadAmount.selector);
        escrow.deposit{value: 1}(REF, payee, address(imd), AMOUNT, acceptBy, deliverBy);
        vm.stopPrank();
    }

    function test_oneDealPerClientAndRef_butNobodyCanTakeAnothersRef() public {
        _deposit();
        vm.prank(client);
        vm.expectRevert(Escrow.DealExists.selector);
        escrow.deposit(REF, payee, address(imd), AMOUNT, acceptBy, deliverBy);
        // A stranger depositing under the same ref gets a different deal.
        imd.mint(stranger, AMOUNT);
        vm.startPrank(stranger);
        imd.approve(address(escrow), AMOUNT);
        bytes32 theirs = escrow.deposit(REF, payee, address(imd), AMOUNT, acceptBy, deliverBy);
        vm.stopPrank();
        assertTrue(theirs != escrow.dealId(client, REF));
    }

    function test_ethDepositNeedsTheExactValue() public {
        vm.startPrank(client);
        vm.expectRevert(Escrow.BadAmount.selector);
        escrow.deposit{value: 1 ether}(REF, payee, address(0), 2 ether, acceptBy, deliverBy);
        bytes32 id = escrow.deposit{value: 2 ether}(REF, payee, address(0), 2 ether, acceptBy, deliverBy);
        vm.stopPrank();
        assertEq(escrow.deals(id).amount, 2 ether);
        assertEq(address(escrow).balance, 2 ether);
    }

    function test_feeOnTransferTokensAreRefused() public {
        FeeOnTransferToken tax = new FeeOnTransferToken();
        vm.prank(admin);
        escrow.setToken(address(tax), true, 0);
        tax.mint(client, AMOUNT);
        vm.startPrank(client);
        tax.approve(address(escrow), AMOUNT);
        vm.expectRevert(Escrow.FeeOnTransferToken.selector);
        escrow.deposit(REF, payee, address(tax), AMOUNT, acceptBy, deliverBy);
        vm.stopPrank();
    }

    function test_pauseStopsDepositsOnly() public {
        bytes32 id = _deposit();
        vm.prank(admin);
        escrow.pause();
        vm.prank(client);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.deposit(keccak256("p2"), payee, address(imd), AMOUNT, acceptBy, deliverBy);
        // The client still gets out, and still withdraws.
        vm.startPrank(client);
        escrow.cancel(id);
        escrow.withdraw(address(imd));
        vm.stopPrank();
        assertEq(imd.balanceOf(client), 10_000 ether);
    }

    // ------------------------------------------------------- happy path

    function test_acceptThenReleasePaysThePayeeLessTheFee() public {
        bytes32 id = _deposit();
        vm.prank(arbiter);
        escrow.accept(id);
        vm.prank(arbiter);
        escrow.release(id);
        assertEq(uint8(_status(id)), uint8(Escrow.Status.Released));
        assertEq(escrow.credits(payee, address(imd)), 97.5 ether);
        assertEq(escrow.credits(treasury, address(imd)), 2.5 ether);
        vm.prank(payee);
        escrow.withdraw(address(imd));
        vm.prank(treasury);
        escrow.withdraw(address(imd));
        assertEq(imd.balanceOf(payee), 97.5 ether);
        assertEq(imd.balanceOf(treasury), 2.5 ether);
        assertEq(escrow.held(address(imd)), 0);
        assertEq(imd.balanceOf(address(escrow)), 0);
    }

    function test_theFeeIsFixedAtDeposit() public {
        bytes32 id = _deposit();
        vm.prank(admin);
        escrow.setFee(1_000, treasury);
        vm.startPrank(arbiter);
        escrow.accept(id);
        escrow.release(id);
        vm.stopPrank();
        assertEq(escrow.credits(treasury, address(imd)), 2.5 ether);
    }

    function test_theClientMayReleaseThemselves() public {
        bytes32 id = _deposit();
        vm.prank(arbiter);
        escrow.accept(id);
        vm.warp(deliverBy + 1); // even after the deadline
        vm.prank(client);
        escrow.release(id);
        assertEq(escrow.credits(payee, address(imd)), 97.5 ether);
    }

    // ------------------------------------------------------- refunds

    function test_theClientCancelsBeforeAcceptance() public {
        bytes32 id = _deposit();
        vm.prank(client);
        escrow.cancel(id);
        assertEq(uint8(_status(id)), uint8(Escrow.Status.Refunded));
        assertEq(escrow.credits(client, address(imd)), AMOUNT);
        // Nothing more to accept, release or cancel.
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(Escrow.WrongStatus.selector, Escrow.Status.Refunded));
        escrow.accept(id);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Escrow.WrongStatus.selector, Escrow.Status.Refunded));
        escrow.cancel(id);
    }

    function test_afterAcceptanceTheClientWaitsForTheDeadline() public {
        bytes32 id = _deposit();
        vm.prank(arbiter);
        escrow.accept(id);
        vm.prank(client);
        vm.expectRevert(Escrow.TooEarly.selector);
        escrow.cancel(id);
        vm.warp(deliverBy + 1);
        // Past the deadline the arbiter can no longer pay out: the client reclaims.
        vm.prank(arbiter);
        vm.expectRevert(Escrow.TooLate.selector);
        escrow.release(id);
        vm.prank(client);
        escrow.cancel(id);
        assertEq(escrow.credits(client, address(imd)), AMOUNT);
    }

    function test_arbiterOrPayeeRefund() public {
        bytes32 a = _deposit();
        vm.prank(arbiter);
        escrow.refund(a); // declined before acceptance
        assertEq(escrow.credits(client, address(imd)), AMOUNT);

        vm.prank(client);
        bytes32 b = escrow.deposit(keccak256("p2"), payee, address(imd), AMOUNT, acceptBy, deliverBy);
        vm.prank(arbiter);
        escrow.accept(b);
        vm.prank(payee);
        escrow.refund(b); // the job failed after acceptance
        assertEq(escrow.credits(client, address(imd)), 2 * AMOUNT);
    }

    function test_acceptanceClosesAtAcceptBy() public {
        bytes32 id = _deposit();
        vm.warp(acceptBy + 1);
        vm.prank(arbiter);
        vm.expectRevert(Escrow.TooLate.selector);
        escrow.accept(id);
        vm.prank(client);
        escrow.cancel(id);
    }

    // ------------------------------------------------------- who may not

    function test_nobodyElseMovesADeal() public {
        bytes32 id = _deposit();
        vm.startPrank(stranger);
        vm.expectRevert(Escrow.NotAllowed.selector);
        escrow.accept(id);
        vm.expectRevert(Escrow.NotAllowed.selector);
        escrow.cancel(id);
        vm.expectRevert(Escrow.NotAllowed.selector);
        escrow.refund(id);
        vm.stopPrank();
        // The payee cannot accept or pay itself; the client cannot accept.
        vm.prank(payee);
        vm.expectRevert(Escrow.NotAllowed.selector);
        escrow.accept(id);
        vm.prank(client);
        vm.expectRevert(Escrow.NotAllowed.selector);
        escrow.accept(id);
        vm.prank(arbiter);
        escrow.accept(id);
        vm.prank(payee);
        vm.expectRevert(Escrow.NotAllowed.selector);
        escrow.release(id);
        vm.prank(stranger);
        vm.expectRevert(Escrow.NotAllowed.selector);
        escrow.release(id);
        // The owner has no way in at all.
        vm.startPrank(admin);
        vm.expectRevert(Escrow.NotAllowed.selector);
        escrow.release(id);
        vm.expectRevert(Escrow.NotAllowed.selector);
        escrow.refund(id);
        vm.stopPrank();
    }

    function test_releaseNeedsAcceptance() public {
        bytes32 id = _deposit();
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(Escrow.WrongStatus.selector, Escrow.Status.Funded));
        escrow.release(id);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Escrow.WrongStatus.selector, Escrow.Status.Funded));
        escrow.release(id);
    }

    function test_aReleasedDealIsFinal() public {
        bytes32 id = _deposit();
        vm.startPrank(arbiter);
        escrow.accept(id);
        escrow.release(id);
        vm.expectRevert(abi.encodeWithSelector(Escrow.WrongStatus.selector, Escrow.Status.Released));
        escrow.refund(id);
        vm.expectRevert(abi.encodeWithSelector(Escrow.WrongStatus.selector, Escrow.Status.Released));
        escrow.release(id);
        vm.stopPrank();
        vm.warp(deliverBy + 1);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Escrow.WrongStatus.selector, Escrow.Status.Released));
        escrow.cancel(id);
    }

    function test_onlyTheOwnerConfigures() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.setArbiter(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.setFee(0, stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.setToken(address(imd), true, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.recoverSurplus(address(imd), stranger);
        vm.stopPrank();
        vm.prank(admin);
        vm.expectRevert(Escrow.BadFee.selector);
        escrow.setFee(1_001, treasury);
    }

    function test_aNewArbiterTakesOverAndTheOldOneIsOut() public {
        bytes32 id = _deposit();
        address next = makeAddr("next");
        vm.prank(admin);
        escrow.setArbiter(next);
        vm.prank(arbiter);
        vm.expectRevert(Escrow.NotAllowed.selector);
        escrow.accept(id);
        vm.prank(next);
        escrow.accept(id);
    }

    function test_disallowingATokenLeavesOpenDealsAlone() public {
        bytes32 id = _deposit();
        vm.prank(admin);
        escrow.setToken(address(imd), false, 0);
        vm.startPrank(arbiter);
        escrow.accept(id);
        escrow.release(id);
        vm.stopPrank();
        vm.prank(payee);
        escrow.withdraw(address(imd));
        assertEq(imd.balanceOf(payee), 97.5 ether);
    }

    // ------------------------------------------------------- withdrawals

    function test_withdrawPaysOnceAndRefusesNothing() public {
        bytes32 id = _deposit();
        vm.prank(client);
        escrow.cancel(id);
        vm.startPrank(client);
        escrow.withdraw(address(imd));
        vm.expectRevert(Escrow.NothingToWithdraw.selector);
        escrow.withdraw(address(imd));
        vm.stopPrank();
    }

    function test_aReceiverThatRejectsEthBlocksOnlyItself() public {
        RejectsEth bad = new RejectsEth();
        vm.prank(client);
        bytes32 id = escrow.deposit{value: 1 ether}(REF, address(bad), address(0), 1 ether, acceptBy, deliverBy);
        vm.startPrank(arbiter);
        escrow.accept(id);
        escrow.release(id); // credited, not sent: never reverts
        vm.stopPrank();
        vm.prank(address(bad));
        vm.expectRevert(Escrow.TransferFailed.selector);
        escrow.withdraw(address(0));
        // The treasury's fee is unaffected.
        vm.prank(treasury);
        escrow.withdraw(address(0));
        assertEq(treasury.balance, 0.025 ether);
    }

    function test_reentrantWithdrawIsStopped() public {
        Reenterer r = new Reenterer(escrow);
        vm.deal(address(r), 0);
        vm.deal(stranger, 5 ether);
        vm.prank(stranger);
        r.deposit{value: 1 ether}(REF, payee, acceptBy, deliverBy);
        // Someone else's ETH sits in the escrow too.
        vm.prank(client);
        escrow.deposit{value: 3 ether}(keccak256("p2"), payee, address(0), 3 ether, acceptBy, deliverBy);
        r.cancel();
        vm.expectRevert(Escrow.TransferFailed.selector);
        r.withdraw();
        assertEq(address(escrow).balance, 4 ether);
    }

    function test_recoverSurplusNeverReachesEscrowedMoney() public {
        _deposit();
        vm.prank(admin);
        vm.expectRevert(Escrow.NothingToWithdraw.selector);
        escrow.recoverSurplus(address(imd), admin);
        imd.mint(address(escrow), 7 ether); // sent by mistake
        vm.prank(admin);
        escrow.recoverSurplus(address(imd), admin);
        assertEq(imd.balanceOf(admin), 7 ether);
        assertEq(imd.balanceOf(address(escrow)), AMOUNT);
    }

    function test_plainEthTransfersAreRefused() public {
        vm.prank(client);
        (bool ok,) = address(escrow).call{value: 1 ether}("");
        assertFalse(ok);
    }

    // ------------------------------------------------------- invariants

    /// Whatever happens, what the escrow holds equals what it owes, and the
    /// client's money ends with the payee and treasury or back with the client.
    function testFuzz_moneyIsConserved(uint256 amount, uint16 fee, uint8 path) public {
        amount = bound(amount, 1, 1_000 ether);
        fee = uint16(bound(fee, 0, 1_000));
        vm.prank(admin);
        escrow.setFee(fee, treasury);
        vm.prank(client);
        bytes32 id = escrow.deposit(REF, payee, address(imd), amount, acceptBy, deliverBy);

        path = path % 4;
        if (path == 0) {
            vm.prank(client);
            escrow.cancel(id);
        } else {
            vm.prank(arbiter);
            escrow.accept(id);
            if (path == 1) {
                vm.prank(arbiter);
                escrow.release(id);
            } else if (path == 2) {
                vm.prank(arbiter);
                escrow.refund(id);
            } else {
                vm.warp(deliverBy + 1);
                vm.prank(client);
                escrow.cancel(id);
            }
        }
        uint256 owed = escrow.credits(client, address(imd)) + escrow.credits(payee, address(imd))
            + escrow.credits(treasury, address(imd));
        assertEq(owed, amount);
        assertEq(escrow.held(address(imd)), imd.balanceOf(address(escrow)));
        if (path == 1) assertEq(escrow.credits(treasury, address(imd)), (amount * fee) / 10_000);
    }
}

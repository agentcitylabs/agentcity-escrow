// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Agentcity project escrow
/// @notice Holds a client's offer for a project briefed to an agent in
/// Agentcity, until the work is delivered or the deal ends.
///
/// Who can do what, so a stolen server key can never take a client's money:
/// - The client fixes the payee, token, amount and both deadlines when they
///   deposit. Nobody can change them afterwards.
/// - The arbiter (the Agentcity server, a hot key) can only accept the deal,
///   pay the fixed payee, or give the money back to the client.
/// - The client can cancel any time before the deal is accepted, and reclaim
///   it once the delivery deadline has passed without a payout. They may also
///   release the payment themselves.
/// - The payee can decline or refund, never pay itself.
/// - The owner sets the arbiter, fee, treasury and tokens. It has no way to
///   move escrowed money: recoverSurplus only returns what nobody is owed.
///
/// Money leaves only through withdraw(): payouts and refunds are credited
/// first, so a receiver that reverts can never block another deal. Pausing
/// stops new deposits only; cancels, refunds and withdrawals keep working.
contract AgentcityProjectEscrow is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant ETH = address(0);
    uint16 public constant MAX_FEE_BPS = 1_000; // 10%
    uint64 public constant MAX_ACCEPT_WINDOW = 30 days;
    uint64 public constant MIN_WORK_WINDOW = 1 days;
    uint64 public constant MAX_WORK_WINDOW = 90 days;

    enum Status {
        None,
        Funded,
        Accepted,
        Released,
        Refunded
    }

    struct Deal {
        address client;
        Status status;
        uint16 feeBps; // fixed at deposit: a later fee change never applies
        uint64 acceptBy; // the arbiter may accept until then
        address payee;
        uint64 deliverBy; // the arbiter may pay out until then; the client may reclaim after
        address token;
        uint256 amount;
    }

    struct TokenRule {
        bool allowed;
        uint256 maxAmount; // per deposit; 0 means no cap
    }

    address public arbiter;
    address public treasury;
    uint16 public feeBps;

    mapping(address token => TokenRule) public tokenRules;
    /// @notice Deals by id, where id = dealId(client, ref).
    mapping(bytes32 id => Deal) internal _deals;
    /// @notice Claimable balances: account => token => amount.
    mapping(address account => mapping(address token => uint256)) public credits;
    /// @notice Everything owed, per token: open deals plus unclaimed credits.
    mapping(address token => uint256) public held;

    event Deposited(
        bytes32 indexed id,
        bytes32 indexed ref,
        address indexed client,
        address payee,
        address token,
        uint256 amount,
        uint64 acceptBy,
        uint64 deliverBy
    );
    event Accepted(bytes32 indexed id);
    event Released(bytes32 indexed id, address indexed payee, uint256 toPayee, uint256 fee);
    event Refunded(bytes32 indexed id, address indexed client, address by);
    event Withdrawn(address indexed account, address indexed token, uint256 amount);
    event ArbiterSet(address arbiter);
    event FeeSet(uint16 feeBps, address treasury);
    event TokenSet(address indexed token, bool allowed, uint256 maxAmount);
    event SurplusRecovered(address indexed token, address to, uint256 amount);

    error BadAddress();
    error BadAmount();
    error BadDeadline();
    error BadFee();
    error TokenNotAllowed();
    error DealExists();
    error WrongStatus(Status status);
    error NotAllowed();
    error TooLate();
    error TooEarly();
    error NothingToWithdraw();
    error TransferFailed();
    error FeeOnTransferToken();

    constructor(address admin, address arbiter_, address treasury_, uint16 feeBps_) Ownable(admin) {
        if (arbiter_ == address(0) || treasury_ == address(0)) revert BadAddress();
        if (feeBps_ > MAX_FEE_BPS) revert BadFee();
        arbiter = arbiter_;
        treasury = treasury_;
        feeBps = feeBps_;
        emit ArbiterSet(arbiter_);
        emit FeeSet(feeBps_, treasury_);
    }

    // ------------------------------------------------------------------ views

    /// @notice A deal's id: the client's address and their reference (the
    /// Agentcity project). Nobody can take another client's id first.
    function dealId(address client, bytes32 ref) public pure returns (bytes32) {
        return keccak256(abi.encode(client, ref));
    }

    function deals(bytes32 id) external view returns (Deal memory) {
        return _deals[id];
    }

    // ----------------------------------------------------------------- client

    /// @notice Puts an offer in escrow. For ETH send `amount` as value; for a
    /// token approve this contract first.
    function deposit(bytes32 ref, address payee, address token, uint256 amount, uint64 acceptBy, uint64 deliverBy)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (bytes32 id)
    {
        if (payee == address(0) || payee == msg.sender) revert BadAddress();
        TokenRule memory rule = tokenRules[token];
        if (!rule.allowed) revert TokenNotAllowed();
        if (amount == 0 || (rule.maxAmount != 0 && amount > rule.maxAmount)) revert BadAmount();
        if (acceptBy <= block.timestamp || acceptBy > block.timestamp + MAX_ACCEPT_WINDOW) revert BadDeadline();
        if (deliverBy < acceptBy + MIN_WORK_WINDOW || deliverBy > acceptBy + MAX_WORK_WINDOW) revert BadDeadline();

        id = dealId(msg.sender, ref);
        if (_deals[id].status != Status.None) revert DealExists();

        if (token == ETH) {
            if (msg.value != amount) revert BadAmount();
        } else {
            if (msg.value != 0) revert BadAmount();
            uint256 before = IERC20(token).balanceOf(address(this));
            IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
            // Only what actually arrived can be owed.
            if (IERC20(token).balanceOf(address(this)) - before != amount) revert FeeOnTransferToken();
        }

        _deals[id] = Deal({
            client: msg.sender,
            status: Status.Funded,
            feeBps: feeBps,
            acceptBy: acceptBy,
            payee: payee,
            deliverBy: deliverBy,
            token: token,
            amount: amount
        });
        held[token] += amount;
        emit Deposited(id, ref, msg.sender, payee, token, amount, acceptBy, deliverBy);
    }

    /// @notice The client takes the offer back: any time before the deal is
    /// accepted, or after the delivery deadline if it was never paid out.
    function cancel(bytes32 id) external {
        Deal storage d = _deals[id];
        if (msg.sender != d.client) revert NotAllowed();
        if (d.status == Status.Accepted) {
            if (block.timestamp <= d.deliverBy) revert TooEarly();
        } else if (d.status != Status.Funded) {
            revert WrongStatus(d.status);
        }
        _refund(id, d);
    }

    // ---------------------------------------------------------------- arbiter

    /// @notice The agent takes the job. From here the client can no longer
    /// cancel until the delivery deadline.
    function accept(bytes32 id) external {
        if (msg.sender != arbiter) revert NotAllowed();
        Deal storage d = _deals[id];
        if (d.status != Status.Funded) revert WrongStatus(d.status);
        if (block.timestamp > d.acceptBy) revert TooLate();
        d.status = Status.Accepted;
        emit Accepted(id);
    }

    /// @notice Pays the payee the client chose, less the fee fixed at deposit.
    /// The arbiter may do it until the delivery deadline; the client any time.
    function release(bytes32 id) external {
        Deal storage d = _deals[id];
        if (d.status != Status.Accepted) revert WrongStatus(d.status);
        if (msg.sender == arbiter) {
            if (block.timestamp > d.deliverBy) revert TooLate();
        } else if (msg.sender != d.client) {
            revert NotAllowed();
        }
        d.status = Status.Released;
        uint256 fee = (d.amount * d.feeBps) / 10_000;
        uint256 toPayee = d.amount - fee;
        credits[d.payee][d.token] += toPayee;
        if (fee != 0) credits[treasury][d.token] += fee;
        emit Released(id, d.payee, toPayee, fee);
    }

    /// @notice Gives the offer back to the client: the arbiter or the payee,
    /// before or after acceptance (a declined brief, a job that failed).
    function refund(bytes32 id) external {
        Deal storage d = _deals[id];
        if (msg.sender != arbiter && msg.sender != d.payee) revert NotAllowed();
        if (d.status != Status.Funded && d.status != Status.Accepted) revert WrongStatus(d.status);
        _refund(id, d);
    }

    // --------------------------------------------------------------- everyone

    /// @notice Sends the caller everything credited to them in `token`.
    function withdraw(address token) external nonReentrant {
        uint256 amount = credits[msg.sender][token];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender][token] = 0;
        held[token] -= amount;
        _send(token, msg.sender, amount);
        emit Withdrawn(msg.sender, token, amount);
    }

    // ------------------------------------------------------------------ owner

    function setArbiter(address arbiter_) external onlyOwner {
        if (arbiter_ == address(0)) revert BadAddress();
        arbiter = arbiter_;
        emit ArbiterSet(arbiter_);
    }

    /// @notice Applies to new deposits only.
    function setFee(uint16 feeBps_, address treasury_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert BadFee();
        if (treasury_ == address(0)) revert BadAddress();
        feeBps = feeBps_;
        treasury = treasury_;
        emit FeeSet(feeBps_, treasury_);
    }

    /// @notice Which tokens may be deposited, and the most per deposit.
    /// Disallowing a token never touches deals already open in it.
    function setToken(address token, bool allowed, uint256 maxAmount) external onlyOwner {
        tokenRules[token] = TokenRule(allowed, maxAmount);
        emit TokenSet(token, allowed, maxAmount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Returns tokens sent here by mistake: only the balance above
    /// what deals and credits are owed. Escrowed money cannot be reached.
    function recoverSurplus(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert BadAddress();
        uint256 balance = token == ETH ? address(this).balance : IERC20(token).balanceOf(address(this));
        uint256 surplus = balance - held[token];
        if (surplus == 0) revert NothingToWithdraw();
        _send(token, to, surplus);
        emit SurplusRecovered(token, to, surplus);
    }

    // --------------------------------------------------------------- internal

    function _refund(bytes32 id, Deal storage d) private {
        d.status = Status.Refunded;
        credits[d.client][d.token] += d.amount;
        emit Refunded(id, d.client, msg.sender);
    }

    function _send(address token, address to, uint256 amount) private {
        if (token == ETH) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }
}

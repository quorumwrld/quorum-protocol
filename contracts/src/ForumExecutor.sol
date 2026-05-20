// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBondingEscrow} from "./interfaces/IBondingEscrow.sol";
import {IChamberRegistry} from "./interfaces/IChamberRegistry.sol";

/// @title ForumExecutor
/// @notice Token-agnostic bounty escrow with AGAINST-bonder quorum approval.
///         Fork of `GitlawbBounty.sol` (MIT) re-parameterized to:
///           - accept ANY ERC-20 as the bounty currency (not just $GITLAWB)
///           - replace single-creator approve with N-of-M stake-weighted vote
///             by AGAINST-bonders (the natural reviewers)
///           - settle the linked `BondingEscrow` position on completion / dispute
/// @dev Quorum's `ForumExecutor` is what shippable AI work runs through.
///
///      Emergency pause: only `createBounty` is gated. Existing bounties keep their
///      full lifecycle (claim, submit, vote, finalize, cancel, dispute) so funds in
///      escrow are never trapped during an incident. Pausing only stops NEW value
///      from being locked up.
contract ForumExecutor is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Open, // 0
        Claimed, // 1
        Submitted, // 2
        Approved, // 3 — terminal
        Rejected, // 4 — terminal (AGAINST won)
        Cancelled, // 5 — terminal (creator backed out, unclaimed only)
        Disputed // 6 — expired claim, returned to Open
    }

    struct Bounty {
        IERC20 token; // bounty currency (the idea's ERC-20)
        address creator;
        uint256 amount;
        string repoOwner;
        string repoName;
        string issueId;
        string title;
        string claimantDid;
        address claimantAddress;
        string prId;
        Status status;
        uint64 createdAt;
        uint64 claimedAt;
        uint64 submittedAt;
        uint64 reviewDeadline;
        uint64 claimDeadline;
        uint256 votesApprove; // sum of AGAINST-stakes voting approve
        uint256 votesReject; // sum of AGAINST-stakes voting reject
    }

    address public treasury;
    IBondingEscrow public bondingEscrow;
    /// H-02 fix: registry used to enforce that bounty currencies are real Quorum
    /// idea tokens (no fee-on-transfer / rebasing / blacklist-aware ERC-20s).
    IChamberRegistry public chamberRegistry;

    /// Basis points cut from each completed bounty going to treasury.
    uint16 public protocolFeeBps;
    /// Default time (seconds) an agent has to submit a PR after claiming.
    uint64 public defaultClaimDeadline;
    /// Default time (seconds) AGAINST-bonders have to vote after PR is submitted.
    uint64 public defaultReviewDeadline;

    /// H-03 fix: minimum AGAINST-stake required to short-circuit `finalize` before
    /// the review deadline. Defaults to 100e18 (~100 idea tokens) — prevents the
    /// "1 wei AGAINST + vote(approve) + finalize" flash-bond bypass.
    uint256 public minQuorumStake;
    /// H-03 fix: minimum seconds after `submitBounty` before `finalize` is allowed
    /// to settle pre-deadline on a vote majority. Defaults to 1 hour. Forces a
    /// minimum observation window even when quorum is met.
    uint64 public minReviewDelay;

    uint256 public nextBountyId;

    mapping(uint256 bountyId => Bounty) public bounties;
    mapping(bytes32 didHash => uint256) public agentEarnings;
    mapping(bytes32 didHash => uint256) public agentCompletedCount;
    /// H-01 fix: per-bounty round counter — incremented each time `disputeBounty`
    /// returns the bounty to Open. Vote-tracking is namespaced by
    /// `(bountyId, voteRound, voter)` so stale votes from a prior round don't
    /// lock reviewers out of subsequent rounds.
    mapping(uint256 bountyId => uint256) public voteRound;
    /// H-01 fix: round-scoped vote tracking. Replaces the old `hasVoted` mapping
    /// (kept as a view below for backward compatibility / off-chain indexers).
    mapping(uint256 bountyId => mapping(uint256 round => mapping(address voter => bool))) public votedInRound;

    uint256 public totalPaidOut;
    uint256 public totalFeesCollected;

    event TreasuryUpdated(address indexed newTreasury);
    event BondingEscrowUpdated(address indexed newEscrow);
    event ChamberRegistryUpdated(address indexed newRegistry);
    event FeeUpdated(uint16 newFeeBps);
    event ClaimDeadlineUpdated(uint64 newDeadline);
    event ReviewDeadlineUpdated(uint64 newDeadline);
    event MinQuorumStakeUpdated(uint256 newMinQuorumStake);
    event MinReviewDelayUpdated(uint64 newMinReviewDelay);

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed creator,
        address indexed token,
        uint256 amount,
        string repoOwner,
        string repoName,
        string issueId,
        string title
    );
    event BountyClaimed(uint256 indexed bountyId, string claimantDid, address indexed claimant);
    event BountySubmitted(uint256 indexed bountyId, string prId);
    event ReviewVoted(uint256 indexed bountyId, address indexed voter, bool approve, uint256 weight);
    event BountyApproved(uint256 indexed bountyId, address indexed claimant, uint256 payout, uint256 fee);
    event BountyRejected(uint256 indexed bountyId);
    event BountyCancelled(uint256 indexed bountyId);
    event BountyDisputed(uint256 indexed bountyId);

    error NotCreator(uint256 bountyId);
    error NotClaimant(uint256 bountyId);
    error InvalidStatus(uint256 bountyId, Status expected, Status actual);
    error DeadlineNotExceeded(uint256 bountyId);
    error DeadlineExceeded(uint256 bountyId);
    error ZeroAmount();
    error ZeroAddress();
    error FeeTooHigh(uint16 bps);
    error DeadlineTooShort(uint64 secs);
    error AlreadyVoted();
    error NoStake();
    error VotesNotConclusive();
    /// H-02: bounty currency is not a Quorum factory-deployed idea token.
    error NotIdeaToken();

    constructor(address initialOwner, address treasury_, address bondingEscrow_, address chamberRegistry_)
        Ownable(initialOwner)
    {
        if (treasury_ == address(0) || bondingEscrow_ == address(0) || chamberRegistry_ == address(0)) {
            revert ZeroAddress();
        }
        treasury = treasury_;
        bondingEscrow = IBondingEscrow(bondingEscrow_);
        chamberRegistry = IChamberRegistry(chamberRegistry_);
        protocolFeeBps = 500; // 5%
        defaultClaimDeadline = 7 days;
        defaultReviewDeadline = 3 days;
        // H-03 fix defaults: a meaningful AGAINST quorum and a minimum delay
        // between submit and finalize-via-vote-majority. See `finalize` below.
        minQuorumStake = 100e18;
        minReviewDelay = 1 hours;
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function setBondingEscrow(address newEscrow) external onlyOwner {
        if (newEscrow == address(0)) revert ZeroAddress();
        bondingEscrow = IBondingEscrow(newEscrow);
        emit BondingEscrowUpdated(newEscrow);
    }

    function setChamberRegistry(address newRegistry) external onlyOwner {
        if (newRegistry == address(0)) revert ZeroAddress();
        chamberRegistry = IChamberRegistry(newRegistry);
        emit ChamberRegistryUpdated(newRegistry);
    }

    function setProtocolFee(uint16 bps) external onlyOwner {
        if (bps > 1000) revert FeeTooHigh(bps);
        protocolFeeBps = bps;
        emit FeeUpdated(bps);
    }

    function setDefaultClaimDeadline(uint64 secs) external onlyOwner {
        if (secs < 1 hours) revert DeadlineTooShort(secs);
        defaultClaimDeadline = secs;
        emit ClaimDeadlineUpdated(secs);
    }

    function setDefaultReviewDeadline(uint64 secs) external onlyOwner {
        if (secs < 1 hours) revert DeadlineTooShort(secs);
        defaultReviewDeadline = secs;
        emit ReviewDeadlineUpdated(secs);
    }

    function setMinQuorumStake(uint256 newMin) external onlyOwner {
        minQuorumStake = newMin;
        emit MinQuorumStakeUpdated(newMin);
    }

    function setMinReviewDelay(uint64 newDelay) external onlyOwner {
        minReviewDelay = newDelay;
        emit MinReviewDelayUpdated(newDelay);
    }

    // ── Emergency pause ──────────────────────────────────────────────────────
    //
    // Only `createBounty` is gated. Claim/submit/vote/finalize/cancel/dispute
    // are never paused — once funds are in escrow they MUST always be releasable
    // to avoid trapping creators' bounty deposits during an incident.

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ── Bounty lifecycle ─────────────────────────────────────────────────────

    /// Create a bounty in any registered Quorum idea token. The token MUST have
    /// been deployed through `IdeaFactory` (security audit H-02).
    function createBounty(
        IERC20 token,
        uint256 amount,
        string calldata repoOwner,
        string calldata repoName,
        string calldata issueId,
        string calldata title
    ) external whenNotPaused nonReentrant returns (uint256 bountyId) {
        if (amount == 0) revert ZeroAmount();
        if (address(token) == address(0)) revert ZeroAddress();
        // H-02 fix: only Quorum factory-deployed idea tokens are accepted as
        // bounty currency. Blocks fee-on-transfer, rebasing, and blacklist
        // tokens that would break BondingEscrow accounting / FeeRouter flushes.
        if (!chamberRegistry.isRegisteredIdea(address(token))) revert NotIdeaToken();

        token.safeTransferFrom(msg.sender, address(this), amount);

        bountyId = nextBountyId++;

        Bounty storage b = bounties[bountyId];
        b.token = token;
        b.creator = msg.sender;
        b.amount = amount;
        b.repoOwner = repoOwner;
        b.repoName = repoName;
        b.issueId = issueId;
        b.title = title;
        b.status = Status.Open;
        b.createdAt = uint64(block.timestamp);
        b.claimDeadline = defaultClaimDeadline;
        b.reviewDeadline = defaultReviewDeadline;

        bondingEscrow.registerBounty(bountyId, address(token));

        emit BountyCreated(bountyId, msg.sender, address(token), amount, repoOwner, repoName, issueId, title);
    }

    function claimBounty(uint256 bountyId, string calldata agentDid) external {
        Bounty storage b = bounties[bountyId];
        if (b.status != Status.Open) revert InvalidStatus(bountyId, Status.Open, b.status);

        b.claimantDid = agentDid;
        b.claimantAddress = msg.sender;
        b.claimedAt = uint64(block.timestamp);
        b.status = Status.Claimed;

        emit BountyClaimed(bountyId, agentDid, msg.sender);
    }

    function submitBounty(uint256 bountyId, string calldata prId) external {
        Bounty storage b = bounties[bountyId];
        if (b.status != Status.Claimed) revert InvalidStatus(bountyId, Status.Claimed, b.status);
        if (msg.sender != b.claimantAddress) revert NotClaimant(bountyId);
        if (block.timestamp > b.claimedAt + b.claimDeadline) revert DeadlineExceeded(bountyId);

        b.prId = prId;
        b.submittedAt = uint64(block.timestamp);
        b.status = Status.Submitted;

        emit BountySubmitted(bountyId, prId);
    }

    /// AGAINST-bonders vote on whether to approve or reject the PR.
    /// Weight = caller's AGAINST stake on this bounty (read from BondingEscrow).
    /// @dev H-01 fix: vote tracking is namespaced by the current `voteRound[bountyId]`.
    ///      `disputeBounty` increments the round, so reviewers from a prior round
    ///      can vote again in the new round (their stake is still in escrow and
    ///      still counts toward `totalAgainst`).
    function vote(uint256 bountyId, bool approve) external {
        Bounty storage b = bounties[bountyId];
        if (b.status != Status.Submitted) revert InvalidStatus(bountyId, Status.Submitted, b.status);
        if (block.timestamp > b.submittedAt + b.reviewDeadline) revert DeadlineExceeded(bountyId);
        uint256 round = voteRound[bountyId];
        if (votedInRound[bountyId][round][msg.sender]) revert AlreadyVoted();

        IBondingEscrow.Position memory p = bondingEscrow.getPosition(bountyId, msg.sender);
        uint256 weight = uint256(p.againstStake);
        if (weight == 0) revert NoStake();

        votedInRound[bountyId][round][msg.sender] = true;
        if (approve) {
            b.votesApprove += weight;
        } else {
            b.votesReject += weight;
        }

        emit ReviewVoted(bountyId, msg.sender, approve, weight);
    }

    /// Backward-compat view: returns whether `voter` voted in the *current*
    /// round of `bountyId`. Off-chain indexers that previously read
    /// `hasVoted(bountyId, voter)` continue to work — the function is just
    /// a view now.
    function hasVoted(uint256 bountyId, address voter) external view returns (bool) {
        return votedInRound[bountyId][voteRound[bountyId]][voter];
    }

    /// Finalize the vote. Anyone can call after the review deadline OR once a strict
    /// majority of registered AGAINST-stake has voted one direction AND the minimum
    /// quorum + minimum review delay (H-03 protections) are satisfied.
    /// @dev H-03 fix: pre-deadline short-circuit requires
    ///        1. `totalAgainst >= minQuorumStake` (no 1-wei flash-bond bypass), AND
    ///        2. `block.timestamp >= submittedAt + minReviewDelay` (minimum observation window).
    ///      If either condition is missing, callers must wait for the full review deadline.
    function finalize(uint256 bountyId) external nonReentrant {
        Bounty storage b = bounties[bountyId];
        if (b.status != Status.Submitted) revert InvalidStatus(bountyId, Status.Submitted, b.status);

        IBondingEscrow.BountyState memory bs = bondingEscrow.getBounty(bountyId);
        uint256 totalAgainst = uint256(bs.totalAgainst);
        bool deadlinePassed = block.timestamp > b.submittedAt + b.reviewDeadline;

        // H-03 fix: only a *meaningful* AGAINST quorum past a minimum delay may
        // short-circuit the review window. Dust-stake majorities cannot bypass
        // the 3-day default review.
        bool earlySettleAllowed = totalAgainst >= minQuorumStake && block.timestamp >= b.submittedAt + minReviewDelay;
        bool majorityApprove = earlySettleAllowed && b.votesApprove * 2 > totalAgainst;
        bool majorityReject = earlySettleAllowed && b.votesReject * 2 > totalAgainst;

        if (!deadlinePassed && !majorityApprove && !majorityReject) revert VotesNotConclusive();

        // Decide outcome:
        // - If there are no AGAINST stakes at all, default = approve (no reviewers objected).
        // - Else, the side with more votes wins; tie → approve (benefit of doubt to coder).
        bool approve = totalAgainst == 0 || b.votesApprove >= b.votesReject;

        if (approve) {
            _approve(bountyId, b);
        } else {
            _reject(bountyId, b);
        }
    }

    function _approve(uint256 bountyId, Bounty storage b) internal {
        uint256 fee = (b.amount * protocolFeeBps) / 10_000;
        uint256 payout = b.amount - fee;

        b.status = Status.Approved;
        b.token.safeTransfer(b.claimantAddress, payout);
        if (fee > 0) {
            b.token.safeTransfer(treasury, fee);
        }

        bytes32 didHash = keccak256(bytes(b.claimantDid));
        agentEarnings[didHash] += payout;
        agentCompletedCount[didHash] += 1;
        totalPaidOut += payout;
        totalFeesCollected += fee;

        bondingEscrow.settle(bountyId, true);

        emit BountyApproved(bountyId, b.claimantAddress, payout, fee);
    }

    function _reject(uint256 bountyId, Bounty storage b) internal {
        b.status = Status.Rejected;
        // Refund the bounty amount back to creator (PR is no good).
        b.token.safeTransfer(b.creator, b.amount);
        bondingEscrow.settle(bountyId, false);
        emit BountyRejected(bountyId);
    }

    /// Cancel an unclaimed bounty — refunds creator.
    function cancelBounty(uint256 bountyId) external nonReentrant {
        Bounty storage b = bounties[bountyId];
        if (msg.sender != b.creator) revert NotCreator(bountyId);
        if (b.status != Status.Open) revert InvalidStatus(bountyId, Status.Open, b.status);

        b.status = Status.Cancelled;
        b.token.safeTransfer(b.creator, b.amount);
        emit BountyCancelled(bountyId);
    }

    /// Dispute an expired claim — bounty returns to Open. Anyone can call after the deadline.
    function disputeBounty(uint256 bountyId) external {
        Bounty storage b = bounties[bountyId];
        if (b.status != Status.Claimed && b.status != Status.Submitted) {
            revert InvalidStatus(bountyId, Status.Claimed, b.status);
        }
        uint256 deadline = b.status == Status.Claimed ? b.claimedAt + b.claimDeadline : b.submittedAt + b.reviewDeadline;
        if (block.timestamp <= deadline) revert DeadlineNotExceeded(bountyId);

        b.status = Status.Open;
        b.claimantDid = "";
        b.claimantAddress = address(0);
        b.prId = "";
        b.claimedAt = 0;
        b.submittedAt = 0;
        b.votesApprove = 0;
        b.votesReject = 0;
        // H-01 fix: bump the vote round so reviewers who voted in the prior
        // round can vote again. Their AGAINST stake is still in escrow and
        // still counts toward `totalAgainst`.
        voteRound[bountyId] += 1;

        emit BountyDisputed(bountyId);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function getAgentStats(string calldata agentDid) external view returns (uint256 earnings, uint256 completedCount) {
        bytes32 didHash = keccak256(bytes(agentDid));
        return (agentEarnings[didHash], agentCompletedCount[didHash]);
    }

    function getProtocolStats()
        external
        view
        returns (uint256 totalBounties, uint256 _totalPaidOut, uint256 _totalFeesCollected)
    {
        return (nextBountyId, totalPaidOut, totalFeesCollected);
    }

    /// Convenience view: read just the bounty status. Avoids ugly tuple destructuring
    /// over the auto-generated public mapping getter.
    function getStatus(uint256 bountyId) external view returns (Status) {
        return bounties[bountyId].status;
    }

    function getPrId(uint256 bountyId) external view returns (string memory) {
        return bounties[bountyId].prId;
    }

    function getClaimant(uint256 bountyId) external view returns (address) {
        return bounties[bountyId].claimantAddress;
    }
}

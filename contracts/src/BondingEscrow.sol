// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IBondingEscrow} from "./interfaces/IBondingEscrow.sol";

/// @title BondingEscrow
/// @notice FOR/AGAINST stakes on each ForumExecutor bounty. The winning side
///         claims their stake back plus a pro-rata share of the loser pool minus a
///         protocol cut.
/// @dev FOR/AGAINST primitive bound to bounty settlement — the winning side gets
///      their stake back plus a slashed share of the loser pool, the protocol
///      keeps a small cut.
///
///      Emergency pause: only `bondFor` / `bondAgainst` are gated. `settle`, `claim`,
///      and `flushProtocolCut` are intentionally NEVER paused — once a position is
///      open, the bonder must always be able to receive their settlement payout,
///      otherwise paused state would trap user funds.
///
///      Trust assumption on `registerBounty`'s `ideaToken` parameter: the executor
///      (set by owner via `setForumExecutor`) is trusted to pass only legitimate
///      idea tokens. The `onlyExecutor` modifier gates this entry point; the executor
///      itself only allows the `ForumExecutor.createBounty` flow which is open to
///      any caller, but the caller funds the bounty in that exact same token via
///      `safeTransferFrom`, so passing a malicious ERC-20 only griefs the caller.
contract BondingEscrow is IBondingEscrow, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // `Position` and `BountyState` are defined in `IBondingEscrow` and re-used here.

    address public forumExecutor;
    address public protocolTreasury;
    uint16 public protocolSlashBps; // share of LOSER pool taken by protocol (default 1000 = 10%)

    mapping(uint256 bountyId => BountyState) internal _bounties;
    mapping(uint256 bountyId => mapping(address bonder => Position)) internal _positions;
    mapping(uint256 bountyId => bool) internal _protocolFlushed;

    event ForumExecutorUpdated(address indexed previousExecutor, address indexed newExecutor);
    event ProtocolTreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event ProtocolSlashBpsUpdated(uint16 previousBps, uint16 newBps);
    event BountyRegistered(uint256 indexed bountyId, address indexed ideaToken);
    event Bonded(uint256 indexed bountyId, address indexed bonder, Side side, uint256 amount);
    event Settled(uint256 indexed bountyId, Settlement outcome);
    event Claimed(uint256 indexed bountyId, address indexed bonder, uint256 payout);

    error NotExecutor();
    error AlreadyRegistered(uint256 bountyId);
    error NotRegistered(uint256 bountyId);
    error AlreadySettled(uint256 bountyId);
    error NotSettled(uint256 bountyId);
    error NothingToClaim();
    error ZeroAmount();
    error ZeroAddress();
    error BpsTooHigh(uint16 bps);
    error AlreadyClaimed();

    constructor(address initialOwner, address treasury_) Ownable(initialOwner) {
        if (treasury_ == address(0)) revert ZeroAddress();
        protocolTreasury = treasury_;
        protocolSlashBps = 1000; // 10%
    }

    modifier onlyExecutor() {
        if (msg.sender != forumExecutor) revert NotExecutor();
        _;
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function setForumExecutor(address newExecutor) external onlyOwner {
        if (newExecutor == address(0)) revert ZeroAddress();
        emit ForumExecutorUpdated(forumExecutor, newExecutor);
        forumExecutor = newExecutor;
    }

    function setProtocolTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        emit ProtocolTreasuryUpdated(protocolTreasury, newTreasury);
        protocolTreasury = newTreasury;
    }

    function setProtocolSlashBps(uint16 newBps) external onlyOwner {
        if (newBps > 3000) revert BpsTooHigh(newBps); // hard ceiling 30%
        emit ProtocolSlashBpsUpdated(protocolSlashBps, newBps);
        protocolSlashBps = newBps;
    }

    // ── Emergency pause ──────────────────────────────────────────────────────
    //
    // Only the bond entry points are gated. `settle`, `claim`, and
    // `flushProtocolCut` keep working when paused so user funds are never
    // trapped mid-bounty.

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ── Executor hooks ───────────────────────────────────────────────────────

    function registerBounty(uint256 bountyId, address ideaToken) external onlyExecutor {
        if (ideaToken == address(0)) revert ZeroAddress();
        BountyState storage b = _bounties[bountyId];
        if (b.registered) revert AlreadyRegistered(bountyId);
        b.ideaToken = ideaToken;
        b.registered = true;
        emit BountyRegistered(bountyId, ideaToken);
    }

    function settle(uint256 bountyId, bool forWon) external onlyExecutor {
        BountyState storage b = _bounties[bountyId];
        if (!b.registered) revert NotRegistered(bountyId);
        if (b.settlement != Settlement.Open) revert AlreadySettled(bountyId);
        b.settlement = forWon ? Settlement.ForWon : Settlement.AgainstWon;
        emit Settled(bountyId, b.settlement);
    }

    // ── Bonders ──────────────────────────────────────────────────────────────

    function bondFor(uint256 bountyId, uint256 amount) external whenNotPaused nonReentrant {
        _bond(bountyId, amount, Side.For);
    }

    function bondAgainst(uint256 bountyId, uint256 amount) external whenNotPaused nonReentrant {
        _bond(bountyId, amount, Side.Against);
    }

    function _bond(uint256 bountyId, uint256 amount, Side side) internal {
        if (amount == 0) revert ZeroAmount();
        BountyState storage b = _bounties[bountyId];
        if (!b.registered) revert NotRegistered(bountyId);
        if (b.settlement != Settlement.Open) revert AlreadySettled(bountyId);

        IERC20(b.ideaToken).safeTransferFrom(msg.sender, address(this), amount);
        Position storage p = _positions[bountyId][msg.sender];
        if (side == Side.For) {
            p.forStake += uint128(amount);
            b.totalFor += uint128(amount);
        } else {
            p.againstStake += uint128(amount);
            b.totalAgainst += uint128(amount);
        }
        emit Bonded(bountyId, msg.sender, side, amount);
    }

    /// Claim winnings after settlement. Returns:
    ///   - If winner: own stake + pro-rata share of (loser pool * (10000 - protocolSlashBps) / 10000)
    ///   - If loser: 0 (their stake is forfeit)
    /// Protocol cut is transferred to treasury on first claim per bounty (lazily).
    function claim(uint256 bountyId) external nonReentrant {
        BountyState storage b = _bounties[bountyId];
        if (!b.registered) revert NotRegistered(bountyId);
        if (b.settlement == Settlement.Open) revert NotSettled(bountyId);

        Position storage p = _positions[bountyId][msg.sender];
        if (p.claimed) revert AlreadyClaimed();

        uint256 payout;
        uint16 winnerBps = 10_000 - protocolSlashBps;
        if (b.settlement == Settlement.ForWon) {
            if (p.forStake > 0 && b.totalFor > 0) {
                // share = loserPool * forStake / totalFor * winnerBps / 10000
                // Split into two mulDivs to avoid the intermediate overflow that
                // (loserPool × forStake × winnerBps) would trigger at uint128.max.
                uint256 grossShare = Math.mulDiv(uint256(b.totalAgainst), uint256(p.forStake), uint256(b.totalFor));
                uint256 netShare = Math.mulDiv(grossShare, winnerBps, 10_000);
                payout = uint256(p.forStake) + netShare;
            }
        } else {
            if (p.againstStake > 0 && b.totalAgainst > 0) {
                uint256 grossShare = Math.mulDiv(uint256(b.totalFor), uint256(p.againstStake), uint256(b.totalAgainst));
                uint256 netShare = Math.mulDiv(grossShare, winnerBps, 10_000);
                payout = uint256(p.againstStake) + netShare;
            }
        }

        p.claimed = true;

        if (payout > 0) {
            IERC20(b.ideaToken).safeTransfer(msg.sender, payout);
        }

        emit Claimed(bountyId, msg.sender, payout);
    }

    /// Flush the protocol cut from a settled bounty to treasury. One-shot (idempotent
    /// guard via `_protocolFlushed` mapping). Anyone can call.
    function flushProtocolCut(uint256 bountyId) external nonReentrant {
        BountyState storage b = _bounties[bountyId];
        if (!b.registered) revert NotRegistered(bountyId);
        if (b.settlement == Settlement.Open) revert NotSettled(bountyId);
        if (_protocolFlushed[bountyId]) return;

        uint256 loserPool = b.settlement == Settlement.ForWon ? b.totalAgainst : b.totalFor;
        uint256 cut = (loserPool * protocolSlashBps) / 10_000;
        _protocolFlushed[bountyId] = true;
        if (cut == 0) return;

        IERC20(b.ideaToken).safeTransfer(protocolTreasury, cut);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function getBounty(uint256 bountyId) external view returns (BountyState memory) {
        return _bounties[bountyId];
    }

    function getPosition(uint256 bountyId, address bonder) external view returns (Position memory) {
        return _positions[bountyId][bonder];
    }

    function isProtocolFlushed(uint256 bountyId) external view returns (bool) {
        return _protocolFlushed[bountyId];
    }
}

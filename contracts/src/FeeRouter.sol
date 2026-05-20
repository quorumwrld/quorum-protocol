// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFeeRouter} from "./interfaces/IFeeRouter.sol";

/// @title FeeRouter
/// @notice Receives Clanker fee tokens on behalf of each idea, then permissionlessly
///         splits them across 6 destinations per the idea's immutable BPS config:
///         [protocol, creator, debateWinners, FOR pool, AGAINST pool, executor pool].
/// @dev Designed for the pull-as-push pattern: anyone calls `flush(ideaToken)`,
///      the contract reads `balanceOf(this)` for that token, splits, and transfers
///      all in one tx. No per-recipient withdrawal state to maintain.
///
///      Each idea config is configured exactly once by `IdeaFactory` at deploy
///      time, then immutable. This is intentional — protocol-level governance over
///      live fee splits would let the operator drain ideas in flight.
contract FeeRouter is IFeeRouter, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// Indices into the recipients/bps arrays.
    uint256 public constant IDX_PROTOCOL = 0;
    uint256 public constant IDX_CREATOR = 1;
    uint256 public constant IDX_WINNERS = 2;
    uint256 public constant IDX_FOR = 3;
    uint256 public constant IDX_AGAINST = 4;
    uint256 public constant IDX_EXECUTOR = 5;
    uint256 public constant N_SLOTS = 6;

    struct FeeConfig {
        address[6] recipients;
        uint16[6] bps;
        bool configured;
    }

    address public factory;
    mapping(address ideaToken => FeeConfig) internal _configs;

    /// 30-day time-lock between `proposeRecovery` and `recoverStuck`. Gives the
    /// community a full month to call `flush(ideaToken)` before the owner can
    /// drain accumulated fees. Hard-coded — there is no admin path to shorten it.
    uint256 public constant RECOVERY_TIMELOCK = 30 days;

    /// Unix timestamp at which `recoverStuck(ideaToken, ...)` becomes callable.
    /// Zero means no active recovery proposal.
    mapping(address ideaToken => uint256 unlockTime) public recoveryUnlockTime;

    event FactoryUpdated(address indexed previousFactory, address indexed newFactory);
    event IdeaConfigured(address indexed ideaToken, address[6] recipients, uint16[6] bps);
    event Flushed(address indexed ideaToken, uint256 totalDistributed);
    event RecoveryProposed(address indexed ideaToken, uint256 unlockTime);
    event RecoveryCancelled(address indexed ideaToken);
    event RecoveryExecuted(address indexed ideaToken, address indexed to, uint256 amount);

    error NotFactory();
    error AlreadyConfigured(address ideaToken);
    error NotConfigured(address ideaToken);
    error BpsSumInvalid(uint256 actual);
    error ZeroRecipient(uint256 index);
    error ZeroAddress();
    error RecoveryNotReady();

    constructor(address initialOwner) Ownable(initialOwner) {}

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    function setFactory(address newFactory) external onlyOwner {
        if (newFactory == address(0)) revert ZeroAddress();
        emit FactoryUpdated(factory, newFactory);
        factory = newFactory;
    }

    function configure(address ideaToken, address[6] calldata recipients, uint16[6] calldata bps) external onlyFactory {
        if (ideaToken == address(0)) revert ZeroAddress();
        FeeConfig storage cfg = _configs[ideaToken];
        if (cfg.configured) revert AlreadyConfigured(ideaToken);

        uint256 sum;
        for (uint256 i; i < N_SLOTS; ++i) {
            if (recipients[i] == address(0)) revert ZeroRecipient(i);
            cfg.recipients[i] = recipients[i];
            cfg.bps[i] = bps[i];
            sum += bps[i];
        }
        if (sum != 10_000) revert BpsSumInvalid(sum);
        cfg.configured = true;

        emit IdeaConfigured(ideaToken, recipients, bps);
    }

    function flush(address ideaToken) external nonReentrant {
        FeeConfig storage cfg = _configs[ideaToken];
        if (!cfg.configured) revert NotConfigured(ideaToken);

        IERC20 t = IERC20(ideaToken);
        uint256 bal = t.balanceOf(address(this));
        if (bal == 0) return;

        uint256 distributed;
        // Distribute slots 0..N-2 by exact BPS; last slot gets the remainder
        // to avoid leaving dust (handles rounding deterministically).
        for (uint256 i; i < N_SLOTS - 1; ++i) {
            if (cfg.bps[i] > 0) {
                uint256 amount = (bal * cfg.bps[i]) / 10_000;
                if (amount > 0) {
                    t.safeTransfer(cfg.recipients[i], amount);
                    distributed += amount;
                }
            }
        }
        uint256 remainder = bal - distributed;
        if (remainder > 0) {
            t.safeTransfer(cfg.recipients[N_SLOTS - 1], remainder);
        }

        emit Flushed(ideaToken, bal);
    }

    function isConfigured(address ideaToken) external view returns (bool) {
        return _configs[ideaToken].configured;
    }

    function getConfig(address ideaToken) external view returns (address[6] memory recipients, uint16[6] memory bps) {
        FeeConfig storage cfg = _configs[ideaToken];
        if (!cfg.configured) revert NotConfigured(ideaToken);
        recipients = cfg.recipients;
        bps = cfg.bps;
    }

    // ── Recovery (time-locked) ───────────────────────────────────────────────
    //
    // If one of the 6 fee recipients for an idea becomes unusable (e.g. a
    // multi-sig key loss, a self-destructed proxy, a sanctioned address)
    // then `flush(ideaToken)` will revert forever on `safeTransfer`, trapping
    // every future fee tick in this contract. To unstuck that idea — and only
    // that idea — the owner can propose a recovery and, after a 30-day
    // time-lock, drain the trapped balance to a fresh address.
    //
    // The time-lock is the public notice period: holders can sell, LPs can
    // exit, etc. before the owner moves the balance.
    //
    // Recovery is per-idea — the owner cannot drain unrelated idea balances
    // with a single proposal. `recoverStuck` reads `balanceOf(this)` for the
    // SPECIFIC `ideaToken` argument.

    /// Owner starts the 30-day recovery clock for a specific idea token.
    /// Calling again resets the clock to 30 days from now.
    function proposeRecovery(address ideaToken) external onlyOwner {
        if (ideaToken == address(0)) revert ZeroAddress();
        uint256 unlockAt = block.timestamp + RECOVERY_TIMELOCK;
        recoveryUnlockTime[ideaToken] = unlockAt;
        emit RecoveryProposed(ideaToken, unlockAt);
    }

    /// Owner aborts the active recovery for a specific idea token.
    function cancelRecovery(address ideaToken) external onlyOwner {
        delete recoveryUnlockTime[ideaToken];
        emit RecoveryCancelled(ideaToken);
    }

    /// Owner drains the contract's current `ideaToken` balance to `to`.
    /// Reverts if no active proposal exists or the 30-day timelock has not
    /// yet elapsed.
    function recoverStuck(address ideaToken, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 unlockAt = recoveryUnlockTime[ideaToken];
        if (unlockAt == 0 || block.timestamp < unlockAt) revert RecoveryNotReady();
        delete recoveryUnlockTime[ideaToken];
        uint256 bal = IERC20(ideaToken).balanceOf(address(this));
        if (bal > 0) {
            IERC20(ideaToken).safeTransfer(to, bal);
        }
        emit RecoveryExecuted(ideaToken, to, bal);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Tests the time-locked owner recovery path for stuck idea-token
///         balances in FeeRouter. The flow is:
///           1. `proposeRecovery(ideaToken)` — owner kicks off a 30-day clock.
///           2. 30 days elapse — anyone can still `flush(ideaToken)`.
///           3. `recoverStuck(ideaToken, to)` — owner drains balance to `to`.
///         Plus the cancel path and the negative paths (early call, no proposal,
///         non-owner caller).
contract FeeRouterRecoveryTest is Test {
    FeeRouter router;
    MockERC20 token;

    address owner = address(0xA1);
    address factory = address(0xF1);
    address rescueDest = address(0xCAFE);

    address protocol = address(0xB1);
    address creator = address(0xB2);
    address winners = address(0xB3);
    address forPool = address(0xB4);
    address againstPool = address(0xB5);
    address executor = address(0xB6);

    address[6] recipients;
    uint16[6] bps;

    function setUp() public {
        vm.prank(owner);
        router = new FeeRouter(owner);
        vm.prank(owner);
        router.setFactory(factory);

        token = new MockERC20("Idea", "IDEA");

        recipients = [protocol, creator, winners, forPool, againstPool, executor];
        bps = [uint16(1500), uint16(1500), uint16(1000), uint16(2500), uint16(1000), uint16(2500)];

        // Configure + load some fee balance to make the rescue meaningful.
        vm.prank(factory);
        router.configure(address(token), recipients, bps);
        token.mint(address(router), 1000 ether);
    }

    // ── Timelock constant ───────────────────────────────────────────────────

    function test_RecoveryTimelock_Is30Days() public view {
        assertEq(router.RECOVERY_TIMELOCK(), 30 days);
    }

    // ── Propose ─────────────────────────────────────────────────────────────

    function test_ProposeRecovery_OnlyOwner() public {
        vm.prank(address(0xBADBEEF));
        vm.expectRevert();
        router.proposeRecovery(address(token));
    }

    function test_ProposeRecovery_SetsUnlockTime() public {
        vm.prank(owner);
        router.proposeRecovery(address(token));
        assertEq(router.recoveryUnlockTime(address(token)), block.timestamp + 30 days);
    }

    function test_ProposeRecovery_ZeroAddress_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        router.proposeRecovery(address(0));
    }

    function test_ProposeRecovery_OverwritesPreviousProposal() public {
        vm.prank(owner);
        router.proposeRecovery(address(token));
        uint256 first = router.recoveryUnlockTime(address(token));

        vm.warp(block.timestamp + 10 days);
        vm.prank(owner);
        router.proposeRecovery(address(token));
        uint256 second = router.recoveryUnlockTime(address(token));

        assertGt(second, first, "second proposal resets clock further out");
        assertEq(second, block.timestamp + 30 days);
    }

    // ── Cancel ──────────────────────────────────────────────────────────────

    function test_CancelRecovery_OnlyOwner() public {
        vm.prank(address(0xBADBEEF));
        vm.expectRevert();
        router.cancelRecovery(address(token));
    }

    function test_CancelRecovery_ClearsUnlockTime() public {
        vm.prank(owner);
        router.proposeRecovery(address(token));
        vm.prank(owner);
        router.cancelRecovery(address(token));
        assertEq(router.recoveryUnlockTime(address(token)), 0);
    }

    /// After cancel, `recoverStuck` reverts again — the proposal is fully aborted.
    function test_CancelRecovery_BlocksRecoverStuck() public {
        vm.prank(owner);
        router.proposeRecovery(address(token));
        vm.warp(block.timestamp + 31 days);
        vm.prank(owner);
        router.cancelRecovery(address(token));

        vm.prank(owner);
        vm.expectRevert(FeeRouter.RecoveryNotReady.selector);
        router.recoverStuck(address(token), rescueDest);
    }

    // ── RecoverStuck ────────────────────────────────────────────────────────

    function test_RecoverStuck_OnlyOwner() public {
        vm.prank(owner);
        router.proposeRecovery(address(token));
        vm.warp(block.timestamp + 31 days);

        vm.prank(address(0xBADBEEF));
        vm.expectRevert();
        router.recoverStuck(address(token), rescueDest);
    }

    function test_RecoverStuck_RevertsBeforeTimelock() public {
        vm.prank(owner);
        router.proposeRecovery(address(token));
        // Jump partway — but NOT past the unlock time.
        vm.warp(block.timestamp + 29 days);

        vm.prank(owner);
        vm.expectRevert(FeeRouter.RecoveryNotReady.selector);
        router.recoverStuck(address(token), rescueDest);
    }

    function test_RecoverStuck_RevertsWithNoProposal() public {
        vm.prank(owner);
        vm.expectRevert(FeeRouter.RecoveryNotReady.selector);
        router.recoverStuck(address(token), rescueDest);
    }

    function test_RecoverStuck_ZeroDest_Reverts() public {
        vm.prank(owner);
        router.proposeRecovery(address(token));
        vm.warp(block.timestamp + 31 days);
        vm.prank(owner);
        vm.expectRevert(FeeRouter.ZeroAddress.selector);
        router.recoverStuck(address(token), address(0));
    }

    function test_RecoverStuck_HappyPath_DrainsBalance() public {
        vm.prank(owner);
        router.proposeRecovery(address(token));
        vm.warp(block.timestamp + 30 days + 1);

        uint256 routerBalBefore = token.balanceOf(address(router));
        assertEq(routerBalBefore, 1000 ether);

        vm.prank(owner);
        router.recoverStuck(address(token), rescueDest);

        assertEq(token.balanceOf(address(router)), 0, "router fully drained");
        assertEq(token.balanceOf(rescueDest), 1000 ether, "rescueDest received full balance");
        assertEq(router.recoveryUnlockTime(address(token)), 0, "unlock time cleared after execution");
    }

    /// After a successful recovery, the next propose+recover cycle works again.
    function test_RecoverStuck_CanProposeAgainAfter() public {
        // First cycle
        vm.prank(owner);
        router.proposeRecovery(address(token));
        skip(31 days);
        vm.prank(owner);
        router.recoverStuck(address(token), rescueDest);

        // New fees flow in
        token.mint(address(router), 500 ether);

        // Second cycle — owner can propose a new recovery
        vm.prank(owner);
        router.proposeRecovery(address(token));
        skip(31 days);
        vm.prank(owner);
        router.recoverStuck(address(token), rescueDest);

        assertEq(token.balanceOf(rescueDest), 1500 ether);
    }

    /// Recovery is per-idea: proposing for token A must not affect token B.
    function test_RecoverStuck_PerIdeaScoped() public {
        MockERC20 otherToken = new MockERC20("Other", "OTH");
        vm.prank(factory);
        router.configure(address(otherToken), recipients, bps);
        otherToken.mint(address(router), 999 ether);

        vm.prank(owner);
        router.proposeRecovery(address(token));
        vm.warp(block.timestamp + 31 days);

        // Recover token A
        vm.prank(owner);
        router.recoverStuck(address(token), rescueDest);

        // Trying token B without its own proposal must revert
        vm.prank(owner);
        vm.expectRevert(FeeRouter.RecoveryNotReady.selector);
        router.recoverStuck(address(otherToken), rescueDest);

        // Token B balance is untouched
        assertEq(otherToken.balanceOf(address(router)), 999 ether);
    }

    /// During the 30-day window, anyone can still call `flush(ideaToken)` —
    /// this is the whole point of the timelock (chance to drain to legit
    /// recipients before owner moves balance).
    function test_FlushStillWorksDuringTimelock() public {
        vm.prank(owner);
        router.proposeRecovery(address(token));

        // 10 days in, someone calls flush — splits to the 6 recipients per BPS
        vm.warp(block.timestamp + 10 days);
        router.flush(address(token));

        assertEq(token.balanceOf(protocol), 150 ether);
        assertEq(token.balanceOf(address(router)), 0);
    }
}

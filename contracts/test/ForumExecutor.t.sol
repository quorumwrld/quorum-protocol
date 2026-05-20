// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ForumExecutor} from "../src/ForumExecutor.sol";
import {BondingEscrow} from "../src/BondingEscrow.sol";
import {ChamberRegistry} from "../src/ChamberRegistry.sol";
import {MockERC20} from "./MockERC20.sol";
import {FeeOnTransferMockERC20} from "./FeeOnTransferMockERC20.sol";

contract ForumExecutorTest is Test {
    ForumExecutor exec;
    BondingEscrow escrow;
    ChamberRegistry registry;
    MockERC20 token;

    address owner = address(0xA1);
    address treasury = address(0xA2);
    address creator = address(0xCEEEE);
    address agent = address(0xA6E47);
    address reviewer1 = address(0xB001);
    address reviewer2 = address(0xB002);
    /// H-02 fix: a stand-in for "the factory" so that `registry.isRegisteredIdea`
    /// returns `true` for the MockERC20 used as bounty currency in these tests.
    address mockFactory = address(0xFAC);

    function setUp() public {
        token = new MockERC20("Idea", "IDEA");
        vm.prank(owner);
        registry = new ChamberRegistry(owner);
        vm.prank(owner);
        registry.setFactory(mockFactory);
        vm.prank(mockFactory);
        registry.registerIdea(address(token), "Idea", "IDEA", "desc", creator, 1);

        vm.prank(owner);
        escrow = new BondingEscrow(owner, treasury);
        vm.prank(owner);
        exec = new ForumExecutor(owner, treasury, address(escrow), address(registry));
        vm.prank(owner);
        escrow.setForumExecutor(address(exec));

        // Fund creator with bounty amount
        token.mint(creator, 10_000 ether);
        vm.prank(creator);
        token.approve(address(exec), type(uint256).max);

        // Fund reviewers so they can stake against
        token.mint(reviewer1, 1000 ether);
        token.mint(reviewer2, 1000 ether);
        vm.prank(reviewer1);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(reviewer2);
        token.approve(address(escrow), type(uint256).max);
    }

    function _createBounty(uint256 amount) internal returns (uint256 id) {
        vm.prank(creator);
        id = exec.createBounty(token, amount, "octocat", "hello-world", "42", "Fix the thing");
    }

    function test_CreateBounty_HappyPath() public {
        uint256 id = _createBounty(1000 ether);
        assertEq(id, 0);
        assertEq(token.balanceOf(address(exec)), 1000 ether);
    }

    function test_CreateBounty_ZeroAmount_Reverts() public {
        vm.prank(creator);
        vm.expectRevert(ForumExecutor.ZeroAmount.selector);
        exec.createBounty(token, 0, "a", "b", "c", "d");
    }

    function test_ClaimBounty_HappyPath() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        assertTrue(exec.getStatus(id) == ForumExecutor.Status.Claimed);
        assertEq(exec.getClaimant(id), agent);
    }

    function test_ClaimBounty_ReclaimReverts() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        vm.prank(address(0xC0FFEE));
        vm.expectRevert(
            abi.encodeWithSelector(
                ForumExecutor.InvalidStatus.selector, id, ForumExecutor.Status.Open, ForumExecutor.Status.Claimed
            )
        );
        exec.claimBounty(id, "did:key:other");
    }

    function test_SubmitBounty_HappyPath() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");
        assertEq(exec.getPrId(id), "PR-1");
        assertTrue(exec.getStatus(id) == ForumExecutor.Status.Submitted);
    }

    function test_SubmitBounty_NotClaimant_Reverts() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        vm.prank(address(0xBADBEEF));
        vm.expectRevert(abi.encodeWithSelector(ForumExecutor.NotClaimant.selector, id));
        exec.submitBounty(id, "PR-bad");
    }

    function test_Vote_RequiresStake() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");

        // No one has bonded against -> reviewer1 has zero stake
        vm.prank(reviewer1);
        vm.expectRevert(ForumExecutor.NoStake.selector);
        exec.vote(id, true);
    }

    function test_Vote_DoubleVote_Reverts() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(reviewer1);
        escrow.bondAgainst(id, 100 ether);

        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");

        vm.prank(reviewer1);
        exec.vote(id, true);
        vm.prank(reviewer1);
        vm.expectRevert(ForumExecutor.AlreadyVoted.selector);
        exec.vote(id, true);
    }

    function test_Finalize_NoAgainstStake_DefaultsToApprove() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");

        // Fast-forward past review deadline (default 3 days)
        vm.warp(block.timestamp + 4 days);

        uint256 agentBefore = token.balanceOf(agent);
        exec.finalize(id);
        uint256 agentAfter = token.balanceOf(agent);
        // 5% fee -> agent gets 95% = 950 ether
        assertEq(agentAfter - agentBefore, 950 ether);
        // Treasury gets 5% = 50 ether
        assertEq(token.balanceOf(treasury), 50 ether);
    }

    function test_Finalize_MajorityRejectRoutesRefund() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(reviewer1);
        escrow.bondAgainst(id, 100 ether);
        vm.prank(reviewer2);
        escrow.bondAgainst(id, 100 ether);

        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");

        // Both vote to reject -> 200 reject vs 0 approve, majority reject (> totalAgainst/2)
        vm.prank(reviewer1);
        exec.vote(id, false);
        vm.prank(reviewer2);
        exec.vote(id, false);

        // H-03: pre-deadline short-circuit requires `block.timestamp >= submittedAt + minReviewDelay`.
        // Quorum is satisfied (200 ether AGAINST >= 100e18 default), so finalize past the
        // 1-hour delay rather than waiting the full review deadline.
        vm.warp(block.timestamp + 1 hours + 1);

        uint256 creatorBefore = token.balanceOf(creator);
        exec.finalize(id);
        uint256 creatorAfter = token.balanceOf(creator);
        // Bounty refunded to creator
        assertEq(creatorAfter - creatorBefore, 1000 ether);
        // Agent gets nothing
        assertEq(token.balanceOf(agent), 0);
    }

    function test_Finalize_TieDefaultsToApprove() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(reviewer1);
        escrow.bondAgainst(id, 100 ether);
        vm.prank(reviewer2);
        escrow.bondAgainst(id, 100 ether);

        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");

        // 100 approve vs 100 reject - tie. Default: approve (benefit of doubt to coder).
        vm.prank(reviewer1);
        exec.vote(id, true);
        vm.prank(reviewer2);
        exec.vote(id, false);

        // Need to pass the review deadline for finalize since neither side has 2x majority
        vm.warp(block.timestamp + 4 days);
        exec.finalize(id);
        // Agent paid
        assertEq(token.balanceOf(agent), 950 ether);
    }

    function test_CancelBounty_OnlyCreator() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(address(0xBADBEEF));
        vm.expectRevert(abi.encodeWithSelector(ForumExecutor.NotCreator.selector, id));
        exec.cancelBounty(id);
    }

    function test_CancelBounty_HappyPath_Refunds() public {
        uint256 id = _createBounty(1000 ether);
        uint256 before_ = token.balanceOf(creator);
        vm.prank(creator);
        exec.cancelBounty(id);
        assertEq(token.balanceOf(creator) - before_, 1000 ether);
    }

    function test_DisputeBounty_OnlyAfterDeadline() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        vm.expectRevert(abi.encodeWithSelector(ForumExecutor.DeadlineNotExceeded.selector, id));
        exec.disputeBounty(id);
    }

    function test_DisputeBounty_AfterDeadline_ReturnsToOpen() public {
        uint256 id = _createBounty(1000 ether);
        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        vm.warp(block.timestamp + 8 days);
        exec.disputeBounty(id);
        assertTrue(exec.getStatus(id) == ForumExecutor.Status.Open);
        assertEq(exec.getClaimant(id), address(0));
    }

    function test_SetProtocolFee_HighReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(ForumExecutor.FeeTooHigh.selector, uint16(2000)));
        exec.setProtocolFee(2000);
    }

    // ── H-01 regression ──────────────────────────────────────────────────────
    //
    // Audit finding: `disputeBounty` did NOT clear `hasVoted`, so reviewers
    // from the first round were permanently locked out of subsequent rounds.
    // Fix: per-bounty `voteRound` counter + round-scoped `votedInRound` mapping.

    function test_H01_DisputedBounty_AllowsSameReviewerToVoteAgain() public {
        uint256 id = _createBounty(1000 ether);
        // Round 0: reviewer1 stakes 100 AGAINST and approves the first submission
        vm.prank(reviewer1);
        escrow.bondAgainst(id, 100 ether);

        address agent1 = address(0xA6E47);
        vm.prank(agent1);
        exec.claimBounty(id, "did:key:agent1");
        vm.prank(agent1);
        exec.submitBounty(id, "PR-1");
        vm.prank(reviewer1);
        exec.vote(id, true);

        // Review deadline expires without finalize, dispute returns bounty to Open.
        // BEFORE the fix this also left `hasVoted[id][reviewer1] = true`.
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 4 days);
        exec.disputeBounty(id);
        assertTrue(exec.getStatus(id) == ForumExecutor.Status.Open);
        assertEq(exec.voteRound(id), 1, "voteRound bumped on dispute");

        // Round 1: a new agent claims and resubmits
        address agent2 = address(0xA62);
        vm.prank(agent2);
        exec.claimBounty(id, "did:key:agent2");
        vm.prank(agent2);
        exec.submitBounty(id, "PR-2");

        // reviewer1 must be able to vote AGAIN. Before the H-01 fix this
        // reverted with `AlreadyVoted`.
        vm.prank(reviewer1);
        exec.vote(id, false);
        assertTrue(exec.hasVoted(id, reviewer1), "vote tracked in new round");

        // And the prior round's vote does NOT count toward the new quorum:
        // votesApprove was reset to 0 in disputeBounty; only the new reject counts.
        // Finalize after the review deadline -> creator refunded (rejection).
        vm.warp(t0 + 12 days);
        uint256 creatorBefore = token.balanceOf(creator);
        exec.finalize(id);
        assertEq(token.balanceOf(creator) - creatorBefore, 1000 ether, "rejected -> refund");
        assertEq(token.balanceOf(agent2), 0, "rejected agent got nothing");
    }

    function test_H01_VoteRoundIsolation_OldRoundCannotBeReplayed() public {
        // Bumping voteRound must make round-0 votes invisible to the new round.
        uint256 id = _createBounty(1000 ether);
        vm.prank(reviewer1);
        escrow.bondAgainst(id, 100 ether);

        vm.prank(agent);
        exec.claimBounty(id, "did:key:a");
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");
        vm.prank(reviewer1);
        exec.vote(id, true);

        // hasVoted view returns true while still in round 0
        assertTrue(exec.hasVoted(id, reviewer1));

        vm.warp(block.timestamp + 4 days);
        exec.disputeBounty(id);

        // After dispute the view should report false for the new (empty) round
        assertFalse(exec.hasVoted(id, reviewer1), "fresh round has no votes yet");
    }

    // ── H-02 regression ──────────────────────────────────────────────────────
    //
    // Audit finding: `createBounty` accepted any ERC-20, so fee-on-transfer /
    // rebasing / blacklist tokens could break BondingEscrow accounting.
    // Fix: `chamberRegistry.isRegisteredIdea(token)` must return true.

    function test_H02_CreateBounty_RegisteredIdea_Succeeds() public {
        // The setUp registered `token` as an idea - happy path still works.
        uint256 id = _createBounty(1000 ether);
        assertEq(id, 0);
        assertEq(token.balanceOf(address(exec)), 1000 ether);
    }

    function test_H02_CreateBounty_UnregisteredToken_Reverts() public {
        // A vanilla MockERC20 that was NEVER registered as a Quorum idea.
        MockERC20 stray = new MockERC20("Stray", "STRAY");
        stray.mint(creator, 1000 ether);
        vm.prank(creator);
        stray.approve(address(exec), type(uint256).max);

        vm.prank(creator);
        vm.expectRevert(ForumExecutor.NotIdeaToken.selector);
        exec.createBounty(stray, 1000 ether, "o", "r", "i", "t");
    }

    function test_H02_CreateBounty_FeeOnTransferToken_Reverts() public {
        // Even a fee-on-transfer token would break BondingEscrow accounting
        // if accepted; the registry check makes the failure mode loud + cheap.
        FeeOnTransferMockERC20 fee = new FeeOnTransferMockERC20("FeeOnT", "FOT", 100); // 1% fee
        fee.mint(creator, 1000 ether);
        vm.prank(creator);
        fee.approve(address(exec), type(uint256).max);

        vm.prank(creator);
        vm.expectRevert(ForumExecutor.NotIdeaToken.selector);
        exec.createBounty(fee, 1000 ether, "o", "r", "i", "t");
    }

    // ── H-03 regression ──────────────────────────────────────────────────────
    //
    // Audit finding: 1 wei AGAINST + vote(approve) + finalize bypassed the
    // 3-day review window. Fix: minQuorumStake + minReviewDelay must both be
    // satisfied for pre-deadline short-circuit.

    function test_H03_FlashBondAttack_OneWeiAgainst_RevertsBeforeDeadline() public {
        uint256 id = _createBounty(1000 ether);
        // Attacker bonds the smallest possible AGAINST stake then tries to
        // self-approve the submission via the quorum short-circuit.
        address attacker = address(0xA77AC);
        token.mint(attacker, 1);
        vm.prank(attacker);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(attacker);
        escrow.bondAgainst(id, 1);

        vm.prank(agent);
        exec.claimBounty(id, "did:key:agent");
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");
        vm.prank(attacker);
        exec.vote(id, true);

        // Skip past minReviewDelay so it can ONLY be the quorum check failing.
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(ForumExecutor.VotesNotConclusive.selector);
        exec.finalize(id);

        // Status still pending; bounty NOT paid out.
        assertTrue(exec.getStatus(id) == ForumExecutor.Status.Submitted);
        assertEq(token.balanceOf(agent), 0);
    }

    function test_H03_MinReviewDelay_RevertsImmediateFinalize() public {
        // Even with a fat AGAINST quorum, an INSTANT finalize (< minReviewDelay)
        // is blocked. This protects against block-included sandwich attacks.
        uint256 id = _createBounty(1000 ether);
        vm.prank(reviewer1);
        escrow.bondAgainst(id, 100 ether);

        vm.prank(agent);
        exec.claimBounty(id, "did:key:a");
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");
        vm.prank(reviewer1);
        exec.vote(id, true);

        // No warp at all - block.timestamp == submittedAt.
        vm.expectRevert(ForumExecutor.VotesNotConclusive.selector);
        exec.finalize(id);
    }

    function test_H03_HonestQuorumPlusDelay_FinalizeSucceeds() public {
        // With >= minQuorumStake AGAINST and >= minReviewDelay elapsed, the
        // pre-deadline short-circuit works as designed.
        uint256 id = _createBounty(1000 ether);
        vm.prank(reviewer1);
        escrow.bondAgainst(id, 100 ether);

        vm.prank(agent);
        exec.claimBounty(id, "did:key:a");
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");
        vm.prank(reviewer1);
        exec.vote(id, true);

        // Wait past minReviewDelay (1 hour default) but BEFORE the 3-day review deadline.
        vm.warp(block.timestamp + 1 hours + 1);
        exec.finalize(id);

        assertEq(token.balanceOf(agent), 950 ether, "agent paid 95% via short-circuit");
    }

    function test_H03_SetMinQuorumStake_OnlyOwner() public {
        vm.prank(address(0xBADBEEF));
        vm.expectRevert();
        exec.setMinQuorumStake(50e18);

        vm.prank(owner);
        exec.setMinQuorumStake(50e18);
        assertEq(exec.minQuorumStake(), 50e18);
    }

    function test_H03_SetMinReviewDelay_OnlyOwner() public {
        vm.prank(address(0xBADBEEF));
        vm.expectRevert();
        exec.setMinReviewDelay(30 minutes);

        vm.prank(owner);
        exec.setMinReviewDelay(30 minutes);
        assertEq(exec.minReviewDelay(), 30 minutes);
    }

    // ── Constructor input validation ─────────────────────────────────────────

    function test_Constructor_ZeroChamberRegistry_Reverts() public {
        vm.expectRevert(ForumExecutor.ZeroAddress.selector);
        new ForumExecutor(owner, treasury, address(escrow), address(0));
    }

    function test_SetChamberRegistry_ZeroAddress_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(ForumExecutor.ZeroAddress.selector);
        exec.setChamberRegistry(address(0));
    }
}

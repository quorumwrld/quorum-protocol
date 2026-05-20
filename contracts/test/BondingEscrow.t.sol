// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BondingEscrow} from "../src/BondingEscrow.sol";
import {IBondingEscrow} from "../src/interfaces/IBondingEscrow.sol";
import {MockERC20} from "./MockERC20.sol";

contract BondingEscrowTest is Test {
    BondingEscrow escrow;
    MockERC20 token;
    address owner = address(0xA1);
    address treasury = address(0xA2);
    address executor = address(0xE1);

    address alice = address(0xA);
    address bob = address(0xB);
    address charlie = address(0xC);

    uint256 constant BOUNTY = 1;

    function setUp() public {
        vm.prank(owner);
        escrow = new BondingEscrow(owner, treasury);
        vm.prank(owner);
        escrow.setForumExecutor(executor);

        token = new MockERC20("Idea", "IDEA");

        // Fund users
        token.mint(alice, 1000 ether);
        token.mint(bob, 1000 ether);
        token.mint(charlie, 1000 ether);

        // Approvals
        vm.prank(alice);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(bob);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(charlie);
        token.approve(address(escrow), type(uint256).max);

        // Register bounty
        vm.prank(executor);
        escrow.registerBounty(BOUNTY, address(token));
    }

    function test_RegisterBounty_OnlyExecutor() public {
        vm.expectRevert(BondingEscrow.NotExecutor.selector);
        escrow.registerBounty(2, address(token));
    }

    function test_BondFor_HappyPath() public {
        vm.prank(alice);
        escrow.bondFor(BOUNTY, 100 ether);
        IBondingEscrow.Position memory p = escrow.getPosition(BOUNTY, alice);
        assertEq(uint256(p.forStake), 100 ether);
        assertEq(uint256(p.againstStake), 0);
    }

    function test_BondAgainst_HappyPath() public {
        vm.prank(bob);
        escrow.bondAgainst(BOUNTY, 50 ether);
        IBondingEscrow.Position memory p = escrow.getPosition(BOUNTY, bob);
        assertEq(uint256(p.forStake), 0);
        assertEq(uint256(p.againstStake), 50 ether);
    }

    function test_Bond_RejectsAfterSettlement() public {
        vm.prank(executor);
        escrow.settle(BOUNTY, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(BondingEscrow.AlreadySettled.selector, BOUNTY));
        escrow.bondFor(BOUNTY, 1 ether);
    }

    function test_Settle_OnlyExecutor() public {
        vm.expectRevert(BondingEscrow.NotExecutor.selector);
        escrow.settle(BOUNTY, true);
    }

    function test_ForWon_ClaimDistributesLoserPool() public {
        // Alice goes FOR 100, Bob goes AGAINST 50, Charlie goes FOR 100
        vm.prank(alice);
        escrow.bondFor(BOUNTY, 100 ether);
        vm.prank(bob);
        escrow.bondAgainst(BOUNTY, 50 ether);
        vm.prank(charlie);
        escrow.bondFor(BOUNTY, 100 ether);

        // FOR wins
        vm.prank(executor);
        escrow.settle(BOUNTY, true);

        // protocolSlashBps = 10% by default. Loser pool = 50.
        // Distributable to FOR = 50 * 90% = 45. Alice and Charlie split equally (50/50 by stake).
        uint256 expectedShareEach = (50 ether * 9000) / (10_000 * 2); // 22.5

        // Alice claims
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        escrow.claim(BOUNTY);
        uint256 aliceAfter = token.balanceOf(alice);
        assertEq(aliceAfter - aliceBefore, 100 ether + expectedShareEach);

        // Charlie claims
        uint256 charlieBefore = token.balanceOf(charlie);
        vm.prank(charlie);
        escrow.claim(BOUNTY);
        uint256 charlieAfter = token.balanceOf(charlie);
        assertEq(charlieAfter - charlieBefore, 100 ether + expectedShareEach);
    }

    function test_AgainstWon_LoserGetsNothing() public {
        vm.prank(alice);
        escrow.bondFor(BOUNTY, 100 ether);
        vm.prank(bob);
        escrow.bondAgainst(BOUNTY, 50 ether);

        vm.prank(executor);
        escrow.settle(BOUNTY, false);

        // Bob (winner) claims
        vm.prank(bob);
        escrow.claim(BOUNTY);

        // Alice (loser) claims — should get 0
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        escrow.claim(BOUNTY);
        uint256 aliceAfter = token.balanceOf(alice);
        assertEq(aliceAfter, aliceBefore, "loser gets nothing");
    }

    function test_DoubleClaim_Reverts() public {
        vm.prank(alice);
        escrow.bondFor(BOUNTY, 100 ether);
        vm.prank(executor);
        escrow.settle(BOUNTY, true);
        vm.prank(alice);
        escrow.claim(BOUNTY);
        vm.prank(alice);
        vm.expectRevert(BondingEscrow.AlreadyClaimed.selector);
        escrow.claim(BOUNTY);
    }

    function test_FlushProtocolCut_Idempotent() public {
        vm.prank(alice);
        escrow.bondFor(BOUNTY, 100 ether);
        vm.prank(bob);
        escrow.bondAgainst(BOUNTY, 100 ether);
        vm.prank(executor);
        escrow.settle(BOUNTY, true);

        uint256 treasuryBefore = token.balanceOf(treasury);
        escrow.flushProtocolCut(BOUNTY);
        uint256 treasuryAfter1 = token.balanceOf(treasury);
        assertEq(treasuryAfter1 - treasuryBefore, 10 ether, "10% of 100 = 10");

        // Second call: idempotent, no-op
        escrow.flushProtocolCut(BOUNTY);
        uint256 treasuryAfter2 = token.balanceOf(treasury);
        assertEq(treasuryAfter2, treasuryAfter1, "second flush is a no-op");
    }

    function testFuzz_ClaimConservation(uint128 forStake, uint128 againstStake) public {
        // Bound to 1e30 — well above any realistic stake (Clanker max supply = 1e27)
        // and small enough to keep the dust assertion meaningful.
        forStake = uint128(bound(forStake, 1, 1e30));
        againstStake = uint128(bound(againstStake, 1, 1e30));
        token.mint(alice, forStake);
        token.mint(bob, againstStake);

        vm.prank(alice);
        escrow.bondFor(BOUNTY, forStake);
        vm.prank(bob);
        escrow.bondAgainst(BOUNTY, againstStake);
        vm.prank(executor);
        escrow.settle(BOUNTY, true);

        escrow.flushProtocolCut(BOUNTY);
        vm.prank(alice);
        escrow.claim(BOUNTY);
        vm.prank(bob); // loser, claims 0
        escrow.claim(BOUNTY);

        // Integer division of `(loserPool * forStake * 9000) / (totalFor * 10000)` and
        // `(loserPool * 1000) / 10000` each rounds down independently, so up to 1 wei
        // per quotient can be left behind. With one winner + one loser + one protocol
        // cut, the max residual is bounded by 2 wei (one per rounding).
        assertLe(token.balanceOf(address(escrow)), 2, "at most 2 wei dust from integer division");
    }
}

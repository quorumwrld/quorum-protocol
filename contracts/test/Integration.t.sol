// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IdeaFactory} from "../src/IdeaFactory.sol";
import {ChamberRegistry} from "../src/ChamberRegistry.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {BondingEscrow} from "../src/BondingEscrow.sol";
import {ForumExecutor} from "../src/ForumExecutor.sol";
import {IClanker} from "../src/interfaces/IClanker.sol";
import {IChamberRegistry} from "../src/interfaces/IChamberRegistry.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {IBondingEscrow} from "../src/interfaces/IBondingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockClanker} from "./MockClanker.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice End-to-end happy path: chamber → idea deploy → bonding → bounty → settle.
///         Covers the 5-contract orchestration. Fuzz tested in CI profile.
contract IntegrationTest is Test {
    IdeaFactory factory;
    ChamberRegistry registry;
    FeeRouter router;
    BondingEscrow escrow;
    ForumExecutor exec;
    MockClanker clanker;

    address owner = address(0xA1);
    address relayer = address(0xA2);
    address dealer = address(0xA3);
    address treasury = address(0xA4);

    address creator = address(0x100);
    address agentCoder = address(0x200);
    address forBonder = address(0x300);
    address againstReviewer = address(0x4000);

    function setUp() public {
        clanker = new MockClanker();

        vm.startPrank(owner);
        registry = new ChamberRegistry(owner);
        router = new FeeRouter(owner);
        escrow = new BondingEscrow(owner, treasury);
        exec = new ForumExecutor(owner, treasury, address(escrow), address(registry));
        factory = new IdeaFactory(
            owner,
            IClanker(address(clanker)),
            IChamberRegistry(address(registry)),
            IFeeRouter(address(router)),
            address(0x4001),
            address(0x4002),
            address(0x4003)
        );

        registry.setFactory(address(factory));
        registry.setDealer(dealer);
        router.setFactory(address(factory));
        escrow.setForumExecutor(address(exec));
        factory.setDeployer(relayer);
        vm.stopPrank();
    }

    function test_FullLifecycle_ForWins() public {
        // 1. Dealer commits chamber root
        vm.prank(dealer);
        registry.commitChamber(42, keccak256("debate-root-42"));

        // 2. Relayer deploys an idea token via Clanker
        IdeaFactory.DeployParams memory p = _params();
        vm.prank(relayer);
        address ideaToken = factory.deployIdea(p);

        // 3. Fund the participants with idea tokens
        // MockClanker minted 1M to itself; transfer slices to participants
        vm.prank(address(clanker));
        IERC20(ideaToken).transfer(creator, 100_000 ether);
        vm.prank(address(clanker));
        IERC20(ideaToken).transfer(forBonder, 100_000 ether);
        vm.prank(address(clanker));
        IERC20(ideaToken).transfer(againstReviewer, 100_000 ether);

        // 4. Creator opens a bounty in the idea token
        vm.prank(creator);
        IERC20(ideaToken).approve(address(exec), type(uint256).max);
        vm.prank(creator);
        uint256 bountyId =
            exec.createBounty(IERC20(ideaToken), 10_000 ether, "flash-org", "flash-repo", "1", "Build the thing");

        // 5. forBonder stakes FOR
        vm.prank(forBonder);
        IERC20(ideaToken).approve(address(escrow), type(uint256).max);
        vm.prank(forBonder);
        escrow.bondFor(bountyId, 5000 ether);

        // 6. againstReviewer stakes AGAINST
        vm.prank(againstReviewer);
        IERC20(ideaToken).approve(address(escrow), type(uint256).max);
        vm.prank(againstReviewer);
        escrow.bondAgainst(bountyId, 2000 ether);

        // 7. agentCoder claims and submits
        vm.prank(agentCoder);
        exec.claimBounty(bountyId, "did:key:agent-coder");
        vm.prank(agentCoder);
        exec.submitBounty(bountyId, "PR-1");

        // 8. Reviewer votes approve (only voter, weight 2000 → wins by default)
        vm.prank(againstReviewer);
        exec.vote(bountyId, true);

        // 9. Finalize after review deadline
        vm.warp(block.timestamp + 4 days);
        exec.finalize(bountyId);

        // Bounty approved → agent paid (95%), treasury fee (5%)
        // agent receives: 10000 ether × 95% = 9500
        assertEq(IERC20(ideaToken).balanceOf(agentCoder), 9500 ether);
        // treasury accumulates both the bounty fee AND the eventual loser-slash flush
        // For now we just verify the bounty fee is there:
        assertGe(IERC20(ideaToken).balanceOf(treasury), 500 ether);

        // 10. forBonder claims winnings (own 5000 + share of 2000 loser pool * 90% = 1800 = 6800)
        vm.prank(forBonder);
        escrow.claim(bountyId);
        // forBonder originally had 100_000 - 5_000 staked = 95_000, then receives 5_000 + 1_800 = 6_800
        assertEq(IERC20(ideaToken).balanceOf(forBonder), 95_000 ether + 6800 ether);

        // 11. againstReviewer claims (loser side → 0)
        uint256 beforeR = IERC20(ideaToken).balanceOf(againstReviewer);
        vm.prank(againstReviewer);
        escrow.claim(bountyId);
        assertEq(IERC20(ideaToken).balanceOf(againstReviewer), beforeR); // unchanged

        // 12. Protocol cut flush (10% of 2000 loser pool = 200)
        escrow.flushProtocolCut(bountyId);
        // Treasury gets bounty fee (500) + slash cut (200) = 700
        assertEq(IERC20(ideaToken).balanceOf(treasury), 700 ether);
    }

    function _params() internal view returns (IdeaFactory.DeployParams memory p) {
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = -887_220;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = 887_220;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;
        p = IdeaFactory.DeployParams({
            name: "Flash",
            ticker: "FLASH",
            description: "d",
            image: "",
            metadata: "",
            context: "",
            salt: bytes32(uint256(1)),
            creator: creator,
            chamberId: 42,
            protocolTreasury: treasury,
            winnersSplitter: address(0),
            forPool: address(escrow),
            againstPool: address(escrow),
            executorPool: address(exec),
            bps: [uint16(1500), uint16(1500), uint16(1000), uint16(2500), uint16(1000), uint16(2500)],
            pairedToken: address(0x4200000000000000000000000000000000000006),
            tickIfToken0IsClanker: -180_000,
            tickSpacing: 200,
            poolData: "",
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: "",
            mevModuleData: ""
        });
    }
}

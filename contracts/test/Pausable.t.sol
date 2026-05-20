// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IdeaFactory} from "../src/IdeaFactory.sol";
import {ForumExecutor} from "../src/ForumExecutor.sol";
import {BondingEscrow} from "../src/BondingEscrow.sol";
import {ChamberRegistry} from "../src/ChamberRegistry.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {IClanker} from "../src/interfaces/IClanker.sol";
import {IChamberRegistry} from "../src/interfaces/IChamberRegistry.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockClanker} from "./MockClanker.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Verifies that the mainnet emergency-pause primitive on IdeaFactory,
///         ForumExecutor, and BondingEscrow halts ONLY the gated entry points
///         (`deployIdea`, `createBounty`, `bondFor`/`bondAgainst`) and never the
///         settlement / claim paths. Trapping funds via pause would itself be
///         a critical bug — these tests assert that doesn't happen.
contract PausableTest is Test {
    IdeaFactory factory;
    ChamberRegistry registry;
    FeeRouter router;
    BondingEscrow escrow;
    ForumExecutor exec;
    MockClanker clanker;
    MockERC20 token;

    address owner = address(0xA1);
    address relayer = address(0xBE1);
    address treasury = address(0xA2);
    address creator = address(0xC1);
    address alice = address(0xA);
    address bob = address(0xB);
    address agent = address(0xA6E47);

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
        router.setFactory(address(factory));
        escrow.setForumExecutor(address(exec));
        factory.setDeployer(relayer);
        vm.stopPrank();

        token = new MockERC20("Idea", "IDEA");
        // H-02: the test token must look like a real Quorum idea token to be
        // accepted by `ForumExecutor.createBounty`. Register it via the factory
        // role (no real Clanker deploy needed for pause tests).
        vm.prank(address(factory));
        registry.registerIdea(address(token), "Idea", "IDEA", "test", creator, 1);
        token.mint(creator, 10_000 ether);
        token.mint(alice, 1000 ether);
        token.mint(bob, 1000 ether);
        vm.prank(creator);
        token.approve(address(exec), type(uint256).max);
        vm.prank(alice);
        token.approve(address(escrow), type(uint256).max);
        vm.prank(bob);
        token.approve(address(escrow), type(uint256).max);
    }

    function _defaultParams() internal view returns (IdeaFactory.DeployParams memory p) {
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
            salt: bytes32(uint256(0xCAFE)),
            creator: creator,
            chamberId: 1,
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

    // ── IdeaFactory ──────────────────────────────────────────────────────────

    function test_IdeaFactory_PauseUnpause_OnlyOwner() public {
        vm.prank(address(0xBADBEEF));
        vm.expectRevert();
        factory.pause();

        vm.prank(owner);
        factory.pause();
        assertTrue(factory.paused());

        vm.prank(address(0xBADBEEF));
        vm.expectRevert();
        factory.unpause();

        vm.prank(owner);
        factory.unpause();
        assertFalse(factory.paused());
    }

    function test_IdeaFactory_DeployIdea_RevertsWhenPaused() public {
        vm.prank(owner);
        factory.pause();

        IdeaFactory.DeployParams memory p = _defaultParams();
        vm.prank(relayer);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        factory.deployIdea(p);
    }

    function test_IdeaFactory_DeployIdea_WorksAfterUnpause() public {
        vm.prank(owner);
        factory.pause();
        vm.prank(owner);
        factory.unpause();

        IdeaFactory.DeployParams memory p = _defaultParams();
        vm.prank(relayer);
        address ideaToken = factory.deployIdea(p);
        assertTrue(ideaToken != address(0));
    }

    // ── ForumExecutor ────────────────────────────────────────────────────────

    function test_ForumExecutor_PauseUnpause_OnlyOwner() public {
        vm.prank(address(0xBADBEEF));
        vm.expectRevert();
        exec.pause();

        vm.prank(owner);
        exec.pause();
        assertTrue(exec.paused());

        vm.prank(owner);
        exec.unpause();
        assertFalse(exec.paused());
    }

    function test_ForumExecutor_CreateBounty_RevertsWhenPaused() public {
        vm.prank(owner);
        exec.pause();

        vm.prank(creator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        exec.createBounty(token, 1000 ether, "octo", "hello", "1", "title");
    }

    /// Critical: claim/submit/finalize/cancel/dispute MUST keep working when paused.
    /// Otherwise funds in escrow are trapped during an incident.
    function test_ForumExecutor_LifecycleNotPaused_FundsAlwaysReleasable() public {
        // Create bounty BEFORE pause
        vm.prank(creator);
        uint256 id = exec.createBounty(token, 1000 ether, "octo", "hello", "1", "title");

        // Pause AFTER creation
        vm.prank(owner);
        exec.pause();

        // Claim still works
        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        // Submit still works
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");
        // Finalize still works (no AGAINST votes → defaults to approve after deadline)
        vm.warp(block.timestamp + 4 days);
        exec.finalize(id);

        // Agent was paid → funds NOT trapped
        assertEq(token.balanceOf(agent), 950 ether); // 5% fee
    }

    function test_ForumExecutor_CancelWorksWhenPaused() public {
        vm.prank(creator);
        uint256 id = exec.createBounty(token, 1000 ether, "octo", "hello", "1", "title");
        uint256 beforeBal = token.balanceOf(creator);

        vm.prank(owner);
        exec.pause();

        vm.prank(creator);
        exec.cancelBounty(id);
        assertEq(token.balanceOf(creator) - beforeBal, 1000 ether, "refund must work when paused");
    }

    // ── BondingEscrow ────────────────────────────────────────────────────────

    function test_BondingEscrow_PauseUnpause_OnlyOwner() public {
        vm.prank(address(0xBADBEEF));
        vm.expectRevert();
        escrow.pause();

        vm.prank(owner);
        escrow.pause();
        assertTrue(escrow.paused());

        vm.prank(owner);
        escrow.unpause();
        assertFalse(escrow.paused());
    }

    function test_BondingEscrow_BondFor_RevertsWhenPaused() public {
        // Register the bounty first
        vm.prank(creator);
        uint256 id = exec.createBounty(token, 1000 ether, "o", "r", "i", "t");

        vm.prank(owner);
        escrow.pause();

        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.bondFor(id, 100 ether);
    }

    function test_BondingEscrow_BondAgainst_RevertsWhenPaused() public {
        vm.prank(creator);
        uint256 id = exec.createBounty(token, 1000 ether, "o", "r", "i", "t");

        vm.prank(owner);
        escrow.pause();

        vm.prank(bob);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.bondAgainst(id, 50 ether);
    }

    /// Critical: settle/claim/flushProtocolCut MUST keep working when paused.
    function test_BondingEscrow_SettlementNotPaused_FundsAlwaysReleasable() public {
        // Open + bond BEFORE pause
        vm.prank(creator);
        uint256 id = exec.createBounty(token, 1000 ether, "o", "r", "i", "t");
        vm.prank(alice);
        escrow.bondFor(id, 100 ether);
        vm.prank(bob);
        escrow.bondAgainst(id, 50 ether);

        // Pause everything
        vm.prank(owner);
        escrow.pause();
        vm.prank(owner);
        exec.pause();

        // Drive bounty to settlement (claim → submit → finalize, all keep working under pause)
        vm.prank(agent);
        exec.claimBounty(id, "did:key:abc");
        vm.prank(agent);
        exec.submitBounty(id, "PR-1");
        vm.warp(block.timestamp + 4 days);
        exec.finalize(id);

        // Claim winnings + protocol flush MUST still work even when paused
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(alice);
        escrow.claim(id);
        assertGt(token.balanceOf(alice), aliceBefore, "winner claim works when paused");

        escrow.flushProtocolCut(id); // anyone, even when paused
        assertGt(token.balanceOf(treasury), 0, "protocol cut flushes when paused");
    }
}

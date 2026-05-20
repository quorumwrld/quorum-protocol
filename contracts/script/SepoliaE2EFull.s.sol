// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ChamberRegistry} from "../src/ChamberRegistry.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {BondingEscrow} from "../src/BondingEscrow.sol";
import {ForumExecutor} from "../src/ForumExecutor.sol";
import {IdeaFactory} from "../src/IdeaFactory.sol";
import {IChamberRegistry} from "../src/interfaces/IChamberRegistry.sol";
import {IBondingEscrow} from "../src/interfaces/IBondingEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockClankerToken} from "../src/mocks/MockClanker.sol";

/// @notice Full bond + bounty + settle lifecycle against live Base Sepolia (chain 84532).
///         Self-contained: deploys a fresh idea, mints test tokens via MockClankerToken.mint,
///         bonds FOR and AGAINST from the deployer wallet, runs the bounty through
///         createBounty → claim → submit → vote → finalize, then settles the bonding
///         escrow + flushes the protocol cut.
///
///         Because `vm.warp` cannot fast-forward live chain state, this script leans on
///         the early-majority short-circuit in `ForumExecutor.finalize()`: when the
///         AGAINST-stake majority votes one direction (`votesApprove * 2 > totalAgainst`),
///         finalize can run immediately — no review-deadline wait required.
///
///         All on-chain calls are real Sepolia transactions; no mocks beyond the
///         already-deployed MockClanker (the testnet stand-in for Clanker v4).
contract SepoliaE2EFull is Script {
    // Live Sepolia contracts (chain 84532) — v2 (2026-05-18 evening, post H-01/H-02/H-03 fixes)
    address constant MOCK_CLANKER = 0x19A32b87754c2f776f5127Da414730CDc527A32E;
    address constant CHAMBER_REGISTRY = 0x9bE1D29fe67ae22CB5644588B8aF460299f36bcA;
    address constant FEE_ROUTER = 0x22Eb62cB5AC5f5b29d8B2A876c0C8e63796f8FcC;
    address constant BONDING_ESCROW = 0x642CFcB9BCe23aC36Dbe03bBDF3dC0cF9cD8855B;
    address constant FORUM_EXECUTOR = 0x035227674a473963ec024c260e33Cc78b186C24D;
    address constant IDEA_FACTORY = 0xB605d5156e82f718097356147146cb42935bd1Ea;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        ChamberRegistry registry = ChamberRegistry(CHAMBER_REGISTRY);
        FeeRouter router = FeeRouter(FEE_ROUTER);
        BondingEscrow escrow = BondingEscrow(BONDING_ESCROW);
        ForumExecutor executor = ForumExecutor(FORUM_EXECUTOR);
        IdeaFactory factory = IdeaFactory(IDEA_FACTORY);

        // Unique chamberId per run so re-runs don't collide on registry.
        uint256 chamberId =
            uint256(keccak256(abi.encode("SepoliaE2EFull", block.timestamp, blockhash(block.number - 1), deployer)));

        console2.log("=== Sepolia E2E Full ===");
        console2.log("deployer:", deployer);
        console2.log("chamberId:", chamberId);

        vm.startBroadcast(deployerKey);

        // ── Step 1: commit chamber + deploy idea ────────────────────────────
        console2.log("[1] commitChamber");
        registry.commitChamber(chamberId, keccak256(abi.encode("debate-root", chamberId)));

        console2.log("[2] deployIdea");
        address ideaToken = factory.deployIdea(_params(chamberId, deployer));
        console2.log("    ideaToken:", ideaToken);

        // ── Step 3: mint test tokens to deployer (MockClankerToken.mint is public) ──
        console2.log("[3] mint 100k idea tokens to deployer");
        MockClankerToken(ideaToken).mint(deployer, 100_000 ether);

        uint256 selfBal = IERC20(ideaToken).balanceOf(deployer);
        console2.log("    deployer balance:", selfBal);

        // ── Step 4: approve escrow + executor ───────────────────────────────
        console2.log("[4] approve BondingEscrow + ForumExecutor");
        IERC20(ideaToken).approve(BONDING_ESCROW, type(uint256).max);
        IERC20(ideaToken).approve(FORUM_EXECUTOR, type(uint256).max);

        // ── Step 5: create bounty (10_000 ether) ────────────────────────────
        console2.log("[5] createBounty (10k tokens)");
        uint256 bountyId = executor.createBounty(
            IERC20(ideaToken), 10_000 ether, "quorumwrld", "quorum", "issue-e2e-1", "Sepolia E2E full lifecycle"
        );
        console2.log("    bountyId:", bountyId);

        // ── Step 6: bond FOR 5_000 + AGAINST 2_000 (same wallet) ────────────
        console2.log("[6a] bondFor 5_000");
        escrow.bondFor(bountyId, 5000 ether);
        console2.log("[6b] bondAgainst 2_000");
        escrow.bondAgainst(bountyId, 2000 ether);

        // ── Step 7: claim as agent identity ─────────────────────────────────
        console2.log("[7] claimBounty did:key:agent-test");
        executor.claimBounty(bountyId, "did:key:agent-test");

        // ── Step 8: submit PR ───────────────────────────────────────────────
        console2.log("[8] submitBounty PR-1");
        executor.submitBounty(bountyId, "PR-1");

        // ── Step 9: vote approve (deployer has 2_000 AGAINST stake → weight 2_000) ──
        // votesApprove * 2 = 4_000 > totalAgainst (2_000) → majority approve short-circuit
        // finalize can be called immediately.
        console2.log("[9] vote(approve=true)");
        executor.vote(bountyId, true);

        // ── Step 10: snapshot pre-finalize balances ─────────────────────────
        uint256 deployerBalBefore = IERC20(ideaToken).balanceOf(deployer);
        uint256 treasuryBalBefore = IERC20(ideaToken).balanceOf(escrow.protocolTreasury());
        console2.log("[10] pre-finalize deployer bal:", deployerBalBefore);
        console2.log("     pre-finalize treasury bal:", treasuryBalBefore);

        // ── Step 11: finalize (early majority short-circuit) ────────────────
        console2.log("[11] finalize");
        executor.finalize(bountyId);

        ForumExecutor.Status statusAfterFinalize = executor.getStatus(bountyId);
        console2.log("    status after finalize (3=Approved):", uint256(statusAfterFinalize));
        require(statusAfterFinalize == ForumExecutor.Status.Approved, "expected Approved");

        // ── Step 12: claim winnings (FOR side won — deployer's FOR stake claims) ──
        console2.log("[12] claim winnings (FOR side won)");
        escrow.claim(bountyId);

        // ── Step 13: flush protocol cut on the AGAINST (losing) pool ─────────
        console2.log("[13] flushProtocolCut");
        escrow.flushProtocolCut(bountyId);

        vm.stopBroadcast();

        // ── Final state read-back ───────────────────────────────────────────
        console2.log("=== Final state ===");
        uint256 deployerBalAfter = IERC20(ideaToken).balanceOf(deployer);
        uint256 treasuryBalAfter = IERC20(ideaToken).balanceOf(escrow.protocolTreasury());
        IBondingEscrow.BountyState memory bs = escrow.getBounty(bountyId);
        IBondingEscrow.Position memory pos = escrow.getPosition(bountyId, deployer);

        console2.log("bounty status (3=Approved):", uint256(executor.getStatus(bountyId)));
        console2.log("settlement (1=ForWon):", uint256(bs.settlement));
        console2.log("totalFor:", uint256(bs.totalFor));
        console2.log("totalAgainst:", uint256(bs.totalAgainst));
        console2.log("position.forStake:", uint256(pos.forStake));
        console2.log("position.againstStake:", uint256(pos.againstStake));
        console2.log("position.claimed:", pos.claimed);
        console2.log("protocolFlushed:", escrow.isProtocolFlushed(bountyId));
        console2.log("deployer balance final:", deployerBalAfter);
        console2.log("treasury balance final:", treasuryBalAfter);
        console2.log("treasury delta:", treasuryBalAfter - treasuryBalBefore);
        console2.log("deployer delta:", deployerBalAfter - deployerBalBefore);
        // Treasury delta = bounty fee (10_000 * 5% = 500) + slash (2_000 * 10% = 200) = 700
        // Deployer delta = bounty payout (10_000 - 500 = 9_500) + FOR claim
        //   FOR claim = forStake (5_000) + (loserPool * forStake / totalFor) * (1 - slashBps)
        //             = 5_000 + (2_000 * 5_000 / 5_000) * 0.9 = 5_000 + 1_800 = 6_800
        // Total deployer delta = 9_500 + 6_800 = 16_300 ether
        // Treasury delta = 500 + 200 = 700 ether
        console2.log("expected treasury delta: 700e18");
        console2.log("expected deployer delta: 16300e18");
    }

    function _params(uint256 chamberId, address creator) internal view returns (IdeaFactory.DeployParams memory p) {
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = -887_200;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = 887_200;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        string memory ticker = string(abi.encodePacked("E", _toShortHex(chamberId)));

        p = IdeaFactory.DeployParams({
            name: "E2E Full",
            ticker: ticker,
            description: "Sepolia full E2E (bond + bounty + settle)",
            image: "",
            metadata: "",
            context: "",
            salt: bytes32(chamberId),
            creator: creator,
            chamberId: chamberId,
            protocolTreasury: creator,
            winnersSplitter: address(0),
            forPool: BONDING_ESCROW,
            againstPool: BONDING_ESCROW,
            executorPool: FORUM_EXECUTOR,
            bps: [uint16(1500), uint16(1500), uint16(1000), uint16(2500), uint16(1000), uint16(2500)],
            pairedToken: 0x4200000000000000000000000000000000000006,
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

    function _toShortHex(uint256 v) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789ABCDEF";
        bytes memory b = new bytes(5);
        for (uint256 i; i < 5; ++i) {
            b[4 - i] = hexChars[(v >> (i * 4)) & 0xf];
        }
        return string(b);
    }
}

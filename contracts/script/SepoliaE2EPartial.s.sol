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

/// @notice v2 partial smoke (chain 84532): exercises commit → deploy idea →
///         mint → approve → createBounty → bondFor → bondAgainst → claim →
///         submit → vote, then stops short of `finalize`.
///
///         The H-03 fix (`minReviewDelay = 1 hour`) blocks the same-block
///         early-majority short-circuit that v1 relied on. Finalize is run
///         out-of-band ~1 h after `submitBounty` via `SepoliaE2EFinalize.s.sol`.
contract SepoliaE2EPartial is Script {
    // v2 Sepolia (2026-05-18 evening, post H-01/H-02/H-03)
    address constant CHAMBER_REGISTRY = 0x9bE1D29fe67ae22CB5644588B8aF460299f36bcA;
    address constant FEE_ROUTER = 0x22Eb62cB5AC5f5b29d8B2A876c0C8e63796f8FcC;
    address constant BONDING_ESCROW = 0x642CFcB9BCe23aC36Dbe03bBDF3dC0cF9cD8855B;
    address constant FORUM_EXECUTOR = 0x035227674a473963ec024c260e33Cc78b186C24D;
    address constant IDEA_FACTORY = 0xB605d5156e82f718097356147146cb42935bd1Ea;

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        ChamberRegistry registry = ChamberRegistry(CHAMBER_REGISTRY);
        BondingEscrow escrow = BondingEscrow(BONDING_ESCROW);
        ForumExecutor executor = ForumExecutor(FORUM_EXECUTOR);
        IdeaFactory factory = IdeaFactory(IDEA_FACTORY);

        uint256 chamberId =
            uint256(keccak256(abi.encode("SepoliaE2EPartialV2", block.timestamp, blockhash(block.number - 1), deployer)));

        console2.log("=== Sepolia v2 partial smoke (no finalize) ===");
        console2.log("deployer:", deployer);
        console2.log("chamberId:", chamberId);

        vm.startBroadcast(deployerKey);

        console2.log("[1] commitChamber");
        registry.commitChamber(chamberId, keccak256(abi.encode("debate-root", chamberId)));

        console2.log("[2] deployIdea");
        address ideaToken = factory.deployIdea(_params(chamberId, deployer));
        console2.log("    ideaToken:", ideaToken);

        console2.log("[3] mint 100k idea tokens to deployer");
        MockClankerToken(ideaToken).mint(deployer, 100_000 ether);

        console2.log("[4a] approve BondingEscrow");
        IERC20(ideaToken).approve(BONDING_ESCROW, type(uint256).max);
        console2.log("[4b] approve ForumExecutor");
        IERC20(ideaToken).approve(FORUM_EXECUTOR, type(uint256).max);

        console2.log("[5] createBounty (10k tokens)");
        uint256 bountyId = executor.createBounty(
            IERC20(ideaToken), 10_000 ether, "quorumwrld", "quorum", "issue-v2-1", "Sepolia v2 partial smoke"
        );
        console2.log("    bountyId:", bountyId);

        console2.log("[6a] bondFor 5_000");
        escrow.bondFor(bountyId, 5_000 ether);
        console2.log("[6b] bondAgainst 2_000");
        escrow.bondAgainst(bountyId, 2_000 ether);

        console2.log("[7] claimBounty did:key:agent-test");
        executor.claimBounty(bountyId, "did:key:agent-test");

        console2.log("[8] submitBounty PR-v2");
        executor.submitBounty(bountyId, "PR-v2");

        console2.log("[9] vote(approve=true)");
        executor.vote(bountyId, true);

        vm.stopBroadcast();

        IBondingEscrow.BountyState memory bs = escrow.getBounty(bountyId);
        IBondingEscrow.Position memory pos = escrow.getPosition(bountyId, deployer);
        console2.log("=== Post-vote state ===");
        console2.log("bountyId:", bountyId);
        console2.log("ideaToken:", ideaToken);
        console2.log("status (2=Submitted):", uint256(executor.getStatus(bountyId)));
        console2.log("totalFor:", uint256(bs.totalFor));
        console2.log("totalAgainst:", uint256(bs.totalAgainst));
        console2.log("position.forStake:", uint256(pos.forStake));
        console2.log("position.againstStake:", uint256(pos.againstStake));
        console2.log("Finalize after >= 1h via SepoliaE2EFinalize.s.sol");
    }

    function _params(uint256 chamberId, address creator) internal pure returns (IdeaFactory.DeployParams memory p) {
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = -887_200;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = 887_200;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        string memory ticker = string(abi.encodePacked("V", _toShortHex(chamberId)));

        p = IdeaFactory.DeployParams({
            name: "Quorum v2 smoke",
            ticker: ticker,
            description: "v2 partial smoke (commit -> vote, no finalize)",
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

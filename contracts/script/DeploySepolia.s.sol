// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ChamberRegistry} from "../src/ChamberRegistry.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {BondingEscrow} from "../src/BondingEscrow.sol";
import {ForumExecutor} from "../src/ForumExecutor.sol";
import {IdeaFactory} from "../src/IdeaFactory.sol";
import {MockClanker} from "../src/mocks/MockClanker.sol";
import {IClanker} from "../src/interfaces/IClanker.sol";
import {IChamberRegistry} from "../src/interfaces/IChamberRegistry.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";

/// @notice Base Sepolia deploy — uses MockClanker since real Clanker v4 factory
///         isn't deployed on Sepolia. Idea tokens are stubs (no LP), but the rest
///         of Quorum (chambers, bonding, executor, fee router) is real on-chain.
///
/// Run with:
///   forge script script/DeploySepolia.s.sol:DeploySepolia \
///     --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast
contract DeploySepolia is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployerAddr = vm.addr(deployerKey);

        // Default treasury + relayer to deployer for v1. Split in prod.
        address treasury = vm.envOr("PROTOCOL_TREASURY", deployerAddr);
        address relayer = vm.envOr("RELAYER_DEALER", deployerAddr);

        console2.log("=== Sepolia deploy ===");
        console2.log("Deployer:", deployerAddr);
        console2.log("Treasury:", treasury);
        console2.log("Relayer:", relayer);

        vm.startBroadcast(deployerKey);

        // 0. MockClanker (Sepolia stub)
        MockClanker mockClanker = new MockClanker();
        console2.log("MockClanker:", address(mockClanker));

        // 1. ChamberRegistry
        ChamberRegistry registry = new ChamberRegistry(deployerAddr);
        console2.log("ChamberRegistry:", address(registry));

        // 2. FeeRouter
        FeeRouter router = new FeeRouter(deployerAddr);
        console2.log("FeeRouter:", address(router));

        // 3. BondingEscrow
        BondingEscrow escrow = new BondingEscrow(deployerAddr, treasury);
        console2.log("BondingEscrow:", address(escrow));

        // 4. ForumExecutor — references ChamberRegistry to enforce that bounty
        //    currencies are factory-deployed idea tokens (security audit H-02).
        ForumExecutor executor = new ForumExecutor(deployerAddr, treasury, address(escrow), address(registry));
        console2.log("ForumExecutor:", address(executor));

        // 5. IdeaFactory — points to MockClanker
        //    hook / locker / mevModule are placeholder addresses on Sepolia
        //    (MockClanker ignores them).
        IdeaFactory factory = new IdeaFactory(
            deployerAddr,
            IClanker(address(mockClanker)),
            IChamberRegistry(address(registry)),
            IFeeRouter(address(router)),
            address(0xdead),
            address(0xdead),
            address(0xdead)
        );
        console2.log("IdeaFactory:", address(factory));

        // Wire
        registry.setFactory(address(factory));
        registry.setDealer(relayer);
        router.setFactory(address(factory));
        escrow.setForumExecutor(address(executor));
        factory.setDeployer(relayer);

        vm.stopBroadcast();

        console2.log("=== Deploy complete ===");
    }
}

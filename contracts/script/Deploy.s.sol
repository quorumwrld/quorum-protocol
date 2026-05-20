// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {ChamberRegistry} from "../src/ChamberRegistry.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {BondingEscrow} from "../src/BondingEscrow.sol";
import {ForumExecutor} from "../src/ForumExecutor.sol";
import {IdeaFactory} from "../src/IdeaFactory.sol";
import {IChamberRegistry} from "../src/interfaces/IChamberRegistry.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {IClanker} from "../src/interfaces/IClanker.sol";

/// @notice One-shot deploy script for Quorum's 5 contracts.
/// @dev    Run with: `forge script script/Deploy.s.sol:Deploy --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast`
///
/// Mainnet primitives (from .env):
///   CLANKER_FACTORY=0xE85A59c628F7d27878ACeB4bf3b35733630083a9
///   CLANKER_HOOK_STATIC_FEE=0xDd5EeaFf7BD481AD55Db083062b13a3cdf0A68CC
///   CLANKER_LP_LOCKER_FEE_CONVERSION=0x63D2DfEA64b3433F4071A98665bcD7Ca14d93496
///   CLANKER_MEV_BLOCK_DELAY=0xE143f9872A33c955F23cF442BB4B1EFB3A7402A2
contract Deploy is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address treasury = vm.envAddress("PROTOCOL_TREASURY");
        address clankerFactory = vm.envAddress("CLANKER_FACTORY");
        address clankerHook = vm.envAddress("CLANKER_HOOK_STATIC_FEE");
        address clankerLocker = vm.envAddress("CLANKER_LP_LOCKER_FEE_CONVERSION");
        address clankerMev = vm.envAddress("CLANKER_MEV_BLOCK_DELAY");
        address relayerDealer = vm.envAddress("RELAYER_DEALER");

        vm.startBroadcast(deployerKey);
        address deployerAddr = vm.addr(deployerKey);

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

        // 5. IdeaFactory
        IdeaFactory factory = new IdeaFactory(
            deployerAddr,
            IClanker(clankerFactory),
            IChamberRegistry(address(registry)),
            IFeeRouter(address(router)),
            clankerHook,
            clankerLocker,
            clankerMev
        );
        console2.log("IdeaFactory:", address(factory));

        // Wire everything
        registry.setFactory(address(factory));
        registry.setDealer(relayerDealer);
        router.setFactory(address(factory));
        escrow.setForumExecutor(address(executor));
        factory.setDeployer(relayerDealer);

        vm.stopBroadcast();

        console2.log("--- Deployment complete ---");
        console2.log("Owner:", deployerAddr);
        console2.log("Treasury:", treasury);
        console2.log("Relayer dealer:", relayerDealer);
    }
}

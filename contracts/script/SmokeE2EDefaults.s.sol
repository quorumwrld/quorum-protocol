// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IdeaFactory} from "../src/IdeaFactory.sol";
import {ChamberRegistry} from "../src/ChamberRegistry.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {IClanker} from "../src/interfaces/IClanker.sol";

/// @notice Variant of SmokeE2E that passes EMPTY `poolData` and `lockerData`
///         to validate the in-contract default-substitution path.
///         Same expected result as SmokeE2E: a real Clanker token + V4 LP NFT.
contract SmokeE2EDefaults is Script {
    function run() external {
        address factoryAddr = vm.envAddress("FACTORY");
        address registryAddr = vm.envAddress("REGISTRY");
        address routerAddr = vm.envAddress("ROUTER");
        address escrowAddr = vm.envAddress("ESCROW");
        address executorAddr = vm.envAddress("EXECUTOR");
        address treasury = vm.envAddress("PROTOCOL_TREASURY");
        uint256 relayerKey = vm.envUint("RELAYER_PRIVATE_KEY");

        IdeaFactory factory = IdeaFactory(factoryAddr);
        address creator = vm.addr(relayerKey);
        address paired = 0x4200000000000000000000000000000000000006;

        int24 startingTick = -230_400;
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = startingTick;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = 230_400;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        IdeaFactory.DeployParams memory p = IdeaFactory.DeployParams({
            name: "Default Path",
            ticker: "DEFP",
            description: "validate empty-bytes default substitution",
            image: "",
            metadata: "",
            context: "",
            // Different salt so we don't collide with SmokeE2E
            salt: bytes32(uint256(0xFEEDF00D)),
            creator: creator,
            chamberId: 2,
            protocolTreasury: treasury,
            winnersSplitter: address(0),
            forPool: escrowAddr,
            againstPool: escrowAddr,
            executorPool: executorAddr,
            bps: [uint16(1500), uint16(1500), uint16(1000), uint16(2500), uint16(1000), uint16(2500)],
            pairedToken: paired,
            tickIfToken0IsClanker: startingTick,
            tickSpacing: 200,
            poolData: "", // ← empty: contract substitutes defaultStaticFeePoolData()
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: "", // ← empty: contract substitutes defaultLockerData(1)
            mevModuleData: ""
        });

        vm.startBroadcast(relayerKey);
        address ideaToken = factory.deployIdea(p);
        vm.stopBroadcast();

        console2.log("Idea token (defaults path):", ideaToken);
        console2.log("Registered?", ChamberRegistry(registryAddr).getIdea(ideaToken).exists);
        console2.log("FeeRouter configured?", FeeRouter(routerAddr).isConfigured(ideaToken));

        try IClanker(0xE85A59c628F7d27878ACeB4bf3b35733630083a9).tokenDeploymentInfo(ideaToken) returns (
            IClanker.DeploymentInfo memory info
        ) {
            console2.log("Clanker hook:", info.hook);
            console2.log("Clanker locker:", info.locker);
        } catch {
            console2.log("Clanker.tokenDeploymentInfo reverted");
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IdeaFactory} from "../src/IdeaFactory.sol";
import {ChamberRegistry} from "../src/ChamberRegistry.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {BondingEscrow} from "../src/BondingEscrow.sol";
import {ForumExecutor} from "../src/ForumExecutor.sol";
import {IClanker} from "../src/interfaces/IClanker.sol";

/// @notice End-to-end smoke test: deploy one real Clanker idea token via the
///         IdeaFactory, register it, configure FeeRouter, verify chain state.
/// @dev    Pool / locker params mirror Clanker SDK v4 defaults
///         (see github.com/clanker-devco/clanker-sdk → config/clankerTokenV4.ts):
///         - clankerFee = 100 bps → 10_000 in the on-chain "uniBps" unit (bps * 100)
///         - pairedFee  = 100 bps → 10_000
///         - tickSpacing = 200
///         - tickIfToken0IsClanker = -230_400  (multiple of 200)
///         - single full-range position: tickLower = tickIfToken0IsClanker, tickUpper = 230_400
///         - lockerData = abi.encode(LpFeeConversionInfo{ feePreference: [FeeIn.Both] })
///           where FeeIn.Both = 0 and the array length MUST equal rewardBps.length (= 1).
///         - mevModuleData = "" (ClankerMevBlockDelay ignores the payload entirely).
contract SmokeE2E is Script {
    /// Mirror of ClankerLpLockerFeeConversion.LpFeeConversionInfo.
    /// Encoded into `lockerData`. `feePreference.length` must equal `rewardBps.length`.
    /// FeeIn enum: 0 = Both, 1 = Paired, 2 = Clanker (per IClankerLpLockerFeeConversion).
    struct LpFeeConversionInfo {
        uint8[] feePreference;
    }

    function run() external {
        address factoryAddr = vm.envAddress("FACTORY");
        address registryAddr = vm.envAddress("REGISTRY");
        address routerAddr = vm.envAddress("ROUTER");
        address escrowAddr = vm.envAddress("ESCROW");
        address executorAddr = vm.envAddress("EXECUTOR");
        address treasury = vm.envAddress("PROTOCOL_TREASURY");
        uint256 relayerKey = vm.envUint("RELAYER_PRIVATE_KEY");

        IdeaFactory factory = IdeaFactory(factoryAddr);

        address creator = vm.addr(relayerKey); // for smoke we use relayer as creator
        address paired = 0x4200000000000000000000000000000000000006; // WETH on Base mainnet

        // Single full-range position. Locker enforces:
        //   tickLower[i] >= poolConfig.tickIfToken0IsClanker
        //   tickLower[i] % tickSpacing == 0 && tickUpper[i] % tickSpacing == 0
        //   tickLower[i] < tickUpper[i] and both within [TickMath.MIN_TICK, MAX_TICK]
        int24 startingTick = -230_400;
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = startingTick; // = startingTick (lowest legal)
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = 230_400; // symmetric upper bound, multiple of 200
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        // ClankerHookStaticFee.poolData = abi.encode(uint24 clankerFee, uint24 pairedFee).
        // SDK default 100 bps → 100 * 100 = 10_000 in Uniswap's pips (1e6 = 100%).
        bytes memory poolData = abi.encode(uint24(10_000), uint24(10_000));

        // ClankerLpLockerFeeConversion.lockerData = abi.encode(LpFeeConversionInfo).
        // One reward recipient (the FeeRouter) → one fee preference entry. Both=0.
        uint8[] memory feePreferences = new uint8[](1);
        feePreferences[0] = 0; // FeeIn.Both
        bytes memory lockerData = abi.encode(LpFeeConversionInfo({feePreference: feePreferences}));

        IdeaFactory.DeployParams memory p = IdeaFactory.DeployParams({
            name: "Flash Settle",
            ticker: "FLASH",
            description: "test idea from smoke deploy",
            image: "",
            metadata: "",
            context: "",
            salt: bytes32(uint256(0xCAFEBABE)),
            creator: creator,
            chamberId: 1,
            protocolTreasury: treasury,
            winnersSplitter: address(0),
            forPool: escrowAddr,
            againstPool: escrowAddr,
            executorPool: executorAddr,
            bps: [uint16(1500), uint16(1500), uint16(1000), uint16(2500), uint16(1000), uint16(2500)],
            pairedToken: paired,
            tickIfToken0IsClanker: startingTick,
            tickSpacing: 200,
            poolData: poolData,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: lockerData,
            mevModuleData: ""
        });

        vm.startBroadcast(relayerKey);
        address ideaToken = factory.deployIdea(p);
        vm.stopBroadcast();

        console2.log("Idea token deployed:", ideaToken);
        console2.log("--- Reading back state ---");
        console2.log("Registered in ChamberRegistry?", ChamberRegistry(registryAddr).getIdea(ideaToken).exists);
        console2.log("FeeRouter configured?", FeeRouter(routerAddr).isConfigured(ideaToken));

        // Try to read Clanker's deployment info
        try IClanker(0xE85A59c628F7d27878ACeB4bf3b35733630083a9).tokenDeploymentInfo(ideaToken) returns (
            IClanker.DeploymentInfo memory info
        ) {
            console2.log("Clanker registers it: hook=", info.hook);
            console2.log("Clanker registers it: locker=", info.locker);
        } catch {
            console2.log("Clanker.tokenDeploymentInfo reverted");
        }
    }
}

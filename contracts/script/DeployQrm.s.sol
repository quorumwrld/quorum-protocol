// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IClanker} from "../src/interfaces/IClanker.sol";

/// @title DeployQrm
/// @notice Launches the Quorum protocol token (QRM) via the Clanker v4 factory
///         on Base mainnet (chain 8453). This is a DIRECT call to `Clanker.deployToken`,
///         not via `IdeaFactory.deployIdea` — QRM is the protocol token, not an idea
///         token. Rewards are split immutably between three destinations
///         (treasury / team-vesting / community-treasury) at deploy time and locked
///         in the Clanker LP locker until 2100.
/// @dev Run on a Base-mainnet anvil fork first, then mainnet broadcast separately.
///      Pool / locker params mirror Clanker SDK v4 defaults — see
///      `docs/clanker-mainnet-params.md` and `script/SmokeE2E.s.sol`.
contract DeployQrm is Script {
    // ── Clanker v4 mainnet addresses (immutable) ────────────────────────────
    address constant CLANKER_FACTORY = 0xE85A59c628F7d27878ACeB4bf3b35733630083a9;
    address constant CLANKER_HOOK_STATIC_FEE = 0xDd5EeaFf7BD481AD55Db083062b13a3cdf0A68CC;
    address constant CLANKER_LP_LOCKER = 0x63D2DfEA64b3433F4071A98665bcD7Ca14d93496;
    address constant CLANKER_MEV_BLOCK_DELAY = 0xE143f9872A33c955F23cF442BB4B1EFB3A7402A2;
    address constant WETH_BASE = 0x4200000000000000000000000000000000000006;

    // ── Pool geometry (SDK v4 defaults) ──────────────────────────────────────
    int24 constant STARTING_TICK = -230_400;
    int24 constant UPPER_TICK = 230_400;
    int24 constant TICK_SPACING = 200;
    uint24 constant CLANKER_FEE_PIPS = 10_000; // 100 bps (Uniswap pips: 1e6 = 100%)
    uint24 constant PAIRED_FEE_PIPS = 10_000; // 100 bps

    // ── Reward split (per DECISIONS.md #002) ─────────────────────────────────
    uint16 constant TREASURY_BPS = 6_000; // 60% DAO multi-sig
    uint16 constant TEAM_BPS = 3_000; // 30% team vesting
    uint16 constant COMMUNITY_BPS = 1_000; // 10% community treasury

    /// Mirror of ClankerLpLockerFeeConversion.LpFeeConversionInfo (see SmokeE2E).
    /// `feePreference.length` MUST equal `rewardBps.length`. FeeIn: 0=Both, 1=Paired, 2=Clanker.
    struct LpFeeConversionInfo {
        uint8[] feePreference;
    }

    function run() external returns (address qrm) {
        uint256 deployerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address treasury = vm.envAddress("PROTOCOL_TREASURY");
        address teamVesting = vm.envAddress("TEAM_VESTING");
        address communityTreasury = vm.envAddress("COMMUNITY_TREASURY");

        address deployer = vm.addr(deployerKey);

        console2.log("=== DeployQrm ===");
        console2.log("chainId:           ", block.chainid);
        console2.log("deployer:          ", deployer);
        console2.log("treasury (60%):    ", treasury);
        console2.log("teamVesting (30%): ", teamVesting);
        console2.log("community (10%):   ", communityTreasury);
        require(treasury != address(0) && teamVesting != address(0) && communityTreasury != address(0), "zero addr");

        // ── Token identity ───────────────────────────────────────────────────
        IClanker.TokenConfig memory tokenConfig = IClanker.TokenConfig({
            tokenAdmin: treasury, // DAO Safe owns token admin role
            name: "Quorum",
            symbol: "QRM",
            salt: keccak256("quorum-v1"),
            image: "ipfs://[fill-in]/quorum-mark.png",
            metadata: '{"description":"Quorum protocol token","website":"https://quorum-app-247.netlify.app"}',
            context: "",
            originatingChainId: 8453
        });

        // ── Pool config ──────────────────────────────────────────────────────
        bytes memory poolData = abi.encode(CLANKER_FEE_PIPS, PAIRED_FEE_PIPS);
        IClanker.PoolConfig memory poolConfig = IClanker.PoolConfig({
            hook: CLANKER_HOOK_STATIC_FEE,
            pairedToken: WETH_BASE,
            tickIfToken0IsClanker: STARTING_TICK,
            tickSpacing: TICK_SPACING,
            poolData: poolData
        });

        // ── Reward arrays (3 recipients) ─────────────────────────────────────
        address[] memory rewardAdmins = new address[](3);
        rewardAdmins[0] = treasury;
        rewardAdmins[1] = teamVesting;
        rewardAdmins[2] = communityTreasury;

        address[] memory rewardRecipients = new address[](3);
        rewardRecipients[0] = treasury;
        rewardRecipients[1] = teamVesting;
        rewardRecipients[2] = communityTreasury;

        uint16[] memory rewardBps = new uint16[](3);
        rewardBps[0] = TREASURY_BPS;
        rewardBps[1] = TEAM_BPS;
        rewardBps[2] = COMMUNITY_BPS;
        // sanity: locker enforces sum == 10_000
        require(uint256(rewardBps[0]) + rewardBps[1] + rewardBps[2] == 10_000, "bps");

        // Single full-range position. positionBps sums to 10_000.
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = STARTING_TICK;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = UPPER_TICK;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        // lockerData: feePreference.length MUST equal rewardBps.length (= 3).
        uint8[] memory feePreferences = new uint8[](3);
        feePreferences[0] = 0; // FeeIn.Both
        feePreferences[1] = 0;
        feePreferences[2] = 0;
        bytes memory lockerData = abi.encode(LpFeeConversionInfo({feePreference: feePreferences}));

        IClanker.LockerConfig memory lockerConfig = IClanker.LockerConfig({
            locker: CLANKER_LP_LOCKER,
            rewardAdmins: rewardAdmins,
            rewardRecipients: rewardRecipients,
            rewardBps: rewardBps,
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: lockerData
        });

        IClanker.MevModuleConfig memory mevConfig = IClanker.MevModuleConfig({
            mevModule: CLANKER_MEV_BLOCK_DELAY,
            mevModuleData: ""
        });

        IClanker.DeploymentConfig memory cfg = IClanker.DeploymentConfig({
            tokenConfig: tokenConfig,
            poolConfig: poolConfig,
            lockerConfig: lockerConfig,
            mevModuleConfig: mevConfig,
            extensionConfigs: new IClanker.ExtensionConfig[](0)
        });

        // ── Broadcast deploy ─────────────────────────────────────────────────
        vm.startBroadcast(deployerKey);
        qrm = IClanker(CLANKER_FACTORY).deployToken(cfg);
        vm.stopBroadcast();

        console2.log("");
        console2.log("=== QRM deployed ===");
        console2.log("QRM address:       ", qrm);

        // ── Verify ───────────────────────────────────────────────────────────
        IClanker.DeploymentInfo memory info = IClanker(CLANKER_FACTORY).tokenDeploymentInfo(qrm);
        console2.log("Clanker hook:      ", info.hook);
        console2.log("Clanker locker:    ", info.locker);
        require(info.hook == CLANKER_HOOK_STATIC_FEE, "hook mismatch");
        require(info.locker == CLANKER_LP_LOCKER, "locker mismatch");

        // First holder check: 100B QRM minted to the LP locker for the V4 position.
        (bool ok, bytes memory ret) =
            qrm.staticcall(abi.encodeWithSignature("balanceOf(address)", CLANKER_LP_LOCKER));
        if (ok && ret.length == 32) {
            uint256 lockerBal = abi.decode(ret, (uint256));
            console2.log("LP locker QRM bal: ", lockerBal);
        }

        // Initial market cap notes — STARTING_TICK = -230_400 with WETH-as-paired puts
        // ~1 WETH-worth of QRM concentrated at the top of the curve. Per the
        // mainnet-fork smoke test the resulting starting market cap is ~15 ETH-denominated
        // before any buys. At WETH ~$3500 that's roughly $52.5k FDV with 100B supply.
        console2.log("");
        console2.log("Starting tick: -230_400  (~15 ETH initial market cap, ~$52.5k at WETH=$3500)");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IClanker} from "./interfaces/IClanker.sol";
import {IChamberRegistry} from "./interfaces/IChamberRegistry.sol";
import {IFeeRouter} from "./interfaces/IFeeRouter.sol";

/// @title IdeaFactory
/// @notice Deploys each graduated idea as a Clanker v4 token on Base, registers it
///         with `ChamberRegistry`, and configures its 6-way fee split in `FeeRouter`.
/// @dev Routes idea-token deployment through the Clanker v4 factory so token
///      creation and LP locking happen onchain at graduation time, with no
///      off-chain dealer required to migrate liquidity.
///
///      Emergency pause: `pause()` halts NEW idea deployments. Already-deployed ideas
///      keep operating (FeeRouter / BondingEscrow / ForumExecutor settlement and claim
///      paths are independent and intentionally NOT gated by this contract's pause
///      state — pausing them too would trap user funds mid-bounty).
contract IdeaFactory is Ownable, Pausable, ReentrancyGuard {
    IClanker public immutable clanker;
    IChamberRegistry public chamberRegistry;
    IFeeRouter public feeRouter;

    /// Server relayer wallet allowed to call `deployIdea` on behalf of validated chambers.
    address public deployer;

    /// Mainnet hooks / lockers used by every idea deploy (configurable, but immutable
    /// per protocol upgrade). All are official Clanker v4 mainnet addresses.
    address public clankerHook; // typically ClankerHookStaticFee
    address public clankerLocker; // ClankerLpLockerFeeConversion
    address public clankerMevModule; // ClankerMevBlockDelay

    /// Storage of deployed ideas (one slot per Clanker token address).
    address[] internal _deployedIdeas;
    mapping(address ideaToken => DeployInfo) internal _deployInfo;

    struct DeployInfo {
        uint256 chamberId;
        address creator;
        uint64 deployedAt;
    }

    /// Caller-provided params for `deployIdea`. The relayer constructs this from
    /// off-chain chamber state (allocations + reveal phase outcome).
    struct DeployParams {
        // Identity
        string name;
        string ticker;
        string description;
        string image;
        string metadata;
        string context;
        bytes32 salt;
        // Origin
        address creator;
        uint256 chamberId;
        // Recipients (the 6-way FeeRouter split)
        address protocolTreasury;
        address winnersSplitter; // 0x0 → defaults to `creator`
        address forPool; // typically BondingEscrow
        address againstPool; // typically BondingEscrow
        address executorPool; // typically ForumExecutor
        uint16[6] bps; // must sum to 10000
        // Pool config (Clanker requires)
        address pairedToken; // typically WETH on Base
        int24 tickIfToken0IsClanker;
        int24 tickSpacing;
        bytes poolData;
        // Locker config (positions + ticks)
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionBps;
        bytes lockerData;
        // MEV module data (typically empty)
        bytes mevModuleData;
    }

    event DeployerUpdated(address indexed previousDeployer, address indexed newDeployer);
    event ChamberRegistryUpdated(address indexed previousRegistry, address indexed newRegistry);
    event FeeRouterUpdated(address indexed previousRouter, address indexed newRouter);
    event ClankerHookUpdated(address indexed previousHook, address indexed newHook);
    event ClankerLockerUpdated(address indexed previousLocker, address indexed newLocker);
    event ClankerMevModuleUpdated(address indexed previousModule, address indexed newModule);
    event IdeaDeployed(address indexed ideaToken, uint256 indexed chamberId, address indexed creator, string ticker);

    error NotDeployer();
    error ZeroAddress();
    error InvalidBpsSum(uint256 sum);

    constructor(
        address initialOwner,
        IClanker clanker_,
        IChamberRegistry registry_,
        IFeeRouter router_,
        address hook_,
        address locker_,
        address mevModule_
    ) Ownable(initialOwner) {
        if (
            address(clanker_) == address(0) || address(registry_) == address(0) || address(router_) == address(0)
                || hook_ == address(0) || locker_ == address(0) || mevModule_ == address(0)
        ) revert ZeroAddress();
        clanker = clanker_;
        chamberRegistry = registry_;
        feeRouter = router_;
        clankerHook = hook_;
        clankerLocker = locker_;
        clankerMevModule = mevModule_;
    }

    modifier onlyDeployer() {
        if (msg.sender != deployer && msg.sender != owner()) revert NotDeployer();
        _;
    }

    // ── Admin ────────────────────────────────────────────────────────────────

    function setDeployer(address newDeployer) external onlyOwner {
        if (newDeployer == address(0)) revert ZeroAddress();
        emit DeployerUpdated(deployer, newDeployer);
        deployer = newDeployer;
    }

    function setChamberRegistry(IChamberRegistry newRegistry) external onlyOwner {
        if (address(newRegistry) == address(0)) revert ZeroAddress();
        emit ChamberRegistryUpdated(address(chamberRegistry), address(newRegistry));
        chamberRegistry = newRegistry;
    }

    function setFeeRouter(IFeeRouter newRouter) external onlyOwner {
        if (address(newRouter) == address(0)) revert ZeroAddress();
        emit FeeRouterUpdated(address(feeRouter), address(newRouter));
        feeRouter = newRouter;
    }

    function setClankerHook(address hook) external onlyOwner {
        if (hook == address(0)) revert ZeroAddress();
        emit ClankerHookUpdated(clankerHook, hook);
        clankerHook = hook;
    }

    function setClankerLocker(address locker) external onlyOwner {
        if (locker == address(0)) revert ZeroAddress();
        emit ClankerLockerUpdated(clankerLocker, locker);
        clankerLocker = locker;
    }

    function setClankerMevModule(address mevModule) external onlyOwner {
        if (mevModule == address(0)) revert ZeroAddress();
        emit ClankerMevModuleUpdated(clankerMevModule, mevModule);
        clankerMevModule = mevModule;
    }

    // ── Emergency pause ──────────────────────────────────────────────────────
    //
    // Only `deployIdea` is gated. Existing ideas keep working — settlement and
    // claim paths in BondingEscrow/ForumExecutor/FeeRouter never read this flag.

    /// Halt new idea deployments. Only the owner can pause.
    function pause() external onlyOwner {
        _pause();
    }

    /// Resume new idea deployments.
    function unpause() external onlyOwner {
        _unpause();
    }

    // ── Core ─────────────────────────────────────────────────────────────────

    /// Deploy a Clanker token for an idea graduated from a chamber, register it,
    /// and configure its fee split.
    /// @dev `payable` because Clanker's `deployToken` is `payable` (optional dev-buy).
    ///      We pass-through `msg.value` so the deployer relayer can fund the dev-buy if it wants.
    function deployIdea(DeployParams calldata p)
        external
        payable
        onlyDeployer
        whenNotPaused
        nonReentrant
        returns (address ideaToken)
    {
        // Validate BPS sum
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            sum += p.bps[i];
        }
        if (sum != 10_000) revert InvalidBpsSum(sum);

        // Build Clanker DeploymentConfig. Rewards: 100% to FeeRouter; FeeRouter
        // then splits to the 6 destinations per its per-idea config.
        address[] memory rewardAdmins = new address[](1);
        rewardAdmins[0] = owner(); // protocol owner can rotate the FeeRouter recipient if needed
        address[] memory rewardRecipients = new address[](1);
        rewardRecipients[0] = address(feeRouter);
        uint16[] memory rewardBps = new uint16[](1);
        rewardBps[0] = 10_000;

        // Substitute SDK-aligned defaults when caller passes empty bytes. Clanker's
        // hooks/lockers `abi.decode` these payloads with no length guard, so an empty
        // value produces an empty-revert deep in the call tree. Centralising the
        // fallback here makes relayer integration safe-by-default.
        bytes memory poolDataResolved = p.poolData.length == 0 ? defaultStaticFeePoolData() : p.poolData;
        bytes memory lockerDataResolved = p.lockerData.length == 0 ? defaultLockerData(rewardBps.length) : p.lockerData;

        IClanker.DeploymentConfig memory cfg = IClanker.DeploymentConfig({
            tokenConfig: IClanker.TokenConfig({
                tokenAdmin: address(this),
                name: p.name,
                symbol: p.ticker,
                salt: p.salt,
                image: p.image,
                metadata: p.metadata,
                context: p.context,
                originatingChainId: block.chainid
            }),
            poolConfig: IClanker.PoolConfig({
                hook: clankerHook,
                pairedToken: p.pairedToken,
                tickIfToken0IsClanker: p.tickIfToken0IsClanker,
                tickSpacing: p.tickSpacing,
                poolData: poolDataResolved
            }),
            lockerConfig: IClanker.LockerConfig({
                locker: clankerLocker,
                rewardAdmins: rewardAdmins,
                rewardRecipients: rewardRecipients,
                rewardBps: rewardBps,
                tickLower: p.tickLower,
                tickUpper: p.tickUpper,
                positionBps: p.positionBps,
                lockerData: lockerDataResolved
            }),
            mevModuleConfig: IClanker.MevModuleConfig({
                mevModule: clankerMevModule,
                mevModuleData: p.mevModuleData // ClankerMevBlockDelay ignores this payload.
            }),
            extensionConfigs: new IClanker.ExtensionConfig[](0)
        });

        ideaToken = clanker.deployToken{value: msg.value}(cfg);

        // Register in ChamberRegistry
        chamberRegistry.registerIdea(ideaToken, p.name, p.ticker, p.description, p.creator, p.chamberId);

        // Configure FeeRouter per-idea split
        address[6] memory recipients = [
            p.protocolTreasury,
            p.creator,
            p.winnersSplitter == address(0) ? p.creator : p.winnersSplitter,
            p.forPool,
            p.againstPool,
            p.executorPool
        ];
        feeRouter.configure(ideaToken, recipients, p.bps);

        _deployedIdeas.push(ideaToken);
        _deployInfo[ideaToken] =
            DeployInfo({chamberId: p.chamberId, creator: p.creator, deployedAt: uint64(block.timestamp)});

        emit IdeaDeployed(ideaToken, p.chamberId, p.creator, p.ticker);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    function deployedIdeas() external view returns (address[] memory) {
        return _deployedIdeas;
    }

    function deployedIdeaCount() external view returns (uint256) {
        return _deployedIdeas.length;
    }

    function getDeployInfo(address ideaToken) external view returns (DeployInfo memory) {
        return _deployInfo[ideaToken];
    }

    // ── Clanker-payload helpers (pure) ──────────────────────────────────────
    //
    // These mirror what the Clanker SDK encodes off-chain. Exposed as `pure`
    // helpers so the relayer/dApp can call them via `eth_call` and so the
    // contract can substitute them when `DeployParams.poolData` /
    // `.lockerData` are empty. Hard-coded to match Clanker v4 mainnet:
    //   - hook  = ClankerHookStaticFee     (encodes `(uint24 clankerFee, uint24 pairedFee)`)
    //   - locker= ClankerLpLockerFeeConversion (encodes `LpFeeConversionInfo{ feePreference: uint8[] }`)
    //
    // Per Clanker SDK defaults (see `clanker-sdk/src/config/clankerTokenV4.ts`):
    //   clankerFee = 100 bps  → 100 * 100 = 10_000  uniBps (1_000_000 = 100%)
    //   pairedFee  = 100 bps  → 10_000
    //   FeeIn.Both = 0          (one entry per reward recipient)

    /// `abi.encode((uint24 clankerFee, uint24 pairedFee))` with both = 1%.
    function defaultStaticFeePoolData() public pure returns (bytes memory) {
        return abi.encode(uint24(10_000), uint24(10_000));
    }

    /// Local mirror of `IClankerLpLockerFeeConversion.LpFeeConversionInfo` so we
    /// can ABI-encode the exact struct shape the locker decodes against.
    /// (A bare `abi.encode(uint8[])` would NOT match — struct-wrapping a single
    ///  dynamic field adds an extra offset word at the head.)
    struct LpFeeConversionInfo {
        uint8[] feePreference;
    }

    /// `abi.encode(LpFeeConversionInfo{ feePreference: [FeeIn.Both, …] })`
    /// with `rewardCount` entries, all set to `FeeIn.Both (= 0)`.
    function defaultLockerData(uint256 rewardCount) public pure returns (bytes memory) {
        uint8[] memory feePreferences = new uint8[](rewardCount);
        // Solidity zero-inits arrays → every entry is already FeeIn.Both (= 0).
        return abi.encode(LpFeeConversionInfo({feePreference: feePreferences}));
    }
}

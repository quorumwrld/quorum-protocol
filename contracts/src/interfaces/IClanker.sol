// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IClanker
/// @notice Minimal interface to Clanker v4 factory on Base mainnet
///         (`0xE85A59c628F7d27878ACeB4bf3b35733630083a9`). Mirrors the relevant
///         subset of structs from github.com/clanker-devco/v4-contracts.
/// @dev We do NOT re-export every field of every Clanker struct — only the ones
///      `IdeaFactory.deployIdea` needs to populate. Pool / locker / MEV configs are
///      passed through verbatim.
interface IClanker {
    struct TokenConfig {
        address tokenAdmin;
        string name;
        string symbol;
        bytes32 salt;
        string image;
        string metadata;
        string context;
        uint256 originatingChainId;
    }

    struct PoolConfig {
        address hook;
        address pairedToken;
        int24 tickIfToken0IsClanker;
        int24 tickSpacing;
        bytes poolData;
    }

    struct LockerConfig {
        address locker;
        address[] rewardAdmins;
        address[] rewardRecipients;
        uint16[] rewardBps;
        int24[] tickLower;
        int24[] tickUpper;
        uint16[] positionBps;
        bytes lockerData;
    }

    struct ExtensionConfig {
        address extension;
        uint256 msgValue;
        uint16 extensionBps;
        bytes extensionData;
    }

    struct MevModuleConfig {
        address mevModule;
        bytes mevModuleData;
    }

    struct DeploymentConfig {
        TokenConfig tokenConfig;
        PoolConfig poolConfig;
        LockerConfig lockerConfig;
        MevModuleConfig mevModuleConfig;
        ExtensionConfig[] extensionConfigs;
    }

    struct DeploymentInfo {
        address token;
        address hook;
        address locker;
        address[] extensions;
    }

    function deployToken(DeploymentConfig memory deploymentConfig) external payable returns (address tokenAddress);

    function tokenDeploymentInfo(address token) external view returns (DeploymentInfo memory);
}

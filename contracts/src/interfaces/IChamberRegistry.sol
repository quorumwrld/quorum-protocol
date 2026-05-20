// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IChamberRegistry {
    struct ChamberMetadata {
        uint256 chamberId;
        bytes32 debateMerkleRoot; // Merkle root of all debate moves (commit-reveal)
        address dealer; // server relayer that ran the chamber
        uint64 createdAt;
        uint64 settledAt; // 0 if not yet settled
        bool settled;
    }

    struct IdeaMetadata {
        address tokenAddress;
        string name;
        string ticker;
        string description;
        address creator;
        uint256 chamberId;
        uint64 launchTimestamp;
        bool graduated;
        uint64 graduationTimestamp;
        bool exists;
    }

    function commitChamber(uint256 chamberId, bytes32 debateMerkleRoot) external;

    function registerIdea(
        address tokenAddress,
        string calldata name,
        string calldata ticker,
        string calldata description,
        address creator,
        uint256 chamberId
    ) external;

    function markGraduated(address tokenAddress) external;

    function getIdea(address tokenAddress) external view returns (IdeaMetadata memory);
    function getIdeaByTicker(string calldata ticker) external view returns (address);
    function getIdeasByChamber(uint256 chamberId) external view returns (address[] memory);
    function getGraduatedIdeas() external view returns (address[] memory);
    function getIdeaCount() external view returns (uint256);
    /// Non-reverting lookup — `true` iff `tokenAddress` was registered through
    /// `registerIdea` (i.e. is a real factory-deployed Quorum idea token).
    function isRegisteredIdea(address tokenAddress) external view returns (bool);
}

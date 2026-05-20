// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IBondingEscrow {
    enum Side {
        For,
        Against
    }

    enum Settlement {
        Open, // 0 — bonding still open, no settlement
        ForWon, // 1 — PR was merged, FOR-bonders win
        AgainstWon // 2 — PR rejected / expired, AGAINST-bonders win
    }

    struct Position {
        uint128 forStake;
        uint128 againstStake;
        bool claimed;
    }

    struct BountyState {
        address ideaToken;
        uint128 totalFor;
        uint128 totalAgainst;
        Settlement settlement;
        bool registered;
    }

    function registerBounty(uint256 bountyId, address ideaToken) external;
    function settle(uint256 bountyId, bool forWon) external;
    function bondFor(uint256 bountyId, uint256 amount) external;
    function bondAgainst(uint256 bountyId, uint256 amount) external;
    function claim(uint256 bountyId) external;

    function getBounty(uint256 bountyId) external view returns (BountyState memory);
    function getPosition(uint256 bountyId, address bonder) external view returns (Position memory);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IClanker} from "../src/interfaces/IClanker.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Test-only stand-in for the Clanker v4 factory.
///         Pretends to deploy a token by creating a fresh MockERC20.
contract MockClanker is IClanker {
    address[] public deployed;
    DeploymentConfig public lastConfig;

    function deployToken(DeploymentConfig memory cfg) external payable returns (address tokenAddress) {
        MockERC20 token = new MockERC20(cfg.tokenConfig.name, cfg.tokenConfig.symbol);
        // Mint a small float so tests can pretend trading happens; real Clanker single-sides LP.
        token.mint(address(this), 1_000_000 ether);
        deployed.push(address(token));
        // We can't store the full DeploymentConfig (contains dynamic arrays).
        // Tests assert outcomes via emitted events from IdeaFactory instead.
        tokenAddress = address(token);
    }

    function deployTokenZeroSupply(TokenConfig memory cfg) external returns (address) {
        MockERC20 token = new MockERC20(cfg.name, cfg.symbol);
        deployed.push(address(token));
        return address(token);
    }

    function tokenDeploymentInfo(
        address /*token*/
    )
        external
        pure
        returns (DeploymentInfo memory)
    {
        return DeploymentInfo({token: address(0), hook: address(0), locker: address(0), extensions: new address[](0)});
    }

    function deprecated() external pure returns (bool) {
        return false;
    }

    function deployedCount() external view returns (uint256) {
        return deployed.length;
    }
}

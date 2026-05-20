// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IClanker} from "../interfaces/IClanker.sol";

/// @notice Stub-Clanker used on testnets where Clanker v4 is not deployed.
///         Pretends to deploy a token by creating a fresh OZ ERC-20 with no LP.
///         NOT for mainnet — production code calls the real Clanker v4 factory
///         at 0xE85A59c628F7d27878ACeB4bf3b35733630083a9.
contract MockClanker is IClanker {
    address[] public deployed;

    function deployToken(DeploymentConfig memory cfg) external payable returns (address tokenAddress) {
        MockClankerToken token = new MockClankerToken(cfg.tokenConfig.name, cfg.tokenConfig.symbol);
        // Mint a small float so downstream tests can pretend trading happens.
        token.mint(address(this), 1_000_000 ether);
        deployed.push(address(token));
        tokenAddress = address(token);
    }

    function deployTokenZeroSupply(TokenConfig memory cfg) external returns (address) {
        MockClankerToken token = new MockClankerToken(cfg.name, cfg.symbol);
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

contract MockClankerToken is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

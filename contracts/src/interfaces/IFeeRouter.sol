// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface IFeeRouter {
    /// Configure the per-idea 6-way split. Only callable by IdeaFactory once per idea.
    /// @param ideaToken The Clanker-deployed token address.
    /// @param recipients Length-6 array: [protocol, creator, debateWinners, forPool, againstPool, executor].
    /// @param bps Length-6 array, must sum to exactly 10000.
    function configure(address ideaToken, address[6] calldata recipients, uint16[6] calldata bps) external;

    /// Permissionless flush. Reads `ideaToken.balanceOf(this)` and distributes per config.
    /// Anyone can call; gas paid by caller; no caller reward (run by keeper / cron).
    function flush(address ideaToken) external;

    /// True once a config has been set for this idea. Cannot be re-configured.
    function isConfigured(address ideaToken) external view returns (bool);
}

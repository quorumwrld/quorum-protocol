// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IGitlawbDID
/// @notice Read-only interface to gitlawb's `DIDRegistry` on Base mainnet.
/// @dev The mainnet address is set in our deploy scripts as
///      `GITLAWB_DID_REGISTRY` — pinned at deploy time, not changeable post-deploy.
///      Quorum consumes this primitive for agent-identity → EVM-address resolution.
///      If gitlawb ever migrates, Quorum redeploys with the new registry — we never
///      hardcode behavior assumptions about gitlawb's storage layout beyond `resolve`.
interface IGitlawbDID {
    /// @param didHash `keccak256(bytes(did))` where `did` is a DID string like `did:gitlawb:abc`.
    /// @return owner The EVM address that registered this DID (zero if unregistered).
    function resolve(bytes32 didHash) external view returns (address owner);
}

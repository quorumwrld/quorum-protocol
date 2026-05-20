// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TransferOwnership
/// @notice Transfers ownership of all 5 Quorum contracts to a new owner —
///         typically a Safe (Gnosis) multisig at app.safe.global.
///
/// @dev Idempotent across runs: if a contract is already owned by the target,
///      we skip and log. If ownership is held by a different address, we revert
///      so the operator can investigate (no surprise re-transfers).
///
/// @dev Run on the *current* owner key (EOA or Safe). Required env vars:
///        CHAMBER_REGISTRY    — address of deployed ChamberRegistry
///        FEE_ROUTER          — address of deployed FeeRouter
///        BONDING_ESCROW      — address of deployed BondingEscrow
///        FORUM_EXECUTOR      — address of deployed ForumExecutor
///        IDEA_FACTORY        — address of deployed IdeaFactory
///        NEW_OWNER           — destination owner (the Safe multisig)
///        DEPLOYER_PRIVATE_KEY — current owner's private key
///
/// @dev Usage:
///   forge script script/TransferOwnership.s.sol:TransferOwnership \
///     --rpc-url $BASE_RPC_URL --broadcast --slow
///
/// @dev Post-transfer verification (see docs/multisig-setup.md § "Verify
///      ownership transfer"):
///   cast call $CHAMBER_REGISTRY 'owner()(address)' --rpc-url $BASE_RPC_URL
///   cast call $FEE_ROUTER       'owner()(address)' --rpc-url $BASE_RPC_URL
///   cast call $BONDING_ESCROW   'owner()(address)' --rpc-url $BASE_RPC_URL
///   cast call $FORUM_EXECUTOR   'owner()(address)' --rpc-url $BASE_RPC_URL
///   cast call $IDEA_FACTORY     'owner()(address)' --rpc-url $BASE_RPC_URL
///   All five MUST equal $NEW_OWNER.
contract TransferOwnership is Script {
    function run() external {
        uint256 ownerKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address currentOwner = vm.addr(ownerKey);
        address newOwner = vm.envAddress("NEW_OWNER");

        require(newOwner != address(0), "TransferOwnership: NEW_OWNER is zero");
        require(newOwner != currentOwner, "TransferOwnership: NEW_OWNER == currentOwner");

        address[5] memory contracts = [
            vm.envAddress("CHAMBER_REGISTRY"),
            vm.envAddress("FEE_ROUTER"),
            vm.envAddress("BONDING_ESCROW"),
            vm.envAddress("FORUM_EXECUTOR"),
            vm.envAddress("IDEA_FACTORY")
        ];
        string[5] memory names = ["ChamberRegistry", "FeeRouter", "BondingEscrow", "ForumExecutor", "IdeaFactory"];

        console2.log("=== Transfer ownership ===");
        console2.log("Current owner:", currentOwner);
        console2.log("New owner    :", newOwner);

        vm.startBroadcast(ownerKey);
        for (uint256 i = 0; i < contracts.length; i++) {
            address target = contracts[i];
            require(target != address(0), string.concat(names[i], ": address is zero"));

            address existing = Ownable(target).owner();
            if (existing == newOwner) {
                console2.log(string.concat(names[i], " already owned by NEW_OWNER, skipping"));
                continue;
            }
            require(existing == currentOwner, string.concat(names[i], ": not owned by signer, refusing to transfer"));

            Ownable(target).transferOwnership(newOwner);
            console2.log(string.concat(names[i], " ownership transferred"));
            console2.log("  ", target, "->", newOwner);
        }
        vm.stopBroadcast();

        console2.log("=== Done. Verify with: cast call <addr> 'owner()(address)' ===");
    }
}

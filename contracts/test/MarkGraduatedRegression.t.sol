// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChamberRegistry} from "../src/ChamberRegistry.sol";
import {IChamberRegistry} from "../src/interfaces/IChamberRegistry.sol";

/// @notice Adversarial regression tests for `ChamberRegistry.markGraduated`.
///         An open-auth path to this function would let an attacker flip the
///         flag and skew fee routing. We restrict to `msg.sender == tokenAddress
///         || msg.sender == factory`, BUT an attacker could still theoretically
///         deploy a contract at some address X and call `markGraduated(X)` from
///         X. These tests prove that the second guard (`!idea.exists`) keeps
///         unregistered tokens out, so the address-equality check alone is NOT
///         load-bearing.
contract MarkGraduatedRegressionTest is Test {
    ChamberRegistry registry;
    address owner = address(0xA1);
    address factory = address(0xF1);
    address creator = address(0xC1);
    address legitIdea = address(0x1DEA);

    function setUp() public {
        vm.prank(owner);
        registry = new ChamberRegistry(owner);
        vm.prank(owner);
        registry.setFactory(factory);
    }

    /// An adversary controls some address X. They call `markGraduated(X)` FROM X.
    /// Because X was never registered through the factory, the call must revert
    /// with `IdeaNotFound`. This is the load-bearing guard, NOT the address check.
    function test_Adversary_UnregisteredSelfCall_Reverts() public {
        // Attacker deploys this contract; its address is unregistered.
        AdversaryToken bad = new AdversaryToken(registry);

        vm.expectRevert(abi.encodeWithSelector(ChamberRegistry.IdeaNotFound.selector, address(bad)));
        bad.attemptSelfGraduate();
    }

    /// Even an EOA can't graduate itself when unregistered.
    function test_Adversary_UnregisteredEOA_Reverts() public {
        address evil = address(0xBADBEEF);
        vm.prank(evil);
        vm.expectRevert(abi.encodeWithSelector(ChamberRegistry.IdeaNotFound.selector, evil));
        registry.markGraduated(evil);
    }

    /// An adversary calling on behalf of a LEGIT registered idea (from any other
    /// EOA) still reverts because of the address-equality check.
    function test_Adversary_LegitIdea_FromWrongAddress_Reverts() public {
        // Factory registers a real idea
        vm.prank(factory);
        registry.registerIdea(legitIdea, "Flash", "FLASH", "desc", creator, 1);

        // Random caller tries to mark the legit idea graduated
        vm.prank(address(0xBADBEEF));
        vm.expectRevert(ChamberRegistry.NotIdeaTokenOrFactory.selector);
        registry.markGraduated(legitIdea);
    }

    /// Adversary calls `markGraduated(legitIdea)` from a contract that pretends
    /// to be `legitIdea` — but it isn't `legitIdea`, so the address-equality
    /// check rejects it.
    function test_Adversary_ImpersonatorContract_Reverts() public {
        vm.prank(factory);
        registry.registerIdea(legitIdea, "Flash", "FLASH", "desc", creator, 1);

        AdversaryToken impersonator = new AdversaryToken(registry);
        vm.expectRevert(ChamberRegistry.NotIdeaTokenOrFactory.selector);
        impersonator.attemptGraduate(legitIdea);
    }

    /// Sanity: a registered token can graduate itself (positive path).
    function test_RegisteredIdea_SelfGraduates_Works() public {
        vm.prank(factory);
        registry.registerIdea(legitIdea, "Flash", "FLASH", "desc", creator, 1);

        vm.prank(legitIdea);
        registry.markGraduated(legitIdea);
        assertTrue(registry.isGraduated(legitIdea));
    }

    /// Sanity: factory can graduate any registered idea (positive path).
    function test_Factory_GraduatesRegisteredIdea_Works() public {
        vm.prank(factory);
        registry.registerIdea(legitIdea, "Flash", "FLASH", "desc", creator, 1);

        vm.prank(factory);
        registry.markGraduated(legitIdea);
        assertTrue(registry.isGraduated(legitIdea));
    }
}

/// Minimal contract used to simulate an attacker. It can call `markGraduated`
/// either passing its own address (self-graduate attempt) or a different
/// address (impersonation attempt).
contract AdversaryToken {
    ChamberRegistry private immutable REGISTRY;

    constructor(ChamberRegistry registry_) {
        REGISTRY = registry_;
    }

    function attemptSelfGraduate() external {
        REGISTRY.markGraduated(address(this));
    }

    function attemptGraduate(address tokenAddress) external {
        REGISTRY.markGraduated(tokenAddress);
    }
}

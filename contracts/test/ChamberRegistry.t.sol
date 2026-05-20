// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChamberRegistry} from "../src/ChamberRegistry.sol";
import {IChamberRegistry} from "../src/interfaces/IChamberRegistry.sol";

contract ChamberRegistryTest is Test {
    ChamberRegistry registry;
    address owner = address(0xA1);
    address factory = address(0xF1);
    address dealer = address(0xD1);
    address creator = address(0xC1);
    address ideaToken = address(0x1DEA);

    function setUp() public {
        vm.prank(owner);
        registry = new ChamberRegistry(owner);
        vm.prank(owner);
        registry.setFactory(factory);
        vm.prank(owner);
        registry.setDealer(dealer);
    }

    function test_RegisterIdea_OnlyFactory() public {
        vm.expectRevert(ChamberRegistry.NotFactory.selector);
        registry.registerIdea(ideaToken, "Flash", "FLASH", "desc", creator, 1);
    }

    function test_RegisterIdea_HappyPath() public {
        vm.prank(factory);
        registry.registerIdea(ideaToken, "Flash", "FLASH", "desc", creator, 1);

        IChamberRegistry.IdeaMetadata memory idea = registry.getIdea(ideaToken);
        assertEq(idea.tokenAddress, ideaToken);
        assertEq(idea.ticker, "FLASH");
        assertEq(idea.creator, creator);
        assertFalse(idea.graduated);
        assertEq(registry.getIdeaByTicker("FLASH"), ideaToken);
        assertEq(registry.getIdeaCount(), 1);
    }

    function test_RegisterIdea_DuplicateReverts() public {
        vm.prank(factory);
        registry.registerIdea(ideaToken, "Flash", "FLASH", "desc", creator, 1);

        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(ChamberRegistry.IdeaExists.selector, ideaToken));
        registry.registerIdea(ideaToken, "Flash", "FLASH", "desc", creator, 1);
    }

    function test_RegisterIdea_TickerCollisionReverts() public {
        vm.prank(factory);
        registry.registerIdea(ideaToken, "Flash", "FLASH", "desc", creator, 1);

        address ideaToken2 = address(0x2DEA);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(ChamberRegistry.TickerTaken.selector, "FLASH"));
        registry.registerIdea(ideaToken2, "Flash2", "FLASH", "desc2", creator, 1);
    }

    /// CRITICAL: `markGraduated` must NEVER be callable by an arbitrary EOA — an
    /// open-auth path would let an attacker flip the flag and skew fee routing.
    /// The implementation restricts to (a) the idea token itself, or (b) the factory.
    function test_MarkGraduated_RandomCallerReverts() public {
        vm.prank(factory);
        registry.registerIdea(ideaToken, "Flash", "FLASH", "desc", creator, 1);

        address randomAttacker = address(0xBADBEEF);
        vm.prank(randomAttacker);
        vm.expectRevert(ChamberRegistry.NotIdeaTokenOrFactory.selector);
        registry.markGraduated(ideaToken);
    }

    function test_MarkGraduated_FactoryAllowed() public {
        vm.prank(factory);
        registry.registerIdea(ideaToken, "Flash", "FLASH", "desc", creator, 1);

        vm.prank(factory);
        registry.markGraduated(ideaToken);

        assertTrue(registry.isGraduated(ideaToken));
    }

    function test_MarkGraduated_IdeaTokenAllowed() public {
        vm.prank(factory);
        registry.registerIdea(ideaToken, "Flash", "FLASH", "desc", creator, 1);

        vm.prank(ideaToken);
        registry.markGraduated(ideaToken);

        assertTrue(registry.isGraduated(ideaToken));
    }

    function test_MarkGraduated_Idempotent() public {
        vm.prank(factory);
        registry.registerIdea(ideaToken, "Flash", "FLASH", "desc", creator, 1);

        vm.prank(factory);
        registry.markGraduated(ideaToken);
        vm.prank(factory);
        registry.markGraduated(ideaToken); // second call is a no-op, must not revert
        assertTrue(registry.isGraduated(ideaToken));
    }

    function test_CommitChamber_OnlyDealer() public {
        vm.expectRevert(ChamberRegistry.NotDealer.selector);
        registry.commitChamber(1, bytes32(uint256(0xABCD)));
    }

    function test_CommitChamber_HappyPath() public {
        vm.prank(dealer);
        registry.commitChamber(42, bytes32(uint256(0xABCD)));
        IChamberRegistry.ChamberMetadata memory c = registry.getChamber(42);
        assertEq(c.chamberId, 42);
        assertEq(c.debateMerkleRoot, bytes32(uint256(0xABCD)));
        assertEq(c.dealer, dealer);
    }

    function test_CommitChamber_RecommitReverts() public {
        vm.prank(dealer);
        registry.commitChamber(42, bytes32(uint256(0xABCD)));
        vm.prank(dealer);
        vm.expectRevert(abi.encodeWithSelector(ChamberRegistry.ChamberAlreadyCommitted.selector, uint256(42)));
        registry.commitChamber(42, bytes32(uint256(0xDEAD)));
    }

    function test_GetGraduatedIdeas() public {
        address[3] memory tokens = [address(0x1), address(0x2), address(0x3)];
        for (uint256 i; i < 3; ++i) {
            vm.prank(factory);
            registry.registerIdea(
                tokens[i], string.concat("Idea-", _toString(i)), string.concat("T", _toString(i)), "d", creator, 1
            );
        }
        vm.prank(factory);
        registry.markGraduated(tokens[0]);
        vm.prank(factory);
        registry.markGraduated(tokens[2]);

        address[] memory grads = registry.getGraduatedIdeas();
        assertEq(grads.length, 2);
        assertEq(grads[0], tokens[0]);
        assertEq(grads[1], tokens[2]);
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory b = new bytes(len);
        while (v != 0) {
            b[--len] = bytes1(uint8(48 + v % 10));
            v /= 10;
        }
        return string(b);
    }
}

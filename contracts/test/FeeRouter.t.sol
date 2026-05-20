// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {MockERC20} from "./MockERC20.sol";

contract FeeRouterTest is Test {
    FeeRouter router;
    MockERC20 token;
    address owner = address(0xA1);
    address factory = address(0xF1);

    address protocol = address(0xB1);
    address creator = address(0xB2);
    address winners = address(0xB3);
    address forPool = address(0xB4);
    address againstPool = address(0xB5);
    address executor = address(0xB6);

    address[6] recipients;
    uint16[6] bps;

    function setUp() public {
        vm.prank(owner);
        router = new FeeRouter(owner);
        vm.prank(owner);
        router.setFactory(factory);

        token = new MockERC20("Idea", "IDEA");

        recipients = [protocol, creator, winners, forPool, againstPool, executor];
        bps = [uint16(1500), uint16(1500), uint16(1000), uint16(2500), uint16(1000), uint16(2500)];
    }

    function test_Configure_OnlyFactory() public {
        vm.expectRevert(FeeRouter.NotFactory.selector);
        router.configure(address(token), recipients, bps);
    }

    function test_Configure_HappyPath() public {
        vm.prank(factory);
        router.configure(address(token), recipients, bps);
        assertTrue(router.isConfigured(address(token)));
    }

    function test_Configure_BpsSumInvalid_Reverts() public {
        uint16[6] memory badBps = [uint16(1500), uint16(1500), uint16(1000), uint16(2500), uint16(1000), uint16(1000)];
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.BpsSumInvalid.selector, uint256(8500)));
        router.configure(address(token), recipients, badBps);
    }

    function test_Configure_ZeroRecipient_Reverts() public {
        address[6] memory badRecipients = [protocol, address(0), winners, forPool, againstPool, executor];
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.ZeroRecipient.selector, uint256(1)));
        router.configure(address(token), badRecipients, bps);
    }

    function test_Configure_Twice_Reverts() public {
        vm.prank(factory);
        router.configure(address(token), recipients, bps);
        vm.prank(factory);
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.AlreadyConfigured.selector, address(token)));
        router.configure(address(token), recipients, bps);
    }

    function test_Flush_HappyPath() public {
        vm.prank(factory);
        router.configure(address(token), recipients, bps);

        token.mint(address(router), 10_000 ether);
        router.flush(address(token));

        assertEq(token.balanceOf(protocol), 1500 ether);
        assertEq(token.balanceOf(creator), 1500 ether);
        assertEq(token.balanceOf(winners), 1000 ether);
        assertEq(token.balanceOf(forPool), 2500 ether);
        assertEq(token.balanceOf(againstPool), 1000 ether);
        assertEq(token.balanceOf(executor), 2500 ether);
        assertEq(token.balanceOf(address(router)), 0);
    }

    function test_Flush_ZeroBalanceNoOp() public {
        vm.prank(factory);
        router.configure(address(token), recipients, bps);
        router.flush(address(token)); // does not revert, distributes nothing
        assertEq(token.balanceOf(protocol), 0);
    }

    function test_Flush_NotConfigured_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(FeeRouter.NotConfigured.selector, address(token)));
        router.flush(address(token));
    }

    function test_Flush_RoundingDustToLastRecipient() public {
        vm.prank(factory);
        router.configure(address(token), recipients, bps);

        // 100 wei → splits won't divide evenly into 6 BPS slots. Remainder must go to executor (last slot).
        token.mint(address(router), 100);
        router.flush(address(token));
        assertEq(token.balanceOf(address(router)), 0, "all dust distributed");
        // Sum of all recipient balances must equal 100
        uint256 sum = token.balanceOf(protocol) + token.balanceOf(creator) + token.balanceOf(winners)
            + token.balanceOf(forPool) + token.balanceOf(againstPool) + token.balanceOf(executor);
        assertEq(sum, 100);
    }

    function testFuzz_FlushConservation(uint256 amount) public {
        amount = bound(amount, 1, type(uint128).max);
        vm.prank(factory);
        router.configure(address(token), recipients, bps);
        token.mint(address(router), amount);
        router.flush(address(token));

        uint256 sum = token.balanceOf(protocol) + token.balanceOf(creator) + token.balanceOf(winners)
            + token.balanceOf(forPool) + token.balanceOf(againstPool) + token.balanceOf(executor);
        assertEq(sum, amount, "conservation: no funds lost in flush");
        assertEq(token.balanceOf(address(router)), 0, "router is fully drained");
    }
}

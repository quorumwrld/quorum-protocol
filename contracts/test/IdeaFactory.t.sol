// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IdeaFactory} from "../src/IdeaFactory.sol";
import {ChamberRegistry} from "../src/ChamberRegistry.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {IClanker} from "../src/interfaces/IClanker.sol";
import {IChamberRegistry} from "../src/interfaces/IChamberRegistry.sol";
import {IFeeRouter} from "../src/interfaces/IFeeRouter.sol";
import {MockClanker} from "./MockClanker.sol";

contract IdeaFactoryTest is Test {
    IdeaFactory factory;
    ChamberRegistry registry;
    FeeRouter router;
    MockClanker clanker;

    address owner = address(0xA1);
    address relayer = address(0xBE1);
    address creator = address(0xCE0);

    address protocolTreasury = address(0xB1);
    address forPool = address(0xB4);
    address againstPool = address(0xB5);
    address executorPool = address(0xB6);

    address hook = address(0x4001);
    address locker = address(0x4002);
    address mevModule = address(0x4003);
    address paired = address(0x4200000000000000000000000000000000000006); // WETH-shape

    function setUp() public {
        clanker = new MockClanker();

        vm.startPrank(owner);
        registry = new ChamberRegistry(owner);
        router = new FeeRouter(owner);
        factory = new IdeaFactory(
            owner,
            IClanker(address(clanker)),
            IChamberRegistry(address(registry)),
            IFeeRouter(address(router)),
            hook,
            locker,
            mevModule
        );
        registry.setFactory(address(factory));
        router.setFactory(address(factory));
        factory.setDeployer(relayer);
        vm.stopPrank();
    }

    function _defaultParams() internal view returns (IdeaFactory.DeployParams memory p) {
        int24[] memory tickLower = new int24[](1);
        tickLower[0] = -887_220;
        int24[] memory tickUpper = new int24[](1);
        tickUpper[0] = 887_220;
        uint16[] memory positionBps = new uint16[](1);
        positionBps[0] = 10_000;

        p = IdeaFactory.DeployParams({
            name: "FlashSettle",
            ticker: "FLASH",
            description: "settle in flash",
            image: "ipfs://x",
            metadata: "{}",
            context: "",
            salt: bytes32(uint256(0xCAFE)),
            creator: creator,
            chamberId: 1,
            protocolTreasury: protocolTreasury,
            winnersSplitter: address(0), // defaults to creator
            forPool: forPool,
            againstPool: againstPool,
            executorPool: executorPool,
            bps: [uint16(1500), uint16(1500), uint16(1000), uint16(2500), uint16(1000), uint16(2500)],
            pairedToken: paired,
            tickIfToken0IsClanker: -180_000,
            tickSpacing: 200,
            poolData: "",
            tickLower: tickLower,
            tickUpper: tickUpper,
            positionBps: positionBps,
            lockerData: "",
            mevModuleData: ""
        });
    }

    function test_DeployIdea_OnlyDeployerOrOwner() public {
        IdeaFactory.DeployParams memory p = _defaultParams();
        vm.prank(address(0xBADBEEF));
        vm.expectRevert(IdeaFactory.NotDeployer.selector);
        factory.deployIdea(p);
    }

    function test_DeployIdea_HappyPath_RegistersAndConfigures() public {
        IdeaFactory.DeployParams memory p = _defaultParams();
        vm.prank(relayer);
        address ideaToken = factory.deployIdea(p);
        assertTrue(ideaToken != address(0));

        // Registered in ChamberRegistry
        IChamberRegistry.IdeaMetadata memory idea = registry.getIdea(ideaToken);
        assertEq(idea.ticker, "FLASH");
        assertEq(idea.creator, creator);
        assertEq(idea.chamberId, 1);

        // FeeRouter configured
        assertTrue(router.isConfigured(ideaToken));
        (address[6] memory recipients, uint16[6] memory bps) = router.getConfig(ideaToken);
        assertEq(recipients[0], protocolTreasury);
        assertEq(recipients[1], creator);
        assertEq(recipients[2], creator); // winnersSplitter defaulted to creator
        assertEq(recipients[3], forPool);
        assertEq(recipients[4], againstPool);
        assertEq(recipients[5], executorPool);
        assertEq(bps[0], 1500);
    }

    function test_DeployIdea_InvalidBpsSum_Reverts() public {
        IdeaFactory.DeployParams memory p = _defaultParams();
        p.bps = [uint16(1500), uint16(1500), uint16(1000), uint16(2500), uint16(1000), uint16(1000)]; // 8500
        vm.prank(relayer);
        vm.expectRevert(abi.encodeWithSelector(IdeaFactory.InvalidBpsSum.selector, uint256(8500)));
        factory.deployIdea(p);
    }

    function test_DeployIdea_StoresMetadata() public {
        IdeaFactory.DeployParams memory p = _defaultParams();
        vm.prank(relayer);
        address ideaToken = factory.deployIdea(p);

        IdeaFactory.DeployInfo memory info = factory.getDeployInfo(ideaToken);
        assertEq(info.chamberId, 1);
        assertEq(info.creator, creator);
        assertEq(info.deployedAt, block.timestamp);
        assertEq(factory.deployedIdeaCount(), 1);
    }

    function test_DeployIdea_WinnersSplitterExplicitlySet() public {
        IdeaFactory.DeployParams memory p = _defaultParams();
        address explicitSplitter = address(0xD00D);
        p.winnersSplitter = explicitSplitter;
        vm.prank(relayer);
        address ideaToken = factory.deployIdea(p);
        (address[6] memory recipients,) = router.getConfig(ideaToken);
        assertEq(recipients[2], explicitSplitter);
    }

    function test_SetDeployer_OnlyOwner() public {
        vm.prank(address(0xBADBEEF));
        vm.expectRevert(); // Ownable: caller is not the owner
        factory.setDeployer(address(0x999));
    }

    function test_SetDeployer_Works() public {
        address newRelayer = address(0xBE2);
        vm.prank(owner);
        factory.setDeployer(newRelayer);
        assertEq(factory.deployer(), newRelayer);
    }

    function test_DeployIdea_RegistryAndRouterRejectIfNotWired() public {
        // Deploy a NEW factory whose registry/router don't have it set as factory yet
        vm.prank(owner);
        ChamberRegistry orphanRegistry = new ChamberRegistry(owner);
        vm.prank(owner);
        FeeRouter orphanRouter = new FeeRouter(owner);
        vm.prank(owner);
        IdeaFactory orphanFactory = new IdeaFactory(
            owner,
            IClanker(address(clanker)),
            IChamberRegistry(address(orphanRegistry)),
            IFeeRouter(address(orphanRouter)),
            hook,
            locker,
            mevModule
        );
        vm.prank(owner);
        orphanFactory.setDeployer(relayer);

        IdeaFactory.DeployParams memory p = _defaultParams();
        vm.prank(relayer);
        vm.expectRevert(ChamberRegistry.NotFactory.selector);
        orphanFactory.deployIdea(p);
    }
}

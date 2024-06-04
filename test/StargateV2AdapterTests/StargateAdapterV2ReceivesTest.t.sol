// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;

import {SushiXSwapV2} from "../../src/SushiXSwapV2.sol";
import {StargateV2Adapter} from "../../src/adapters/StargateV2Adapter.sol";
import {AirdropPayloadExecutor} from "../../src/payload-executors/AirdropPayloadExecutor.sol";
import {ISushiXSwapV2} from "../../src/interfaces/ISushiXSwapV2.sol";
import {ISushiXSwapV2Adapter} from "../../src/interfaces/ISushiXSwapV2Adapter.sol";
import {IRouteProcessor} from "../../src/interfaces/IRouteProcessor.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IStargateFeeLibrary} from "../../src/interfaces/stargate/IStargateFeeLibrary.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../utils/BaseTest.sol";
import "../../utils/RouteProcessorHelper.sol";
import {OFTComposeMsgCodec} from "../../src/adapters/lib/layer-zero/OFTComposeMsgCodec.sol";

import {StdUtils} from "forge-std/StdUtils.sol";

contract StargateV2AdapterReceivesTest is BaseTest {
    using SafeERC20 for IERC20;

    SushiXSwapV2 public sushiXswap;
    StargateV2Adapter public stargateV2Adapter;
    AirdropPayloadExecutor public airdropExecutor;
    IRouteProcessor public routeProcessor;
    RouteProcessorHelper public routeProcessorHelper;

    address public stargatePoolUSDCAddress;
    address public stargatePoolUSDTAddress;
    address public stargatePoolNativeAddress;

    IWETH public weth;
    IERC20 public sushi;
    IERC20 public usdc;
    IERC20 public usdt;

    address constant NATIVE_ADDRESS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address public operator = address(0xbeef);
    address public owner = address(0x420);
    address public user = address(0x4201);

    uint32 public arbitrumEID = 30110;

    function setUp() public override {
        forkMainnet();
        super.setUp();

        weth = IWETH(constants.getAddress("mainnet.weth"));
        sushi = IERC20(constants.getAddress("mainnet.sushi"));
        usdc = IERC20(constants.getAddress("mainnet.usdc"));
        usdt = IERC20(constants.getAddress("mainnet.usdt"));

        vm.deal(address(operator), 100 ether);
        deal(address(weth), address(operator), 100 ether);
        deal(address(usdc), address(operator), 1 ether);
        deal(address(sushi), address(operator), 1000 ether);

        routeProcessor = IRouteProcessor(
            constants.getAddress("mainnet.routeProcessor")
        );
        routeProcessorHelper = new RouteProcessorHelper(
            constants.getAddress("mainnet.v2Factory"),
            constants.getAddress("mainnet.v3Factory"),
            address(routeProcessor),
            address(weth)
        );

        stargatePoolUSDCAddress = constants.getAddress(
            "mainnet.stargateV2PoolUSDC"
        );
        stargatePoolUSDTAddress = constants.getAddress(
            "mainnet.stargateV2PoolUSDT"
        );
        stargatePoolNativeAddress = constants.getAddress(
            "mainnet.stargateV2PoolNative"
        );

        vm.startPrank(owner);
        sushiXswap = new SushiXSwapV2(routeProcessor, address(weth));

        // add operator as privileged
        sushiXswap.setPrivileged(operator, true);

        // setup stargate adapter
        stargateV2Adapter = new StargateV2Adapter(
            constants.getAddress("mainnet.stargateV2Endpoint"),
            constants.getAddress("mainnet.stargateV2PoolNative"),
            constants.getAddress("mainnet.routeProcessor"),
            constants.getAddress("mainnet.weth")
        );
        sushiXswap.updateAdapterStatus(address(stargateV2Adapter), true);

        // deploy payload executors
        airdropExecutor = new AirdropPayloadExecutor();

        vm.stopPrank();
    }

    function test_RevertWhen_ReceivedCallFromNonStargateEndpoint() public {
        vm.prank(owner);
        vm.expectRevert();
        stargateV2Adapter.lzCompose{gas: 200000}(
            address(0),
            bytes32(0),
            "",
            address(0),
            ""
        );
    }

    // uint32 keeps max amount to ~4294 usdc
    function test_FuzzReceiveERC20AndSwapToERC20(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // receive 1 usdc and swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: amount,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            address(user), // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(
            weth.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 weth"
        );
        assertGt(weth.balanceOf(user), 0, "user should have > 0 weth");
    }

    function test_FuzzReceiveExtraERC20AndSwapToERC20UserReceivesExtra(uint32 amount) public {
        vm.assume(amount > 1000000 && amount < type(uint32).max); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount + 1); // amount adapter receives

        // receive 1 usdc and swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: amount,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            address(user), // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), 1, "user should have extra usdc");
        assertEq(
            weth.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 weth"
        );
        assertGt(weth.balanceOf(user), 0, "user should have > 0 weth");
    }

    function test_FuzzReceiveERC20AndSwapToUSDT(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // receive 1 usdc and swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(usdt),
            100,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: amount,
                tokenOut: address(usdt),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            address(user), // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(
            usdt.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 weth"
        );
        assertGt(usdt.balanceOf(user), 0, "user should have > 0 weth");
    }

    function test_FuzzReceiveUSDTAndSwapToERC20(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdt), address(stargateV2Adapter), amount); // amount adapter receives

        // receive 1 usdc and swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdt),
            address(weth),
            500,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdt),
                amountIn: amount,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            address(user), // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolUSDTAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdt.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdt.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(
            weth.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 weth"
        );
        assertGt(weth.balanceOf(user), 0, "user should have > 0 weth");
    }

    // uint64 keeps max amount to ~18 eth
    function test_FuzzReceiveNativeAndSwapToERC20(uint64 amount) public {
        vm.assume(amount > 0.1 ether);

        vm.deal(constants.getAddress("mainnet.stargateV2Endpoint"), amount); // amount for lzCompose

        // receive 1 usdc and swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRouteNativeIn(
            address(weth), // wrapToken
            false, // isV2
            address(usdc), // tokenOut
            500, // fee
            user // to
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: NATIVE_ADDRESS,
                amountIn: amount,
                tokenOut: address(usdc),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            address(user), // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        address(stargateV2Adapter).call{value: amount}("");
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolNativeAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertGt(usdc.balanceOf(user), 0, "user should have > 0 usdc");
        assertEq(
            weth.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 weth"
        );
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 eth"
        );
        assertEq(user.balance, 0, "user should have 0 eth");
    }

    function test_FuzzReceiveERC20AndDustSwaptoERC20(
        uint32 amount,
        uint64 dustAmount
    ) public {
        vm.assume(amount > 1000000); // > 1 usdc
        vm.assume(dustAmount > 0.001 ether);

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives
        vm.deal(constants.getAddress("mainnet.stargateV2Endpoint"), dustAmount); // dust for sgReceive

        // receive 1 usdc and swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: amount,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            address(user), // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        address(stargateV2Adapter).call{value: dustAmount}("");
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(
            weth.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 weth"
        );
        assertGt(weth.balanceOf(user), 0, "user should have > 0 weth");
        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 eth"
        );
        assertEq(user.balance, dustAmount, "user should have all the dust");
    }

    function test_FuzzReceiveNativeAndDustSwaptoERC20(
        uint64 amount,
        uint64 dustAmount
    ) public {
        amount = uint64(bound(amount, 0.1 ether, 10 ether));
        dustAmount = uint64(bound(dustAmount, 0.001 ether, 0.1 ether));

        vm.deal(constants.getAddress("mainnet.stargateV2Endpoint"), amount + dustAmount); // amount for sgReceive

        // receive 1 usdc and swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRouteNativeIn(
            address(weth), // wrapToken
            false, // isV2
            address(usdc), // tokenOut
            500, // fee
            user // to
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: NATIVE_ADDRESS,
                amountIn: amount,
                tokenOut: address(usdc),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            address(user), // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        address(stargateV2Adapter).call{value: (amount + dustAmount)}("");
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolNativeAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertGt(usdc.balanceOf(user), 0, "user should have > 0 usdc");
        assertEq(
            weth.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 weth"
        );
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 eth"
        );
        assertEq(
            user.balance,
            dustAmount,
            "user should have dustAmount or greater of eth"
        );
    }

    // uint32 keeps max amount to ~4294 usdc
    function test_FuzzReceiveERC20NotEnoughGasForSwap(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // receive usdc and attempt swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: amount,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        stargateV2Adapter.lzCompose{gas: 90000}(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should have all the usdc");
        assertEq(
            weth.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 weth"
        );
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
    }

    function test_FuzzReceiveUSDTNotEnoughGasForSwap(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdt

        deal(address(usdt), address(stargateV2Adapter), amount); // amount adapter receives

        // receive usdc and attempt swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdt),
            address(weth),
            500,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdt),
                amountIn: amount,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        stargateV2Adapter.lzCompose{gas: 90000}(
            stargatePoolUSDTAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdt.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdt.balanceOf(user), amount, "user should have all the usdt");
        assertEq(
            weth.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 weth"
        );
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
    }

    function test_FuzzReceiveNativeNotEnoughGasForSwap(uint64 amount) public {
        vm.assume(amount > 0.1 ether);

        vm.deal(constants.getAddress("mainnet.stargateV2Endpoint"), amount); // amount for lzCompose

        // receive native (sgETH) and attempt swap to usdc
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(weth),
                amountIn: amount,
                tokenOut: address(usdc),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        address(stargateV2Adapter).call{value: amount}("");
        stargateV2Adapter.lzCompose{gas: 90000}(
            stargatePoolNativeAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 eth"
        );
        assertEq(user.balance, amount, "user should have all the eth");
    }

    function test_FuzzReceiveERC20AndDustNotEnoughGasForSwap(
        uint32 amount,
        uint64 dustAmount
    ) public {
        vm.assume(amount > 1000000); // > 1 usdc
        vm.assume(dustAmount > 0.001 ether);

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives
        vm.deal(constants.getAddress("mainnet.stargateV2Endpoint"), dustAmount); // dust for sgReceive

        // receive usdc & dust and attempt to swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: amount,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        address(stargateV2Adapter).call{value: dustAmount}("");
        stargateV2Adapter.lzCompose{gas: 90000}(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should have all the usdc");
        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 eth"
        );
        assertEq(user.balance, dustAmount, "user should have all the dust");
    }

    function test_FuzzReceiveERC20EnoughForGasNoSwapOrPayloadData(
        uint32 amount
    ) public {
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // no swap data, payload empty
        bytes memory payload = abi.encode(
            user, // to
            "", // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        stargateV2Adapter.lzCompose{gas: 200000}(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should have all the usdc");
    }

    function test_FuzzReceiveUSDTEnoughForGasNoSwapOrPayloadData(
        uint32 amount
    ) public {
        vm.assume(amount > 1000000); // > 1 usdt

        deal(address(usdt), address(stargateV2Adapter), amount); // amount adapter receives

        // no swap data, payload empty
        bytes memory payload = abi.encode(
            user, // to
            "", // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        stargateV2Adapter.lzCompose{gas: 200000}(
            stargatePoolUSDTAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdt.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdt"
        );
        assertEq(usdt.balanceOf(user), amount, "user should have all the usdt");
    }

    function test_FuzzReceiveNativeEnoughForGasNoSwapOrPayloadData(
        uint64 amount
    ) public {
        vm.assume(amount > 0.1 ether);

        vm.deal(constants.getAddress("mainnet.stargateV2Endpoint"), amount); // amount for lzCompose

        // no swap data, payload empty
        bytes memory payload = abi.encode(
            user, // to
            "", // _swapData
            "" // _payloadData
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        address(stargateV2Adapter).call{value: amount}("");
        stargateV2Adapter.lzCompose{gas: 200000}(
            stargatePoolNativeAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 eth"
        );
        assertEq(user.balance, amount, "user should have all the eth");
    }

    function test_FuzzReceiveERC20AndDustEnoughForGasNoSwapOrPayloadData(
        uint32 amount,
        uint64 dustAmount
    ) public {
        vm.assume(amount > 1000000); // > 1 usdc
        vm.assume(dustAmount > 0.1 ether);

        vm.deal(constants.getAddress("mainnet.stargateV2Endpoint"), dustAmount); // dust for sgReceive
        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // no swap data, payload empty
        bytes memory payload = abi.encode(
            user, // to
            "", // _swapData
            "" // _payloadData
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        address(stargateV2Adapter).call{value: dustAmount}("");
        stargateV2Adapter.lzCompose{gas: 200000}(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should have all the usdc");
        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 eth"
        );
        assertEq(user.balance, dustAmount, "user should have all the dust");
    }

    function test_FuzzReceiveERC20FailedSwap(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // switched tokenIn to weth, and tokenOut to usdc - should fail now on swap
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(weth),
            address(usdc),
            500,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(weth),
                amountIn: amount,
                tokenOut: address(usdc),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        stargateV2Adapter.lzCompose{gas: 200000}(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should have all the usdc");
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
    }

    function test_FuzzReceiveUSDTFailedSwap(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdt

        deal(address(usdt), address(stargateV2Adapter), amount); // amount adapter receives

        // receive usdc and attempt swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdt),
            address(weth),
            500,
            user
        );

        // switched tokenIn to weth, and tokenOut to usdc - should fail now on swap
        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(weth),
                amountIn: amount,
                tokenOut: address(usdt),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        stargateV2Adapter.lzCompose{gas: 200000}(
            stargatePoolUSDTAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdt.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdt.balanceOf(user), amount, "user should have all the usdc");
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
    }

    function test_FuzzReceiveERC20FailedSwapFromOutOfGas(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // receive usdc and attempt swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        // attempt swap from usdc to weth
        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: amount,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        stargateV2Adapter.lzCompose{gas: 120000}(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should have all the usdc");
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
    }

    function test_FuzzReceiveERC20AndDustFailedSwap(
        uint32 amount,
        uint64 dustAmount
    ) public {
        vm.assume(amount > 1000000); // > 1 usdc
        vm.assume(dustAmount > 0.1 ether);

        vm.deal(constants.getAddress("mainnet.stargateV2Endpoint"), dustAmount); // dust for sgReceive
        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // receive usdc and attempt swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        // switched tokenIn to weth, and tokenOut to usdc - should fail now on swap
        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(weth),
                amountIn: amount,
                tokenOut: address(usdc),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        address(stargateV2Adapter).call{value: dustAmount}("");
        stargateV2Adapter.lzCompose{gas: 200000}(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should have all the usdc");
        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 eth"
        );
        assertEq(user.balance, dustAmount, "user should have all the dust");
    }

    function test_ReceiveERC20AndDustFailedSwapMinimumGasSent() public {
        uint32 amount = 1000001;
        uint64 dustAmount = 0.2 ether;
        vm.assume(amount > 1000000); // > 1 usdc
        vm.assume(dustAmount > 0.1 ether);

        vm.deal(constants.getAddress("mainnet.stargateV2Endpoint"), dustAmount); // dust for sgReceive
        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // receive usdc and attempt swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        // switched tokenIn to weth, and tokenOut to usdc - should fail now on swap
        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(weth),
                amountIn: amount,
                tokenOut: address(usdc),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        address(stargateV2Adapter).call{value: dustAmount}("");
        stargateV2Adapter.lzCompose{gas: 101570}(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should have all the usdc");
        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 eth"
        );
        assertEq(user.balance, dustAmount, "user should have all the dust");
    }

    function test_FuzzReceiveNativeFailedSwap(uint64 amount) public {
        vm.assume(amount > 0.1 ether);

        vm.deal(constants.getAddress("mainnet.stargateV2Endpoint"), amount); // amount for sgReceive

        // receive native (sgETH) and attempt swap to usdc
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(weth),
            address(usdc),
            500,
            user
        );

        // switched tokenIn to usdc, and tokenOut to weth - should fail now on swap
        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: amount,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        address(stargateV2Adapter).call{value: amount}("");
        stargateV2Adapter.lzCompose{gas: 200000}(
            stargatePoolNativeAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 eth"
        );
        assertEq(user.balance, amount, "user should have all the eth");
        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
    }

    function test_FuzzReceiveERC20FailSwapSlippageCheck(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // receive usdc and attempt swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        // attempt to swap usdc to weth with max amountOutMin
        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: amount,
                tokenOut: address(weth),
                amountOutMin: type(uint256).max, // abnormally high amountOutMin
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        stargateV2Adapter.lzCompose{gas: 200000}(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should have all the usdc");
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
    }

    function test_FuzzReceiveNativeFailSwapSlippageCheck(uint64 amount) public {
        vm.assume(amount > 0.1 ether);

        vm.deal(constants.getAddress("mainnet.stargateV2Endpoint"), amount); // amount for sgReceive

        // receive native (sgETH) and attempt swap to usdc
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(weth),
            address(usdc),
            500,
            user
        );

        // attempt to swap weth to usdc with max amount of amountOutMin
        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(weth),
                amountIn: amount,
                tokenOut: address(usdc),
                amountOutMin: type(uint256).max,
                to: user,
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        bytes memory payload = abi.encode(
            user, // to
            rpd_encoded, // _swapData
            "" // _payloadData
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        address(stargateV2Adapter).call{value: amount}("");
        stargateV2Adapter.lzCompose{gas: 200000}(
            stargatePoolNativeAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 eth"
        );
        assertEq(user.balance, amount, "user should have all the eth");
        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
    }

    function test_ReceiveERC20AndSwapToERC20AndAirdropERC20FromPayload()
        public
    {
        uint32 amount = 1000001;
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // receive 1 usdc and swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            address(airdropExecutor)
        );

        // airdrop all the weth to two addresses
        address user1 = address(0x4203);
        address user2 = address(0x4204);
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;

        bytes memory payload = abi.encode(
            address(user), // to
            abi.encode(
                IRouteProcessor.RouteProcessorData({
                    tokenIn: address(usdc),
                    amountIn: amount,
                    tokenOut: address(weth),
                    amountOutMin: 0,
                    to: address(airdropExecutor),
                    route: computedRoute
                })
            ), // swap data
            abi.encode(
                ISushiXSwapV2Adapter.PayloadData({
                    target: address(airdropExecutor),
                    gasLimit: 200000,
                    targetData: abi.encode(
                        AirdropPayloadExecutor.AirdropPayloadParams({
                            token: address(weth),
                            recipients: recipients
                        })
                    )
                })
            ) // payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(
            weth.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 weth"
        );
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
        assertGt(
            weth.balanceOf(user1),
            0,
            "user1 should have > 0 weth from airdrop"
        );
        assertGt(
            weth.balanceOf(user2),
            0,
            "user2 should have > 0 weth from airdrop"
        );
    }

    function test_ReceiveERC20AndSwapToUSDTAndAirdropUSDTFromPayload() public {
        uint32 amount = 1000001;
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // receive 1 usdc and swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(usdt),
            100,
            address(airdropExecutor)
        );

        // airdrop all the weth to two addresses
        address user1 = address(0x4203);
        address user2 = address(0x4204);
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;

        bytes memory payload = abi.encode(
            address(user), // to
            abi.encode(
                IRouteProcessor.RouteProcessorData({
                    tokenIn: address(usdc),
                    amountIn: amount,
                    tokenOut: address(usdt),
                    amountOutMin: 0,
                    to: address(airdropExecutor),
                    route: computedRoute
                })
            ), // swap data
            abi.encode(
                ISushiXSwapV2Adapter.PayloadData({
                    target: address(airdropExecutor),
                    gasLimit: 200000,
                    targetData: abi.encode(
                        AirdropPayloadExecutor.AirdropPayloadParams({
                            token: address(usdt),
                            recipients: recipients
                        })
                    )
                })
            ) // payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(
            usdt.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdt"
        );
        assertEq(usdt.balanceOf(user), 0, "user should have 0 usdt");
        assertGt(
            usdt.balanceOf(user1),
            0,
            "user1 should have > 0 usdt from airdrop"
        );
        assertGt(
            usdt.balanceOf(user2),
            0,
            "user2 should have > 0 usdt from airdrop"
        );
    }

    function test_ReceiveERC20AndSwapToERC20AndFailedAirdropERC20FromPayload()
        public
    {
        uint32 amount = 1000001;
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // receive 1 usdc and swap to weth
        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            address(airdropExecutor)
        );

        // airdrop all the weth to two addresses
        address user1 = address(0x4203);
        address user2 = address(0x4204);
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;

        bytes memory payload = abi.encode(
            address(user), // to
            abi.encode(
                IRouteProcessor.RouteProcessorData({
                    tokenIn: address(usdc),
                    amountIn: amount,
                    tokenOut: address(weth),
                    amountOutMin: 0,
                    to: address(airdropExecutor),
                    route: computedRoute
                })
            ), // swap data
            abi.encode(
                ISushiXSwapV2Adapter.PayloadData({
                    target: address(airdropExecutor),
                    gasLimit: 200000,
                    targetData: abi.encode(
                        AirdropPayloadExecutor.AirdropPayloadParams({
                            token: address(user), // using user for token to airdrop so it fails
                            recipients: recipients
                        })
                    )
                })
            ) // payloadData
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should have all usdc");
        assertEq(
            usdc.balanceOf(address(airdropExecutor)),
            0,
            "payload executor should have 0 usdc"
        );
        assertEq(
            weth.balanceOf(address(airdropExecutor)),
            0,
            "payload executor should have 0 weth"
        );
        assertEq(
            weth.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 weth"
        );
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
        assertEq(
            usdc.balanceOf(user1),
            0,
            "user1 should have 0 usdc from airdrop"
        );
        assertEq(
            usdc.balanceOf(user2),
            0,
            "user2 should have 0 usdc from airdrop"
        );
    }

    function test_ReceiveERC20AndAirdropFromPayload() public {
        uint32 amount = 1000001;
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // airdrop all the weth to two addresses
        address user1 = address(0x4203);
        address user2 = address(0x4204);
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;

        bytes memory payload = abi.encode(
            address(user), // to
            "", // swap data
            abi.encode(
                ISushiXSwapV2Adapter.PayloadData({
                    target: address(airdropExecutor),
                    gasLimit: 200000,
                    targetData: abi.encode(
                        AirdropPayloadExecutor.AirdropPayloadParams({
                            token: address(usdc),
                            recipients: recipients
                        })
                    )
                })
            ) // payload data
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertGt(
            usdc.balanceOf(user1),
            0,
            "user1 should have > 0 usdc from airdrop"
        );
        assertGt(
            usdc.balanceOf(user2),
            0,
            "user2 should have > 0 usdc from airdrop"
        );
    }

    function test_ReceiveUSDTAndAirdropFromPayload() public {
        uint32 amount = 1000001;
        vm.assume(amount > 1000000); // > 1 usdt

        deal(address(usdt), address(stargateV2Adapter), amount); // amount adapter receives

        // airdrop all the weth to two addresses
        address user1 = address(0x4203);
        address user2 = address(0x4204);
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;

        bytes memory payload = abi.encode(
            address(user), // to
            "", // swap data
            abi.encode(
                ISushiXSwapV2Adapter.PayloadData({
                    target: address(airdropExecutor),
                    gasLimit: 200000,
                    targetData: abi.encode(
                        AirdropPayloadExecutor.AirdropPayloadParams({
                            token: address(usdt),
                            recipients: recipients
                        })
                    )
                })
            ) // payload data
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolUSDTAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdt.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdt"
        );
        assertEq(usdt.balanceOf(user), 0, "user should have 0 usdt");
        assertGt(
            usdt.balanceOf(user1),
            0,
            "user1 should have > 0 usdt from airdrop"
        );
        assertGt(
            usdt.balanceOf(user2),
            0,
            "user2 should have > 0 usdt from airdrop"
        );
    }

    function test_ReceiveNativeAndAirdropFromPayload() public {
        uint64 amount = 1 ether;
        vm.assume(amount > 0.1 ether);

        vm.deal(address(stargateV2Adapter), amount);

        // airdrop all the weth to two addresses
        address user1 = address(0x4203);
        address user2 = address(0x4204);
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;

        bytes memory payload = abi.encode(
            address(user), // to
            "", // swap data
            abi.encode(
                ISushiXSwapV2Adapter.PayloadData({
                    target: address(airdropExecutor),
                    gasLimit: 200000,
                    targetData: abi.encode(
                        AirdropPayloadExecutor.AirdropPayloadParams({
                            token: NATIVE_ADDRESS,
                            recipients: recipients
                        })
                    )
                })
            ) // payload data
        );

        vm.startPrank(constants.getAddress("mainnet.stargateV2Endpoint"));
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolNativeAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter should have 0 native"
        );
        assertEq(user.balance, 0, "user should have 0 native");
        assertGt(user1.balance, 0, "user1 should have > 0 native from airdrop");
        assertGt(user2.balance, 0, "user2 should have > 0 native from airdrop");
    }

    function test_ReceiveERC20AndFailedAirdropFromPayload() public {
        uint32 amount = 1000001;
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // airdrop all the weth to two addresses
        address user1 = address(0x4203);
        address user2 = address(0x4204);
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;

        bytes memory payload = abi.encode(
            address(user), // to
            "", // swap data
            abi.encode(
                ISushiXSwapV2Adapter.PayloadData({
                    target: address(airdropExecutor),
                    gasLimit: 200000,
                    targetData: abi.encode(
                        AirdropPayloadExecutor.AirdropPayloadParams({
                            token: address(weth), // using weth for token to airdrop so it fails
                            recipients: recipients
                        })
                    )
                })
            ) // payload data
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        // auto sends enough gas, so no need to calculate gasNeeded & send here
        stargateV2Adapter.lzCompose(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should all usdc");
        assertEq(
            usdc.balanceOf(user1),
            0,
            "user1 should have 0 usdc from airdrop"
        );
        assertEq(
            usdc.balanceOf(user2),
            0,
            "user2 should have 0 usdc from airdrop"
        );
    }

    function test_ReceiveERC20AndFailedAirdropPayloadFromOutOfGas() public {
        uint32 amount = 1000001;
        vm.assume(amount > 1000000); // > 1 usdc

        deal(address(usdc), address(stargateV2Adapter), amount); // amount adapter receives

        // airdrop all the weth to two addresses
        address user1 = address(0x4203);
        address user2 = address(0x4204);
        address[] memory recipients = new address[](2);
        recipients[0] = user1;
        recipients[1] = user2;

        bytes memory payload = abi.encode(
            address(user), // to
            "", // swap data
            abi.encode(
                ISushiXSwapV2Adapter.PayloadData({
                    target: address(airdropExecutor),
                    gasLimit: 200000,
                    targetData: abi.encode(
                        AirdropPayloadExecutor.AirdropPayloadParams({
                            token: address(usdc),
                            recipients: recipients
                        })
                    )
                })
            ) // payload data
        );

        vm.prank(constants.getAddress("mainnet.stargateV2Endpoint"));
        stargateV2Adapter.lzCompose{gas: 120000}(
            stargatePoolUSDCAddress,
            bytes32(0),
            OFTComposeMsgCodec.encode(
                0,
                arbitrumEID,
                amount,
                abi.encodePacked(OFTComposeMsgCodec.addressToBytes32(user), payload)
            ),
            address(stargateV2Adapter),
            ""
        );

        assertEq(
            usdc.balanceOf(address(stargateV2Adapter)),
            0,
            "stargateV2Adapter should have 0 usdc"
        );
        assertEq(usdc.balanceOf(user), amount, "user should all usdc");
        assertEq(
            usdc.balanceOf(user1),
            0,
            "user1 should have 0 usdc from airdrop"
        );
        assertEq(
            usdc.balanceOf(user2),
            0,
            "user2 should have 0 usdc from airdrop"
        );
    }
}

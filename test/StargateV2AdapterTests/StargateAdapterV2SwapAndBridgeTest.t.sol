// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;

import {SushiXSwapV2} from "../../src/SushiXSwapV2.sol";
import {StargateV2Adapter, StargateTeleportParams} from "../../src/adapters/stargateV2Adapter.sol";
import {ISushiXSwapV2} from "../../src/interfaces/ISushiXSwapV2.sol";
import {IRouteProcessor} from "../../src/interfaces/IRouteProcessor.sol";
import {SendParam, MessagingFee, OFTReceipt} from "../../src/interfaces/layer-zero/IOFT.sol";
import {IStargate} from "../../src/interfaces/stargate-v2/IStargate.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../utils/BaseTest.sol";
import "../../utils/RouteProcessorHelper.sol";
import {OptionsBuilder} from "../../src/adapters/lib/layer-zero/OptionsBuilder.sol";

import {StdUtils} from "forge-std/StdUtils.sol";

contract stargateV2AdapterV2SwapAndBridgeTest is BaseTest {
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    SushiXSwapV2 public sushiXswap;
    StargateV2Adapter public stargateV2Adapter;
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

        vm.stopPrank();
    }

    function test_SwapFromERC20ToERC20AndBridge() public {
        uint64 amount = 1 ether;
        // basic swap 1 weth to usdc and bridge
        deal(address(weth), user, amount);
        vm.deal(user, 0.1 ether);

        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true, // rpHasToken
            false, // isV2
            address(weth), // tokenIn
            address(usdc), // tokenOut
            500, // fee
            address(stargateV2Adapter) // to
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(weth),
                amountIn: amount,
                tokenOut: address(usdc),
                amountOutMin: 0,
                to: address(stargateV2Adapter),
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(
            IStargate(stargatePoolUSDCAddress),
            SendParam({
                dstEid: arbitrumEID,
                to: addressToBytes32(user),
                amountLD: amount, // TODO: this isn't correct amount
                minAmountLD: amount,
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            })
        );

        vm.startPrank(user);
        IERC20(address(weth)).safeIncreaseAllowance(address(sushiXswap), amount);

        sushiXswap.swapAndBridge{value: messagingFee.nativeFee}(
            ISushiXSwapV2.BridgeParams({
                refId: 0x0000,
                adapter: address(stargateV2Adapter),
                tokenIn: address(weth),
                amountIn: amount,
                to: user,
                adapterData: abi.encode(StargateTeleportParams({
                    dstEid: arbitrumEID,
                    to: user,
                    receiver: address(stargateV2Adapter),
                    token: address(usdc),
                    amount: 0,
                    amountMin: 0,
                    stargate: IStargate(stargatePoolUSDCAddress),
                    messagingFee: messagingFee,
                    gas: 0
                }))
            }),
            user, // _refundAddress
            rpd_encoded, // _swapData
            "", // _swapPayload
            "" // _payloadData
        );

        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(usdc.balanceOf(address(sushiXswap)), 0, "xswap should have 0 usdc");
        assertEq(usdc.balanceOf(address(stargateV2Adapter)), 0, "stargateV2Adapter should have 0 usdc");
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
        assertEq(weth.balanceOf(address(sushiXswap)), 0, "xSwap should have 0 weth");
        assertEq(weth.balanceOf(address(stargateV2Adapter)), 0, "stargateV2Adapter should have 0 weth");
    }

    function test_SwapFromUSDTToERC20AndBridge(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdt
        
        deal(address(usdt), user, amount);
        vm.deal(user, 0.1 ether);

        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true, // rpHasToken
            false, // isV2
            address(usdt), // tokenIn
            address(usdc), // tokenOut
            100, // fee
            address(stargateV2Adapter) // to
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdt),
                amountIn: amount,
                tokenOut: address(usdc),
                amountOutMin: 0,
                to: address(stargateV2Adapter),
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(
            IStargate(stargatePoolUSDCAddress),
            SendParam({
                dstEid: arbitrumEID,
                to: addressToBytes32(user),
                amountLD: amount, // TODO: this isn't correct amount
                minAmountLD: amount,
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            })
        );
        
        vm.startPrank(user);
        IERC20(address(usdt)).safeIncreaseAllowance(address(sushiXswap), amount);

        sushiXswap.swapAndBridge{value: messagingFee.nativeFee}(
            ISushiXSwapV2.BridgeParams({
                refId: 0x0000,
                adapter: address(stargateV2Adapter),
                tokenIn: address(usdt),
                amountIn: amount,
                to: user,
                adapterData: abi.encode(StargateTeleportParams({
                    dstEid: arbitrumEID,
                    to: user,
                    receiver: address(stargateV2Adapter),
                    token: address(usdc),
                    amount: 0,
                    amountMin: 0,
                    stargate: IStargate(stargatePoolUSDCAddress),
                    messagingFee: messagingFee,
                    gas: 0
                }))
            }),
            user, // _refundAddress
            rpd_encoded, // _swapData
            "", // _swapPayload
            "" // _payloadData
        );

        assertEq(usdt.balanceOf(user), 0, "user should have 0 usdt");
        assertEq(usdt.balanceOf(address(sushiXswap)), 0, "xswap should have 0 usdt");
        assertEq(usdt.balanceOf(address(stargateV2Adapter)), 0, "stargateV2Adapter should have 0 usdt");
        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(usdc.balanceOf(address(sushiXswap)), 0, "xSwap should have 0 usdc");
        assertEq(usdc.balanceOf(address(stargateV2Adapter)), 0, "stargateV2Adapter should have 0 usdc");
    }

    function test_SwapFromERC20ToUSDTAndBridge(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdc
        
        deal(address(usdc), user, amount);
        vm.deal(user, 0.1 ether);

        bytes memory computedRoute = routeProcessorHelper.computeRoute(
            true, // rpHasToken
            false, // isV2
            address(usdc), // tokenIn
            address(usdt), // tokenOut
            100, // fee
            address(stargateV2Adapter) // to
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: amount,
                tokenOut: address(usdt),
                amountOutMin: 0,
                to: address(stargateV2Adapter),
                route: computedRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(
            IStargate(stargatePoolUSDCAddress),
            SendParam({
                dstEid: arbitrumEID,
                to: addressToBytes32(user),
                amountLD: amount, // TODO: this isn't correct amount
                minAmountLD: amount,
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            })
        );
        
        vm.startPrank(user);
        IERC20(address(usdc)).safeIncreaseAllowance(address(sushiXswap), amount);

        sushiXswap.swapAndBridge{value: messagingFee.nativeFee}(
            ISushiXSwapV2.BridgeParams({
                refId: 0x0000,
                adapter: address(stargateV2Adapter),
                tokenIn: address(usdc),
                amountIn: amount,
                to: user,
                adapterData: abi.encode(StargateTeleportParams({
                    dstEid: arbitrumEID,
                    to: user,
                    receiver: address(stargateV2Adapter),
                    token: address(usdt),
                    amount: 0,
                    amountMin: 0,
                    stargate: IStargate(stargatePoolUSDTAddress),
                    messagingFee: messagingFee,
                    gas: 0
                }))
            }),
            user, // _refundAddress
            rpd_encoded, // _swapData
            "", // _swapPayload
            "" // _payloadData
        );

        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(usdc.balanceOf(address(sushiXswap)), 0, "xswap should have 0 usdc");
        assertEq(usdc.balanceOf(address(stargateV2Adapter)), 0, "stargateV2Adapter should have 0 usdc");
        assertEq(usdt.balanceOf(user), 0, "user should have 0 usdt");
        assertEq(usdt.balanceOf(address(sushiXswap)), 0, "xSwap should have 0 usdt");
        assertEq(usdt.balanceOf(address(stargateV2Adapter)), 0, "stargateV2Adapter should have 0 usdt");
    }

    function test_SwapFromNativeToERC20AndBridge() public {
        uint64 amount = 1 ether;
        uint64 gasAmount = 0.2 ether;
        
        uint256 valueToSend = uint256(amount) + gasAmount;
        vm.deal(user, valueToSend);

        bytes memory computeRoute = routeProcessorHelper.computeRouteNativeIn(
            address(weth), // wrapToken
            false, // isV2
            address(usdc), // tokenOut
            500, // fee
            address(stargateV2Adapter) // to
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: NATIVE_ADDRESS,
                amountIn: amount,
                tokenOut: address(usdc),
                amountOutMin: 0,
                to: address(stargateV2Adapter),
                route: computeRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(
            IStargate(stargatePoolUSDCAddress),
            SendParam({
                dstEid: arbitrumEID,
                to: addressToBytes32(user),
                amountLD: amount, // TODO: this isn't correct amount
                minAmountLD: amount,
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            })
        );
        
        vm.startPrank(user);
        sushiXswap.swapAndBridge{value: uint256(amount) + messagingFee.nativeFee}(
            ISushiXSwapV2.BridgeParams({
                refId: 0x0000,
                adapter: address(stargateV2Adapter),
                tokenIn: NATIVE_ADDRESS,
                amountIn: amount,
                to: user,
                adapterData: abi.encode(StargateTeleportParams({
                    dstEid: arbitrumEID,
                    to: user,
                    receiver: address(stargateV2Adapter),
                    token: address(usdc),
                    amount: 0,
                    amountMin: 0,
                    stargate: IStargate(stargatePoolUSDCAddress),
                    messagingFee: messagingFee,
                    gas: 0
                }))
            }),
            user, // _refundAddress
            rpd_encoded, // _swapData
            "", // _swapPayload
            "" // _payloadData
        );

        assertGt(user.balance, 0, "user should have refund amount of native");
        assertLt(user.balance, gasAmount, "user should not have more than gas sent of native");
        assertEq(address(sushiXswap).balance, 0, "xswap should have 0 native");
        assertEq(address(stargateV2Adapter).balance, 0, "stargateV2Adapter should have 0 native");
        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(usdc.balanceOf(address(sushiXswap)), 0, "xSwap should have 0 usdc");
        assertEq(usdc.balanceOf(address(stargateV2Adapter)), 0, "stargateV2Adapter should have 0 usdc");
    }

    function test_SwapFromERC20ToWethAndBridge() public {
        uint32 amount = 1000000;
        // swap 1 usdc to eth and bridge
        deal(address(usdc), user, amount);
        vm.deal(user, 0.2 ether);

        bytes memory computeRoute = routeProcessorHelper.computeRoute(
            true, // rpHasToken
            false, // isV2
            address(usdc), // tokenIn
            address(weth), // tokenOut
            500, // fee
            address(stargateV2Adapter) // to
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: amount,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: address(stargateV2Adapter),
                route: computeRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(
            IStargate(stargatePoolUSDCAddress),
            SendParam({
                dstEid: arbitrumEID,
                to: addressToBytes32(user),
                amountLD: amount, // TODO: this isn't correct amount
                minAmountLD: amount,
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            })
        );

        vm.startPrank(user);
        IERC20(address(usdc)).safeIncreaseAllowance(address(sushiXswap), amount);

        sushiXswap.swapAndBridge{value: messagingFee.nativeFee}(
            ISushiXSwapV2.BridgeParams({
                refId: 0x0000,
                adapter: address(stargateV2Adapter),
                tokenIn: address(usdc),
                amountIn: amount,
                to: user,
                adapterData: abi.encode(StargateTeleportParams({
                    dstEid: arbitrumEID,
                    to: user,
                    receiver: address(stargateV2Adapter),
                    token: address(weth),
                    amount: 0,
                    amountMin: 0,
                    stargate: IStargate(stargatePoolNativeAddress),
                    messagingFee: messagingFee,
                    gas: 0
                }))
            }),
            user, // _refundAddress
            rpd_encoded, // _swapData
            "", // _swapPayload
            "" // _payloadData
        );

        assertEq(usdc.balanceOf(user), 0, "user should have 0 usdc");
        assertEq(usdc.balanceOf(address(sushiXswap)), 0, "xswap should have 0 usdc");
        assertEq(usdc.balanceOf(address(stargateV2Adapter)), 0, "stargateV2Adapter should have 0 usdc");
        assertEq(weth.balanceOf(user), 0, "user should have 0 weth");
        assertEq(weth.balanceOf(address(sushiXswap)), 0, "xSwap should have 0 weth");
        assertEq(weth.balanceOf(address(stargateV2Adapter)), 0, "stargateV2Adapter should have 0 weth");
    }

    function test_RevertWhen_SwapToNativeAndBridge() public {
        // swap 1 usdc to eth and bridge
        uint64 amount = 1 ether;

        deal(address(usdc), user, amount);
        vm.deal(user, 0.1 ether);

        bytes memory computeRoute = routeProcessorHelper.computeRouteNativeOut(
            true, // rpHasToken
            false, // isV2
            address(usdc), // tokenIn
            address(weth), // tokenOut
            500, // fee
            address(stargateV2Adapter) // to
        );

        IRouteProcessor.RouteProcessorData memory rpd = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: 1000000,
                tokenOut: NATIVE_ADDRESS,
                amountOutMin: 0,
                to: address(stargateV2Adapter),
                route: computeRoute
            });

        bytes memory rpd_encoded = abi.encode(rpd);

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(
            IStargate(stargatePoolUSDCAddress),
            SendParam({
                dstEid: arbitrumEID,
                to: addressToBytes32(user),
                amountLD: amount, // TODO: this isn't correct amount
                minAmountLD: amount,
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            })
        );

        vm.startPrank(user);
        IERC20(address(usdc)).safeIncreaseAllowance(address(sushiXswap), amount);

        vm.expectRevert(bytes4(keccak256("RpSentNativeIn()")));
        sushiXswap.swapAndBridge{value: messagingFee.nativeFee}(
            ISushiXSwapV2.BridgeParams({
                refId: 0x0000,
                adapter: address(stargateV2Adapter),
                tokenIn: address(usdc), // doesn't matter for bridge params with swapAndBridge
                amountIn: amount,
                to: user,
                adapterData: abi.encode(StargateTeleportParams({
                    dstEid: arbitrumEID,
                    to: user,
                    receiver: address(stargateV2Adapter),
                    token: NATIVE_ADDRESS,
                    amount: 0,
                    amountMin: 0,
                    stargate: IStargate(stargatePoolNativeAddress),
                    messagingFee: messagingFee,
                    gas: 0
                })) 
            }),
            user, // _refundAddress
            rpd_encoded, // _swapData
            "", // _swapPayload
            "" // _payloadData
        );
    }
}

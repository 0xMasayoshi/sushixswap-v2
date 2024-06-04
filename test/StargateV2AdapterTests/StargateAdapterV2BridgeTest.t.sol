// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.0;

import {SushiXSwapV2} from "../../src/SushiXSwapV2.sol";
import {StargateV2Adapter, StargateTeleportParams} from "../../src/adapters/StargateV2Adapter.sol";
import {ISushiXSwapV2} from "../../src/interfaces/ISushiXSwapV2.sol";
import {IRouteProcessor} from "../../src/interfaces/IRouteProcessor.sol";
import {SendParam, MessagingFee, OFTReceipt} from "../../src/interfaces/layer-zero/IOFT.sol";
import {IStargate} from "../../src/interfaces/stargate-v2/IStargate.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../utils/BaseTest.sol";
import "../../utils/RouteProcessorHelper.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {OptionsBuilder} from "../../src/adapters/lib/layer-zero/OptionsBuilder.sol";

import {StdUtils} from "forge-std/StdUtils.sol";

contract StargateV2AdapterBridgeTest is BaseTest {
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

    // uint32 keeps it max amount to ~4294 usdc
    function testFuzz_BridgeERC20(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdc

        vm.deal(user, 1 ether);
        deal(address(usdc), user, amount);

        // basic usdc bridge
        vm.startPrank(user);
        usdc.approve(address(sushiXswap), amount);

        SendParam memory sendParam = SendParam({
            dstEid: arbitrumEID,
            to: addressToBytes32(user),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(IStargate(stargatePoolUSDCAddress), sendParam);

        (, , OFTReceipt memory receipt) = IStargate(stargatePoolUSDCAddress).quoteOFT(sendParam);

        uint256 amountMin = receipt.amountReceivedLD;
        receipt.amountReceivedLD = amountMin;

        vm.recordLogs();
        //todo: don't think we should be passing messagingFee as value
        sushiXswap.bridge{value: messagingFee.nativeFee}(
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
                    token: address(usdc),
                    amount: 0,
                    amountMin: amountMin,
                    stargate: IStargate(stargatePoolUSDCAddress),
                    messagingFee: messagingFee,
                    // sendParam: sendParam,
                    gas: 0
                }))
            }),
            user, // _refundAddress
            "", // _swapPayload
            "" // _payloadData
        );

        // check balances post call
        assertEq(
            usdc.balanceOf(address(sushiXswap)),
            0,
            "xswap usdc balance should be 0"
        );
        assertEq(usdc.balanceOf(user), 0, "user usdc balance should be 0");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].emitter == stargatePoolUSDCAddress) {
                assertEq(entries[i].topics.length, 3);
                assertEq(entries[i].topics[0], keccak256("OFTSent(bytes32,uint32,address,uint256,uint256)"));
                bytes32 fromAddress = entries[i].topics[2];
                (
                    uint32 dstEid, // Destination Endpoint ID.
                    uint256 amountSentLD, // Amount of tokens sent in local decimals.
                    uint256 amountReceivedLD // Amount of tokens received in local decimals.
                ) = abi.decode(
                    entries[i].data,
                    (
                        uint32,
                        uint256,
                        uint256   
                    )
                );

                assertEq(dstEid, arbitrumEID, "Swap event chainId should be 30110");
                assertEq(
                    fromAddress,
                    addressToBytes32(address(stargateV2Adapter)),
                    "Swap event fromAddress should be stargateV2Adapter"
                );
                assertEq(
                    amountSentLD,
                    amount,
                    "Swap event amountSentLD should be amount bridged"
                );
                assertEq(
                    amountReceivedLD,
                    amountMin,
                    "Swap event amountReceivedLD should be amountMin"
                );
                break;
            }
        }
    }

    function testFuzz_BridgeUSDT(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdt

        vm.deal(user, 1 ether);
        deal(address(usdt), user, amount);

        // basic usdc bridge
        vm.startPrank(user);
        usdt.forceApprove(address(sushiXswap), amount);

        SendParam memory sendParam = SendParam({
            dstEid: arbitrumEID,
            to: addressToBytes32(user),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(IStargate(stargatePoolUSDTAddress), sendParam);

        (, , OFTReceipt memory receipt) = IStargate(stargatePoolUSDTAddress).quoteOFT(sendParam);

        uint256 amountMin = receipt.amountReceivedLD;
        receipt.amountReceivedLD = amountMin;

        vm.recordLogs();
        //todo: don't think we should be passing messagingFee as value
        sushiXswap.bridge{value: messagingFee.nativeFee}(
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
                    token: address(usdt),
                    amount: amount,
                    amountMin: amountMin,
                    stargate: IStargate(stargatePoolUSDTAddress),
                    messagingFee: messagingFee,
                    gas: 0
                }))
            }),
            user, // _refundAddress
            "", // _swapPayload
            "" // _payloadData
        );

        // check balances post call
        assertEq(
            usdt.balanceOf(address(sushiXswap)),
            0,
            "xswap usdt balance should be 0"
        );
        assertEq(usdt.balanceOf(user), 0, "user usdt balance should be 0");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].emitter == stargatePoolUSDTAddress) {
                assertEq(entries[i].topics.length, 3);
                assertEq(entries[i].topics[0], keccak256("OFTSent(bytes32,uint32,address,uint256,uint256)"));
                bytes32 fromAddress = entries[i].topics[2];
                (
                    uint32 dstEid, // Destination Endpoint ID.
                    uint256 amountSentLD, // Amount of tokens sent in local decimals.
                    uint256 amountReceivedLD // Amount of tokens received in local decimals.
                ) = abi.decode(
                    entries[i].data,
                    (
                        uint32,
                        uint256,
                        uint256
                    )
                );

                assertEq(dstEid, arbitrumEID, "Swap event chainId should be 30110");
                assertEq(
                    fromAddress,
                    addressToBytes32(address(stargateV2Adapter)),
                    "Swap event fromAddress should be stargateV2Adapter"
                );
                assertEq(
                    amountSentLD,
                    amount,
                    "Swap event amountSentLD should be amount bridged"
                );
                assertEq(
                    amountReceivedLD,
                    amountMin,
                    "Swap event amountReceivedLD should be amountMin"
                );
                break;
            }
        }
    }

    // uint64 keeps it max amount to ~18 weth
    function testFuzz_BridgeWETH(uint64 amount) public {
        vm.assume(amount > 0.1 ether);

        vm.deal(user, 1 ether);
        deal(address(weth), user, amount);

        // basic usdc bridge
        vm.startPrank(user);
        IERC20(address(weth)).approve(address(sushiXswap), amount);

        SendParam memory sendParam = SendParam({
            dstEid: arbitrumEID,
            to: addressToBytes32(user),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(IStargate(stargatePoolNativeAddress), sendParam);

        (, , OFTReceipt memory receipt) = IStargate(stargatePoolNativeAddress).quoteOFT(sendParam);

        uint256 amountMin = receipt.amountReceivedLD;
        receipt.amountReceivedLD = amountMin;

        vm.recordLogs();
        //todo: don't think we should be passing messagingFee as value
        sushiXswap.bridge{value: messagingFee.nativeFee}(
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
                    token: address(weth),
                    amount: amount,
                    amountMin: amountMin,
                    stargate: IStargate(stargatePoolNativeAddress),
                    messagingFee: messagingFee,
                    gas: 0
                }))
            }),
            user, // _refundAddress
            "", // _swapPayload
            "" // _payloadData
        );

        // check balances post call
        assertEq(
            weth.balanceOf(address(sushiXswap)),
            0,
            "xswap weth balance should be 0"
        );
        assertEq(weth.balanceOf(user), 0, "user weth balance should be 0");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].emitter == stargatePoolNativeAddress) {
                assertEq(entries[i].topics.length, 3);
                assertEq(entries[i].topics[0], keccak256("OFTSent(bytes32,uint32,address,uint256,uint256)"));
                bytes32 fromAddress = entries[i].topics[2];
                (
                    uint32 dstEid, // Destination Endpoint ID.
                    uint256 amountSentLD, // Amount of tokens sent in local decimals.
                    uint256 amountReceivedLD // Amount of tokens received in local decimals.
                ) = abi.decode(
                    entries[i].data,
                    (
                        uint32,
                        uint256,
                        uint256
                    )
                );

                assertEq(dstEid, arbitrumEID, "Swap event chainId should be 30110");
                assertEq(
                    fromAddress,
                    addressToBytes32(address(stargateV2Adapter)),
                    "Swap event fromAddress should be stargateV2Adapter"
                );
                // StargatePoolNative.sharedDecimals is 6 on ETH -- can't use assertEq
                assertLe(
                    amountSentLD,
                    amount,
                    "Swap event amountSentLD should be <= amount bridged"
                );
                assertGe(
                    amountReceivedLD,
                    amountMin,
                    "Swap event amountReceivedLD should be >= amountMin"
                );
                break;
            }
        }
    }

    // uint64 keeps it max amount to ~18 eth
    function testFuzz_BridgeNative(uint64 amount) public {
        vm.assume(amount > 0.1 ether);

        SendParam memory sendParam = SendParam({
            dstEid: arbitrumEID,
            to: addressToBytes32(user),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(IStargate(stargatePoolNativeAddress), sendParam);

        (, , OFTReceipt memory receipt) = IStargate(stargatePoolNativeAddress).quoteOFT(sendParam);

        uint256 amountMin = receipt.amountReceivedLD;
        receipt.amountReceivedLD = amountMin;

        uint256 balanceBefore = operator.balance;
        vm.recordLogs();
        vm.startPrank(operator);
        uint256 gas_start = gasleft();
        //todo: don't think we should be passing messagingFee as value
        sushiXswap.bridge{value: messagingFee.nativeFee + amount}(
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
                    token: NATIVE_ADDRESS,
                    amount: amount,
                    amountMin: amountMin,
                    stargate: IStargate(stargatePoolNativeAddress),
                    messagingFee: messagingFee,
                    gas: 0
                }))
            }),
            user, // _refundAddress
            "", // _swapPayload
            "" // _payloadData
        );

        uint256 gas_used = gas_start - gasleft();

        // check balances post call
        assertEq(
            address(sushiXswap).balance,
            0,
            "xswap eth balance should be 0"
        );
        assertEq(
            address(stargateV2Adapter).balance,
            0,
            "stargateV2Adapter eth balance should be 0"
        );
        assertLe(
            operator.balance,
            balanceBefore - (messagingFee.nativeFee + amountMin) - gas_used,
            string(
                abi.encodePacked(
                    "operator balance should be lte ",
                    Strings.toString(
                        balanceBefore - (messagingFee.nativeFee + amountMin) - gas_used
                    )
                )
            )
        );
        assertGe(
            operator.balance,
            balanceBefore - (messagingFee.nativeFee + amount) - gas_used,
            string(
                abi.encodePacked(
                    "operator balance should be gte ",
                    Strings.toString(
                        balanceBefore - (messagingFee.nativeFee + amount) - gas_used
                    )
                )
            )
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].emitter == stargatePoolNativeAddress) {
                assertEq(entries[i].topics.length, 3);
                assertEq(entries[i].topics[0], keccak256("OFTSent(bytes32,uint32,address,uint256,uint256)"));
                bytes32 fromAddress = entries[i].topics[2];
                (
                    uint32 dstEid, // Destination Endpoint ID.
                    uint256 amountSentLD, // Amount of tokens sent in local decimals.
                    uint256 amountReceivedLD // Amount of tokens received in local decimals.
                ) = abi.decode(
                    entries[i].data,
                    (
                        uint32,
                        uint256,
                        uint256
                    )
                );

                assertEq(dstEid, arbitrumEID, "Swap event chainId should be 30110");
                assertEq(
                    fromAddress,
                    addressToBytes32(address(stargateV2Adapter)),
                    "Swap event fromAddress should be stargateV2Adapter"
                );
                assertLe(
                    amountSentLD,
                    amount,
                    "Swap event amountSentLD should be <= amount bridged"
                );
                assertGe(
                    amountReceivedLD,
                    amountMin,
                    "Swap event amountReceivedLD should be >= amountMin"
                );
                break;
            }
        }
    }

    // uint32 keeps it max amount to ~4294 usdc
    function testFuzz_BridgeERC20WithSwapData(uint32 amount) public {
        vm.assume(amount > 1000000); // > 1 usdc

        vm.deal(user, 1 ether);
        deal(address(usdc), user, amount);

        // basic usdc bridge
        vm.startPrank(user);
        usdc.approve(address(sushiXswap), amount);

        // this should use arbitrum addresses, but for simplicity we will use mainnet ones
        bytes memory computedRoute_dst = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd_dst = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: 0,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: user,
                route: computedRoute_dst
            });

        bytes memory rpd_encoded_dst = abi.encode(rpd_dst);

        SendParam memory sendParam = SendParam({
            dstEid: arbitrumEID,
            to: addressToBytes32(address(sushiXswap)),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzComposeOption(0, 200_000, 0), // compose gas limit
            composeMsg: abi.encode(
                address(user), // to
                rpd_encoded_dst, // _swapData
                "" // _payloadData
            ),
            oftCmd: ""
        });

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(IStargate(stargatePoolUSDCAddress), sendParam);

        {
            (, , OFTReceipt memory receipt) = IStargate(stargatePoolUSDCAddress).quoteOFT(sendParam);
            sendParam.minAmountLD = receipt.amountReceivedLD;
        }
        uint256 amountMin = sendParam.minAmountLD;

        vm.recordLogs();
        //todo: don't think we should be passing messagingFee as value
        sushiXswap.bridge{value: messagingFee.nativeFee}(
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
                    token: address(usdc),
                    amount: amount,
                    amountMin: amountMin,
                    stargate: IStargate(stargatePoolUSDCAddress),
                    messagingFee: messagingFee,
                    gas: 200_000
                }))
            }),
            user, // _refundAddress
            rpd_encoded_dst, // _swapPayload
            "" // _payloadData
        );

        // check balances post call
        assertEq(
            usdc.balanceOf(address(sushiXswap)),
            0,
            "xswap usdc balance should be 0"
        );
        assertEq(usdc.balanceOf(user), 0, "user usdc balance should be 0");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint i = 0; i < entries.length; i++) {
            if (entries[i].emitter == stargatePoolUSDCAddress) {
                assertEq(entries[i].topics.length, 3);
                assertEq(entries[i].topics[0], keccak256("OFTSent(bytes32,uint32,address,uint256,uint256)"));
                bytes32 fromAddress = entries[i].topics[2];
                (
                    uint32 dstEid, // Destination Endpoint ID.
                    uint256 amountSentLD, // Amount of tokens sent in local decimals.
                    uint256 amountReceivedLD // Amount of tokens received in local decimals.
                ) = abi.decode(
                    entries[i].data,
                    (
                        uint32,
                        uint256,
                        uint256   
                    )
                );

                assertEq(dstEid, arbitrumEID, "Swap event chainId should be 30110");
                assertEq(
                    fromAddress,
                    addressToBytes32(address(stargateV2Adapter)),
                    "Swap event fromAddress should be stargateV2Adapter"
                );
                assertEq(
                    amountSentLD,
                    amount,
                    "Swap event amountSentLD should be amount bridged"
                );
                assertEq(
                    amountReceivedLD,
                    amountMin,
                    "Swap event amountReceivedLD should be amountMin"
                );
                break;
            }
        }
    }

    function test_RevertWhen_BridgeWithSwapDataInsufficientGasPassed() public {
        uint32 amount = 1000000;

        vm.deal(user, 1 ether);
        deal(address(usdc), user, amount);

        // basic usdc bridge
        vm.startPrank(user);
        usdc.approve(address(sushiXswap), amount);

        // this should use arbitrum addresses, but for simplicity we will use mainnet ones
        bytes memory computedRoute_dst = routeProcessorHelper.computeRoute(
            true,
            false,
            address(usdc),
            address(weth),
            500,
            user
        );

        IRouteProcessor.RouteProcessorData memory rpd_dst = IRouteProcessor
            .RouteProcessorData({
                tokenIn: address(usdc),
                amountIn: 0,
                tokenOut: address(weth),
                amountOutMin: 0,
                to: user,
                route: computedRoute_dst
            });

        bytes memory rpd_encoded_dst = abi.encode(rpd_dst);

        bytes memory mockPayload = abi.encode(
            user, // to
            rpd_encoded_dst, // _swapData
            "" // _payloadData
        );

        uint128 insufficientGasForDst = 90000;


        SendParam memory sendParam = SendParam({
            dstEid: arbitrumEID,
            to: addressToBytes32(address(sushiXswap)),
            amountLD: amount,
            minAmountLD: amount,
            extraOptions: OptionsBuilder.newOptions().addExecutorLzComposeOption(0, insufficientGasForDst, 0), // compose gas limit
            composeMsg: mockPayload,
            oftCmd: ""
        });

        MessagingFee memory messagingFee = stargateV2Adapter.getFee(IStargate(stargatePoolUSDCAddress), sendParam);

        {
            (, , OFTReceipt memory receipt) = IStargate(stargatePoolUSDCAddress).quoteOFT(sendParam);
            sendParam.minAmountLD = receipt.amountReceivedLD;
        }

        uint256 amountMin = sendParam.minAmountLD;

        vm.expectRevert(bytes4(keccak256("InsufficientGas()")));
        sushiXswap.bridge{value: messagingFee.nativeFee}(
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
                    token: address(usdc),
                    amount: amount,
                    amountMin: amountMin,
                    stargate: IStargate(stargatePoolUSDCAddress),
                    messagingFee: messagingFee,
                    gas: insufficientGasForDst
                }))
            }),
            user, // _refundAddress
            rpd_encoded_dst, // _swapPayload
            "" // _payloadData
        );
    }
}

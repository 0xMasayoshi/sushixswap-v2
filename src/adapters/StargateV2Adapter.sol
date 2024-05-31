// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.10;

import {IRouteProcessor} from "../interfaces/IRouteProcessor.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {SafeERC20, IERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {OptionsBuilder} from "./lib/layer-zero/OptionsBuilder.sol";
import {IPayloadExecutor} from "../interfaces/IPayloadExecutor.sol";
import {ISushiXSwapV2Adapter} from "../interfaces/ISushiXSwapV2Adapter.sol";
// import {IStargateWidget} from "../interfaces/stargate/IStargateWidget.sol";
import {SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "../interfaces/layer-zero/IOFT.sol";
import {IStargate} from "../interfaces/stargate-v2/IStargate.sol";

import "forge-std/console.sol";

contract StargateV2Adapter is ISushiXSwapV2Adapter {
    using SafeERC20 for IERC20;
    using OptionsBuilder for bytes;

    address public immutable stargatePoolNative;
    IRouteProcessor public immutable rp;
    IWETH public immutable weth;

    address constant NATIVE_ADDRESS =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    struct StargateTeleportParams {
        uint32 dstEid; // Destination endpoint ID.
        address to; // Recipient address.
        address token; // input token
        uint256 amount; // Amount to send
        uint256 amountMin; // Minimum amount to send
        IStargate stargate; // stargate pool
        MessagingFee messagingFee; // stargate messaging fee [stargate.quoteSend]
        address receiver; // detination address for sgReceive
        uint128 gas; // extra gas to be sent for dst chain operations
    }

    error InsufficientGas();
    error NotStargateComposer();
    error RpSentNativeIn();

    constructor(
        address _stargatePoolNative,
        address _rp,
        address _weth
    ) {
        stargatePoolNative = _stargatePoolNative;
        rp = IRouteProcessor(_rp);
        weth = IWETH(_weth);
    }

    /// @inheritdoc ISushiXSwapV2Adapter
    function swap(
        uint256 _amountBridged,
        bytes calldata _swapData,
        address _token,
        bytes calldata _payloadData
    ) external payable override {
        IRouteProcessor.RouteProcessorData memory rpd = abi.decode(
            _swapData,
            (IRouteProcessor.RouteProcessorData)
        );

        // send tokens to RP
        if (_token != stargatePoolNative) {
            IERC20(rpd.tokenIn).safeTransfer(address(rp), _amountBridged);
        }

        rp.processRoute{value: _token == stargatePoolNative ? _amountBridged : 0}(
            rpd.tokenIn,
            _amountBridged,
            rpd.tokenOut,
            rpd.amountOutMin,
            rpd.to,
            rpd.route
        );

        // tokens should be sent via rp
        if (_payloadData.length > 0) {
            PayloadData memory pd = abi.decode(_payloadData, (PayloadData));
            try
                IPayloadExecutor(pd.target).onPayloadReceive{gas: pd.gasLimit}(
                    pd.targetData
                )
            {} catch (bytes memory) {
                revert();
            }
        }
    }

    /// @inheritdoc ISushiXSwapV2Adapter
    function executePayload(
        uint256 _amountBridged,
        bytes calldata _payloadData,
        address _token
    ) external payable override {
        PayloadData memory pd = abi.decode(_payloadData, (PayloadData));

        if (_token != stargatePoolNative) {
            IERC20(_token).safeTransfer(pd.target, _amountBridged);
        }

        IPayloadExecutor(pd.target).onPayloadReceive{
            gas: pd.gasLimit,
            value: _token == stargatePoolNative ? _amountBridged : 0
        }(pd.targetData);
    }

    /// @notice Get the fees to be paid in native token for the swap
    function getFee(
        IStargate _stargate,
        SendParam calldata _sendParam
    ) external view returns (MessagingFee memory) {
        return _stargate.quoteSend(_sendParam, false);
    }

    /// @inheritdoc ISushiXSwapV2Adapter
    function adapterBridge(
        bytes calldata _adapterData,
        address _refundAddress,
        bytes calldata _swapData,
        bytes calldata _payloadData
    ) external payable override {
        console.log('LFG');
        StargateTeleportParams memory params = abi.decode(
            _adapterData,
            (StargateTeleportParams)
        );

        if (params.token == NATIVE_ADDRESS) {
            // RP should not send native in, since we won't know the exact amount to bridge
            if (params.amount == 0) revert RpSentNativeIn();
        } else if (params.token == address(weth)) {
            // this case is for when rp sends weth in
            if (params.amount == 0)
                params.amount = weth.balanceOf(address(this));
            weth.withdraw(params.amount);
        } else {
            if (params.amount == 0)
                params.amount = IERC20(params.token).balanceOf(address(this));

            IERC20(params.token).forceApprove(
                address(params.stargate),
                params.amount
            );
        }

        bytes memory payload = bytes("");
        if (_swapData.length > 0 || _payloadData.length > 0) {
            /// @dev dst gas should be more than 100k
            if (params.gas < 100000) revert InsufficientGas();
            payload = abi.encode(params.to, _swapData, _payloadData);
        }

        params.stargate.sendToken{value: address(this).balance}(
            SendParam({
                dstEid: params.dstEid,
                to: bytes32(uint256(uint160(params.receiver))),
                amountLD: params.amount,
                minAmountLD: params.amountMin,
                // TODO: should this be calculated off-chain? how to do InsufficientGas check then?
                extraOptions: payload.length > 0 ? OptionsBuilder.newOptions().addExecutorLzComposeOption(0, params.gas, 0) : new bytes(0),
                composeMsg: payload,
                oftCmd: "" // use taxi
            }),
            params.messagingFee,
            _refundAddress
        );

        // TODO: is this needed?
        // stargateWidget.partnerSwap(0x0001);
    }

    /// @inheritdoc ISushiXSwapV2Adapter
    function sendMessage(bytes calldata _adapterData) external {
        (_adapterData);
        revert();
    }

    receive() external payable {}
}

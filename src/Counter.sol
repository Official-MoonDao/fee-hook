// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import "forge-std/console.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {StateView} from "v4-periphery/src/lens/StateView.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";


interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}


contract FeeHook is BaseHook, OApp {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    mapping(PoolId => mapping(address => uint256)) public totalWithdrawnPerUser;
    mapping(PoolId => uint256) public totalWithdrawn;
    uint256 public totalReceived;
    mapping(PoolId => uint256) public NATIVE_FEES;
    mapping(PoolId => uint256) public TOKEN_ID;

    IPositionManager posm;
    // FIXME increase this
    uint256 MIN_WITHDRAW = 0.0001 ether;
    uint256 destinationChainId;
    uint32 destinationEid; // LayerZero endpoint ID for the destination chain
    address public vMooneyAddress;



    constructor(IPoolManager _poolManager, IPositionManager _posm, address _lzEndpoint, uint256 _destinationChainId, uint32 _destinationEid, address _vMooneyAddress) BaseHook(_poolManager) OApp(_lzEndpoint, msg.sender) Ownable(msg.sender) {
        posm = _posm;
        destinationChainId = _destinationChainId;
        destinationEid = _destinationEid;
        vMooneyAddress = _vMooneyAddress;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata _params, BalanceDelta _delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (_params.zeroForOne && _params.amountSpecified > 0) {
            uint256 feeAmount = uint256(_params.amountSpecified) * uint256(key.fee) / 1e6;
            NATIVE_FEES[key.toId()] += feeAmount;
        }
        if (NATIVE_FEES[key.toId()] >= MIN_WITHDRAW) {
            bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
            bytes[] memory params = new bytes[](2);
            uint256 tokenId = TOKEN_ID[key.toId()];
            params[0] = abi.encode(tokenId, 0, 0, 0, bytes(""));
            params[1] = abi.encode(key.currency0, key.currency1, address(this));

            uint256 balance0Before = key.currency0.balanceOf(address(this));
            uint256 balance1Before = key.currency1.balanceOf(address(this));

            posm.modifyLiquiditiesWithoutUnlock(
                actions, params
            );

            uint256 balance0After = key.currency0.balanceOf(address(this));
            uint256 balance1After = key.currency1.balanceOf(address(this));
            uint256 contractETHBalance = address(this).balance;

            if (block.chainid != destinationChainId) {
                bytes memory payload = abi.encode();
                // Fee for messaging (assumed to be provided)
                uint256 messageFee = msg.value;
                uint256 totalAmount = address(this).balance;
                uint128 GAS_LIMIT = 500000;
                uint128 VALUE = uint128(address(this).balance);
                bytes memory options;
                OptionsBuilder.addExecutorLzReceiveOption(options, GAS_LIMIT, VALUE);

                _lzSend(
                    destinationEid,
                    payload,
                    options,
                    MessagingFee(msg.value, 0),
                    payable(msg.sender)
                );
            }

        }
        return (BaseHook.afterSwap.selector, 0);
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, BalanceDelta) {
        TOKEN_ID[key.toId()] = posm.nextTokenId() - 1;
        return (BaseHook.beforeAddLiquidity.selector, toBalanceDelta(0, 0));
    }

    function withdrawFees(PoolKey calldata key, address token) external {
        uint256 userBalance = IERC20(token).balanceOf(msg.sender);
        uint256 totalSupply = IERC20(token).totalSupply();
        uint256 userProportion = userBalance / totalSupply;
        uint256 withdrawn = totalWithdrawnPerUser[key.toId()][msg.sender];
        uint256 contractETHBalance = address(this).balance;
        console.log("contract balance", contractETHBalance);
        uint256 allocated = userProportion * (contractETHBalance + totalWithdrawn[key.toId()]);
        console.log("allocated", allocated);
        require(allocated <= withdrawn, "Nothing to withdraw");
        if (allocated == 0) {
            return;
        }
        uint256 withdrawable = allocated - withdrawn;
        // transfer eth
        totalWithdrawnPerUser[key.toId()][msg.sender] += withdrawable;
        totalWithdrawn[key.toId()] += withdrawable;
        transferETH(msg.sender, withdrawable);
    }

    function transferETH(address to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    receive() external payable {
        totalReceived += msg.value;
    }

    fallback() external payable {
        totalReceived += msg.value;
    }

    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata payload,
        address,  // Executor address as specified by the OApp.
        bytes calldata  // Any extra data or options to trigger on receipt.
    ) internal override {
        totalReceived += msg.value;
    }

}

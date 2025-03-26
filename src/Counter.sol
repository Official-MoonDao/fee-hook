// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import "forge-std/console.sol";

import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";

import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";


interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
}


contract Counter is BaseHook {
    using PoolIdLibrary for PoolKey;

    // NOTE: ---------------------------------------------------------
    // state variables should typically be unique to a pool
    // a single hook contract should be able to service multiple pools
    // ---------------------------------------------------------------

    mapping(PoolId => uint256 count) public beforeSwapCount;
    mapping(PoolId => uint256 count) public afterSwapCount;

    mapping(PoolId => uint256 count) public beforeAddLiquidityCount;
    mapping(PoolId => uint256 count) public beforeRemoveLiquidityCount;
    mapping(PoolId => mapping(address => uint256)) public totalWithdrawnPerUser;
    mapping(PoolId => uint256) public totalWithdrawn;

    IPositionManager posm;

    constructor(IPoolManager _poolManager, IPositionManager _posm) BaseHook(_poolManager) {
        posm = _posm;
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

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        beforeSwapCount[key.toId()]++;
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata _params, BalanceDelta _delta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        //(int128 amount0, int128 amount1) = (_delta.amount0(), _delta.amount1());
        //int128 swapAmount = _params.amountSpecified < 0 == _params.zeroForOne ? amount1 : amount0;
        //uint128 swapAmountPositive = uint128(swapAmount < 0 ? -swapAmount : swapAmount);
        //// define swap fee
        //// FIXME what should the swap fee be?
        //uint128 swapFee = swapAmountPositive * 1 / 10000000; // 0.3%

        //console.log("Swap fee: ", swapFee);
        //console.log("contract balance", address(this).balance);
        //poolManager.take(key.currency0, address(this), swapFee);
        //poolManager.take(key.currency0, address(this), 0);
        //poolManager.collect()
        return (BaseHook.afterSwap.selector, 0);
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        beforeAddLiquidityCount[key.toId()]++;
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        beforeRemoveLiquidityCount[key.toId()]++;
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function withdrawFees(uint256 tokenId, PoolKey calldata key, address token) external {
        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, 0, 0, 0, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        uint256 deadline = block.timestamp + 60;

        uint256 balance0Before = key.currency0.balanceOf(address(this));
        uint256 balance1Before = key.currency1.balanceOf(address(this));

        posm.modifyLiquidities(
            abi.encode(actions, params),
            deadline
        );

        uint256 balance0After = key.currency0.balanceOf(address(this));
        uint256 balance1After = key.currency1.balanceOf(address(this));
        console.log("change in balance0", balance0After - balance0Before);
        console.log("change in balance1", balance1After - balance1Before);


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
        console.log("withdrawable", withdrawable);
        //transferETH(msg.sender, withdrawable);
    }

    function transferETH(address to, uint256 amount) internal {
        (bool success, ) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    receive() external payable {
    // you can leave this empty or add some logic
    }

    fallback() external payable {
    }

}

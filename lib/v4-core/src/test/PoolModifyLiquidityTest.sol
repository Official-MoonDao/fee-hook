// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;
import "forge-std/console.sol";
import "forge-std/Script.sol";

import {CurrencyLibrary, Currency} from "../types/Currency.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {PoolTestBase} from "./PoolTestBase.sol";
import {IHooks} from "../interfaces/IHooks.sol";
import {Hooks} from "../libraries/Hooks.sol";
import {LPFeeLibrary} from "../libraries/LPFeeLibrary.sol";
import {CurrencySettler} from "../../test/utils/CurrencySettler.sol";
import {StateLibrary} from "../libraries/StateLibrary.sol";

contract PoolModifyLiquidityTest is PoolTestBase {
    using CurrencySettler for Currency;
    using Hooks for IHooks;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    constructor(IPoolManager _manager) PoolTestBase(_manager) {}

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
        bytes hookData;
        bool settleUsingBurn;
        bool takeClaims;
    }

    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta) {
        delta = modifyLiquidity(key, params, hookData, false, false);
    }

    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData,
        bool settleUsingBurn,
        bool takeClaims
    ) public payable returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, key, params, hookData, settleUsingBurn, takeClaims))),
            (BalanceDelta)
        );

        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) {
            CurrencyLibrary.ADDRESS_ZERO.transfer(msg.sender, ethBalance);
        }
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));

        CallbackData memory data = abi.decode(rawData, (CallbackData));

        (uint128 liquidityBefore,,) = manager.getPositionInfo(
            data.key.toId(), address(this), data.params.tickLower, data.params.tickUpper, data.params.salt
        );

        (BalanceDelta delta,) = manager.modifyLiquidity(data.key, data.params, data.hookData);

        (uint128 liquidityAfter,,) = manager.getPositionInfo(
            data.key.toId(), address(this), data.params.tickLower, data.params.tickUpper, data.params.salt
        );

        (,, int256 delta0) = _fetchBalances(data.key.currency0, data.sender, address(this));
        (,, int256 delta1) = _fetchBalances(data.key.currency1, data.sender, address(this));

        require(
            int128(liquidityBefore) + data.params.liquidityDelta == int128(liquidityAfter), "liquidity change incorrect"
        );

        if (data.params.liquidityDelta < 0) {
            assert(delta0 > 0 || delta1 > 0);
            assert(!(delta0 < 0 || delta1 < 0));
        } else if (data.params.liquidityDelta > 0) {
            assert(delta0 < 0 || delta1 < 0);
            assert(!(delta0 > 0 || delta1 > 0));
        }
        console.log('currency0', data.key.currency0.isAddressZero());
        console.log('delta0', delta0);
        console.log('delta1', delta1);

        if (delta0 < 0) data.key.currency0.settle(manager, data.sender, uint256(-delta0), data.settleUsingBurn);
        if (delta1 < 0) data.key.currency1.settle(manager, data.sender, uint256(-delta1), data.settleUsingBurn);
        if (delta0 > 0) data.key.currency0.take(manager, data.sender, uint256(delta0), data.takeClaims);
        if (delta1 > 0) data.key.currency1.take(manager, data.sender, uint256(delta1), data.takeClaims);

        return abi.encode(delta);
    }
}

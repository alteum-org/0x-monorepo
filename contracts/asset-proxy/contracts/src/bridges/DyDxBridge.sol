/*

  Copyright 2019 ZeroEx Intl.

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.

*/

pragma solidity ^0.5.9;
pragma experimental ABIEncoderV2;

import "@0x/contracts-erc20/contracts/src/interfaces/IERC20Token.sol";
import "@0x/contracts-erc20/contracts/src/LibERC20Token.sol";
import "@0x/contracts-exchange-libs/contracts/src/IWallet.sol";
import "../interfaces/IERC20Bridge.sol";
import "../interfaces/IDyDx.sol";
import "@0x/contracts-utils/contracts/src/DeploymentConstants.sol";


// solhint-disable space-after-comma
contract DyDxBridge is
    IERC20Bridge,
    IWallet,
    DeploymentConstants
{

    struct DyDxInfo {
        address accountOperator;
        address accountOwner;
        uint256 accountNumber;
        uint256 fromMarketId;
        uint256 toMarketId;
    }

    /// @dev Callback for `IERC20Bridge`.
    ///      Function Prerequisite:
    ///        1. Tokens are held in this contract that correspond to `DyDxInfo.fromMarketId`, and
    ///        2. Tokens are held in a DyDx account that corresponds to `DyDxInfo.toMarketId`
    ///           This account is owned by `from`.
    ///
    ///      When called, two actions take place:
    ///        1. The total balance held by this contract is deposited into the DyDx account (`DyDxInfo.fromMarketId`).
    ///        2. A portion of tokens (`amount`) from the DyDx account are withdrawn to `to` (`DyDxInfo.toMarketId`).
    ///
    ///      In the context of a 0x Trade:
    ///        1. The Maker owns a DyDx account and this bridge is set to the order's `makerAddress`.
    ///        2. The order's `takerAsset` corresponds to the `fromMarketId`;
    ///           the order's `makerAsset` corresponds to the `toMarketId`.
    ///        3. When the trade is executed on the 0x Exchange, the `takerAsset` is first transferred to this bridge
    ///           and then into the maker's DyDx account. (Step 1 above).
    ///        4. In return, the `makerAsset` is withdrawn from the maker's DyDx account and transferred to the taker.
    ///           (Step 2 above).
    ///
    /// @param toTokenAddress The token to give to `to`.
    /// @param to The recipient of the bought tokens.
    /// @param amount Minimum amount of `toTokenAddress` tokens to buy.
    /// @param bridgeData The abi-encoeded "from" token address.
    /// @return success The magic bytes if successful.
    function bridgeTransferFrom(
        address toTokenAddress,
        address /* from */,
        address to,
        uint256 amount,
        bytes calldata bridgeData
    )
        external
        returns (bytes4 success)
    {
        // Decode DyDx info from the bridge data.
        // This encapsulates an account owned by `from`, as well as
        // the tokens being exchanged by `from` and `to`.
        (DyDxInfo memory dydxInfo) = abi.decode(bridgeData, (DyDxInfo));

        // Cache dydx contract.
        IDyDx dydx = IDyDx(_getDyDxAddress());

        // Set allowance for this contract.
        address fromTokenAddress = dydx.getMarketTokenAddress(dydxInfo.fromMarketId);
        uint256 fromTokenAmount = IERC20Token(fromTokenAddress).balanceOf(address(this));
        LibERC20Token.approve(fromTokenAddress, address(dydx), uint256(-1));

        // Construct dydx account info.
        IDyDx.AccountInfo memory account = IDyDx.AccountInfo({
            owner: dydxInfo.accountOwner,
            number: dydxInfo.accountNumber
        });

        // Construct action to deposit tokens held by this contract into DyDx.
        IDyDx.AssetAmount memory amountToDeposit = IDyDx.AssetAmount({
            sign: true,                                 // true if positive.
            denomination: IDyDx.AssetDenomination.Wei,  // Wei => actual token amount held in account.
            ref: IDyDx.AssetReference.Target,           // Target => an absolute amount.
            value: fromTokenAmount                      // amount to deposit.
        });

        IDyDx.ActionArgs memory depositAction = IDyDx.ActionArgs({
            actionType: IDyDx.ActionType.Deposit,       // deposit tokens.
            amount: amountToDeposit,                    // amount to deposit.
            accountId: 0,                               // index in the `accounts` when calling `operate` below.
            primaryMarketId: dydxInfo.fromMarketId,     // indicates which token to deposit.
            otherAddress: address(this),                // despoit tokens from `this` address.
            // unused parameters
            secondaryMarketId: 0,
            otherAccountId: 0,
            data: hex''
        });

        // Construct action to withdraw tokens from dydx into `to`.
        IDyDx.AssetAmount memory amountToWithdraw = IDyDx.AssetAmount({
            sign: true,                                 // true if positive.
            denomination: IDyDx.AssetDenomination.Wei,  // Wei => actual token amount held in account.
            ref: IDyDx.AssetReference.Target,           // Target => an absolute amount.
            value: amount                               // amount to withdraw.
        });

        IDyDx.ActionArgs memory withdrawAction = IDyDx.ActionArgs({
            actionType: IDyDx.ActionType.Withdraw,      // withdraw tokens.
            amount: amountToWithdraw,                   // amount to withdraw.
            accountId: 0,                               // index in the `accounts` when calling `operate` below.
            primaryMarketId: dydxInfo.toMarketId,       // indicates which token to withdraw.
            otherAddress: to,                           // withdraw tokens to `to` address.
            // unused parameters
            secondaryMarketId: 0,
            otherAccountId: 0,
            data: hex''
        });

        // Construct arguments to `dydx.operate`.
        IDyDx.AccountInfo[] memory accounts = new IDyDx.AccountInfo[](1);
        accounts[0] = account;
        IDyDx.ActionArgs[] memory actions = new IDyDx.ActionArgs[](2);
        actions[0] = depositAction;
        actions[1] = withdrawAction;

        // Run operations. This will revert on failure.
        dydx.operate(accounts, actions);
        return BRIDGE_SUCCESS;
    }

    /// @dev `SignatureType.Wallet` callback, so that this bridge can be the maker
    ///      and sign for itself in orders. Always succeeds.
    /// @return magicValue Magic success bytes, always.
    function isValidSignature(
        bytes32,
        bytes calldata
    )
        external
        view
        returns (bytes4 magicValue)
    {
        return LEGACY_WALLET_MAGIC_VALUE;
    }
}

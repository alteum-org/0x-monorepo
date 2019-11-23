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
import "@0x/contracts-exchange-libs/contracts/src/LibOrder.sol";
import "@0x/contracts-utils/contracts/src/DeploymentConstants.sol";
import "@0x/contracts-utils/contracts/src/LibBytes.sol";
import "@0x/contracts-utils/contracts/src/Authorizable.sol";
import "../interfaces/IERC20Bridge.sol";
import "../interfaces/IDydx.sol";
import "../interfaces/IAssetData.sol";

// solhint-disable space-after-comma
contract DydxBridge is
    IERC20Bridge,
    DeploymentConstants,
    Authorizable
{

    using LibBytes for bytes;

    enum Action {
        Deposit,        // Deposit tokens into dydx account.
        Withdraw        // Withdraw tokens from dydx account.
    }

    struct BridgeData {
        Action action;
        address accountOwner;       // The owner of the dydx account.
        uint256 accountNumber;      // Account number used to identify the owner's specific account.
        uint256 marketId;           // Market to operate on.
    }

    /// @dev Callback for `IERC20Bridge`. Deposits or withdraws tokens from a dydx account.
    ///      Notes:
    ///         1. This bridge must be set as an operator of the dydx account that is being operated on.
    ///         2. This function may only be called in the context of the 0x Exchange executing an order
    ///            (ERC20Bridge is authorized).
    ///         3. The order must be signed by the owner or an operator of the dydx account.
    ///            This signature validated by the 0x Exchange.
    ///         4. The `from` address must be the maker (and hence is the owner or operator of the dydx account).
    /// @param from The sender of the tokens.
    /// @param to The recipient of the tokens.
    /// @param amount Minimum amount of `toTokenAddress` tokens to buy.
    /// @param encodedBridgeData An abi-encoded `BridgeData` struct.
    /// @return success The magic bytes if successful.
    function bridgeTransferFrom(
        address,
        address from,
        address to,
        uint256 amount,
        bytes calldata encodedBridgeData
    )
        external
        onlyAuthorized
        returns (bytes4 success)
    {
        // Decode bridge data.
        (BridgeData memory bridgeData) = abi.decode(encodedBridgeData, (BridgeData));

        // Cache dydx contract.
        IDydx dydx = IDydx(_getDydxAddress());

        // Assert that `from` is the owner or an operator of the dydx account.
        require(
            from == bridgeData.accountOwner || dydx.getIsLocalOperator(bridgeData.accountOwner, from),
            "INVALID_DYDX_OWNER_OR_OPERATOR"
        );

        // Construct dydx account info.
        IDydx.AccountInfo[] memory accounts = new IDydx.AccountInfo[](1);
        accounts[0] = IDydx.AccountInfo({
            owner: bridgeData.accountOwner,
            number: bridgeData.accountNumber
        });

        // Create dydx action.
        IDydx.ActionArgs[] memory actions;
        if (bridgeData.action == Action.Deposit) {
            actions[0] = _createDepositAction(
                from,
                amount,
                bridgeData
            );
        } else if (bridgeData.action == Action.Withdraw) {
            actions[0] = _createWithdrawAction(
                to,
                amount,
                bridgeData
            );
        } else {
            revert("UNRECOGNIZED_ACTION");
        }

        // Run operation. This will revert on failure.
        dydx.operate(accounts, actions);
        return BRIDGE_SUCCESS;
    }

    /// @dev Returns a dydx `DepositAction`.
    function _createDepositAction(
        address depositFrom,
        uint256 amount,
        BridgeData memory bridgeData
    )
        internal
        pure
        returns (IDydx.ActionArgs memory)
    {
        // Create dydx amount.
        IDydx.AssetAmount memory amountToDeposit = IDydx.AssetAmount({
            sign: true,                                 // true if positive.
            denomination: IDydx.AssetDenomination.Wei,  // Wei => actual token amount held in account.
            ref: IDydx.AssetReference.Target,           // Target => an absolute amount.
            value: amount                               // amount to deposit.
        });

        // Create dydx deposit action.
        IDydx.ActionArgs memory depositAction = IDydx.ActionArgs({
            actionType: IDydx.ActionType.Deposit,           // deposit tokens.
            amount: amountToDeposit,                        // amount to deposit.
            accountId: 0,                                   // index in the `accounts` when calling `operate`.
            primaryMarketId: bridgeData.marketId,           // indicates which token to deposit.
            otherAddress: depositFrom,                      // deposit from this address.
            // unused parameters
            secondaryMarketId: 0,
            otherAccountId: 0,
            data: hex''
        });

        return depositAction;
    }

    /// @dev Returns a dydx `WithdrawAction`.
    function _createWithdrawAction(
        address withdrawTo,
        uint256 amount,
        BridgeData memory bridgeData
    )
        internal
        pure
        returns (IDydx.ActionArgs memory)
    {
        // Create dydx amount.
        IDydx.AssetAmount memory amountToWithdraw = IDydx.AssetAmount({
            sign: true,                                     // true if positive.
            denomination: IDydx.AssetDenomination.Wei,      // Wei => actual token amount held in account.
            ref: IDydx.AssetReference.Target,               // Target => an absolute amount.
            value: amount                                   // amount to withdraw.
        });

        // Create withdraw action.
        IDydx.ActionArgs memory withdrawAction = IDydx.ActionArgs({
            actionType: IDydx.ActionType.Withdraw,          // withdraw tokens.
            amount: amountToWithdraw,                       // amount to withdraw.
            accountId: 0,                                   // index in the `accounts` when calling `operate`.
            primaryMarketId: bridgeData.marketId,           // indicates which token to withdraw.
            otherAddress: withdrawTo,                       // withdraw tokens to this address.
            // unused parameters
            secondaryMarketId: 0,
            otherAccountId: 0,
            data: hex''
        });

        return withdrawAction;
    }
}

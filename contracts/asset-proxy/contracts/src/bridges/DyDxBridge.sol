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
import "../interfaces/IERC20Bridge.sol";
import "../interfaces/IDyDx.sol";
import "../interfaces/IAssetData.sol";

// solhint-disable space-after-comma
contract DyDxBridge is
    IERC20Bridge,
    IWallet,
    DeploymentConstants
{

    using LibBytes for bytes;

    bytes4 constant VALID_SIGNATURE_RETURN_VALUE = bytes4(0x20c13b0b);
    bytes4 constant INVALID_SIGNATURE_RETURN_VALUE = bytes4(0);

    // OrderWithHash(LibOrder.Order order, bytes32 orderHash).selector
    // == bytes4(keccak256('OrderWithHash((address,address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,bytes,bytes,bytes,bytes),bytes32)'))
    bytes4 constant EIP1271_ORDER_WITH_HASH_SELECTOR = bytes4(0x3efe50c8);

    struct BridgeInfo {
        // Fields used by dydx
        address dydxAccountOwner;           // The owner of the dydx account.
        uint256 dydxAccountNumber;          // Account number used to identify the owner's specific account.
        address dydxAccountOperator;        // Optional. Operator of dydx account who signed the order.
        uint256 dydxFromMarketId;           //
        uint256 dydxToMarketId;
        // Fields used by bridge
        bool shouldDepositIntoDyDx;         // True iff contract balance should be deposited into DyDx account.
        address fromTokenAddress;           // The token given to `from` or deposited into the DyDx account.
    }

    /// @dev Callback for `IERC20Bridge`.
    ///      Function Prerequisite:
    ///        1. Tokens are held in this contract that correspond to `DyDxInfo.fromMarketId` (`fromTokenAddress`), and
    ///        2. Tokens are held in a DyDx account that corresponds to `DyDxInfo.toMarketId` (`toTokenAddress`)
    ///
    ///      When called, two actions take place:
    ///        1. The total balance held by this contract is deposited into the DyDx account OR transferred to `from`.
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
        address from,
        address to,
        uint256 amount,
        bytes calldata bridgeData
    )
        external
        returns (bytes4 success)
    {
        // Decode bridge data.
        (BridgeInfo memory bridgeInfo) = abi.decode(bridgeData, (BridgeInfo));

        // Cache dydx contract.
        IDyDx dydx = IDyDx(_getDyDxAddress());

        // Cache the balance held by this contract.
        IERC20Token fromToken = IERC20Token(bridgeInfo.fromTokenAddress);
        uint256 fromTokenAmount = fromToken.balanceOf(address(this));

        // Construct dydx account info.
        IDyDx.AccountInfo[] memory accounts = new IDyDx.AccountInfo[](1);
        accounts[0] = IDyDx.AccountInfo({
            owner: bridgeInfo.dydxAccountOwner,
            number: bridgeInfo.dydxAccountNumber
        });

        // Construct arguments to `dydx.operate`.
        IDyDx.ActionArgs[] memory actions;
        if (bridgeInfo.shouldDepositIntoDyDx) {
            // Generate deposit/withdraw actions
            actions = new IDyDx.ActionArgs[](2);
            actions[0] = _createDepositAction(bridgeInfo, fromTokenAmount);
            actions[1] = _createWithdrawAction(bridgeInfo, amount, to);

            // Allow DyDx to deposit `fromToken` from this contract.
            LibERC20Token.approve(
                bridgeInfo.fromTokenAddress,
                address(dydx),
                uint256(-1)
            );
        } else {
            // Generate withdraw action
            actions = new IDyDx.ActionArgs[](1);
            actions[0] = _createWithdrawAction(bridgeInfo, amount, to);

            // Transfer `fromToken` to `from`
            require(
                fromToken.transfer(from, fromTokenAmount),
                "TRANSFER_OF_FROM_TOKEN_FAILED"
            );
        }

        // Run operations. This will revert on failure.
        dydx.operate(accounts, actions);
        return BRIDGE_SUCCESS;
    }

    function _createDepositAction(
        BridgeInfo memory bridgeInfo,
        uint256 amount
    )
        internal
        view
        returns (IDyDx.ActionArgs memory)
    {
        // Construct action to deposit tokens held by this contract into DyDx.
        IDyDx.AssetAmount memory amountToDeposit = IDyDx.AssetAmount({
            sign: true,                                 // true if positive.
            denomination: IDyDx.AssetDenomination.Wei,  // Wei => actual token amount held in account.
            ref: IDyDx.AssetReference.Target,           // Target => an absolute amount.
            value: amount                               // amount to deposit.
        });

        IDyDx.ActionArgs memory depositAction = IDyDx.ActionArgs({
            actionType: IDyDx.ActionType.Deposit,           // deposit tokens.
            amount: amountToDeposit,                        // amount to deposit.
            accountId: 0,                                   // index in the `accounts` when calling `operate` below.
            primaryMarketId: bridgeInfo.dydxFromMarketId,   // indicates which token to deposit.
            otherAddress: address(this),                    // deposit tokens from `this` address.
            // unused parameters
            secondaryMarketId: 0,
            otherAccountId: 0,
            data: hex''
        });

        return depositAction;
    }

    function _createWithdrawAction(
        BridgeInfo memory bridgeInfo,
        uint256 amount,
        address to
    )
        internal
        view
        returns (IDyDx.ActionArgs memory)
    {
        // Construct action to withdraw tokens from dydx into `to`.
        IDyDx.AssetAmount memory amountToWithdraw = IDyDx.AssetAmount({
            sign: true,                                 // true if positive.
            denomination: IDyDx.AssetDenomination.Wei,  // Wei => actual token amount held in account.
            ref: IDyDx.AssetReference.Target,           // Target => an absolute amount.
            value: amount                               // amount to withdraw.
        });

        IDyDx.ActionArgs memory withdrawAction = IDyDx.ActionArgs({
            actionType: IDyDx.ActionType.Withdraw,          // withdraw tokens.
            amount: amountToWithdraw,                       // amount to withdraw.
            accountId: 0,                                   // index in the `accounts` when calling `operate` below.
            primaryMarketId: bridgeInfo.dydxToMarketId,     // indicates which token to withdraw.
            otherAddress: to,                               // withdraw tokens to `to` address.
            // unused parameters
            secondaryMarketId: 0,
            otherAccountId: 0,
            data: hex''
        });

        return withdrawAction;
    }

    /// @dev Given a 0x order where the `makerAssetData` corresponds to a DyDx transfer via this bridge,
    ///      `isValidSignature` verifies that the corresponding DyDx account owner (or operator)
    ///      has authorized the trade by signing the input order.
    /// @param data Signed tuple (ZeroExOrder, hash(ZeroExOrder))
    /// @param signature Proof that `data` has been signed.
    /// @return magicValue bytes4(0x20c13b0b) if the signature check succeeds.
    function isValidSignature(
        bytes calldata data,
        bytes calldata signature
    )
        external
        view
        returns (bytes4 magicValue)
    {
        // Assert that `data` is an encoded `OrderWithHash`.
        bytes4 dataType = data.readBytes4(0);
        require(
            dataType == EIP1271_ORDER_WITH_HASH_SELECTOR,
            "INVALID_DATA_EXPECTED_EIP1271_ORDER_WITH_HASH"
        );

        // Assert that signature is correct length.
        require(
            signature.length == 66,
            "INVALID_SIGNATURE_LENGTH"
        );

        // Decode the order and hash, plus extract the DyDxBridge asset data.
        (
            LibOrder.Order memory order,
            bytes32 orderHash
        ) = abi.decode(
                data.slice(4, data.length),
                (LibOrder.Order, bytes32)
        );

        bytes memory dydxBridgeAssetData = order.makerAssetData;

        // Decode and validate the asset proxy id.
        bytes4 assetProxyId = dydxBridgeAssetData.readBytes4(0);
        require(
            assetProxyId == IAssetData(address(0)).ERC20Bridge.selector,
            "MAKER_ASSET_DATA_NOT_ENCODED_FOR_ERC20_BRIDGE"
        );

        // Decode the ERC20 Bridge asset data.
        (
            address tokenAddress,
            address bridgeAddress,
            bytes memory bridgeData
        ) = abi.decode(
            dydxBridgeAssetData.slice(4, dydxBridgeAssetData.length),
            (address, address, bytes)
        );
        require(
            bridgeAddress == address(this),
            "INVALID_BRIDGE_ADDRESS"
        );

        // Decode and validate the `bridgeData` and extract the expected signer address.
        (BridgeInfo memory bridgeInfo) = abi.decode(bridgeData, (BridgeInfo));
        address signerAddress = bridgeInfo.dydxAccountOperator != address(0)
            ? bridgeInfo.dydxAccountOperator
            : bridgeInfo.dydxAccountOwner;

        // Validate signature.
        uint8 v = uint8(signature[0]);
        bytes32 r = signature.readBytes32(1);
        bytes32 s = signature.readBytes32(33);
        address recovered = ecrecover(
            orderHash,
            v,
            r,
            s
        );

        // Return `VALID_SIGNATURE_RETURN_VALUE` iff signature is valid.
        return (signerAddress == recovered)
            ? VALID_SIGNATURE_RETURN_VALUE
            : INVALID_SIGNATURE_RETURN_VALUE;
    }
}

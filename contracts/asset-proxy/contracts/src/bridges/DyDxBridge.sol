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

    bytes4 constant VALID_SIGNATURE_RETURN_VALUE = bytes4(0x20c13b0b);
    bytes4 constant INVALID_SIGNATURE_RETURN_VALUE = bytes4(0);

    // OrderWithHash(LibOrder.Order order, bytes32 orderHash).selector
    // == bytes4(keccak256('OrderWithHash((address,address,address,address,uint256,uint256,uint256,uint256,uint256,uint256,bytes,bytes,bytes,bytes),bytes32)'))
    bytes4 constant EIP1271_ORDER_WITH_HASH_SELECTOR = bytes4(0x3efe50c8);

    struct BridgeData {
        // Fields used by dydx
        address dydxAccountOwner;           // The owner of the dydx account.
        uint256 dydxAccountNumber;          // Account number used to identify the owner's specific account.
        address dydxAccountOperator;        // Optional. Operator of dydx account who signed the order.
        uint256 dydxFromMarketId;           //
        uint256 dydxToMarketId;
        // Fields used by bridge
        bool shouldDepositIntodydx;         // True iff contract balance should be deposited into dydx account.
        address fromTokenAddress;           // The token given to `from` or deposited into the dydx account.
    }

    /// @dev Callback for `IERC20Bridge`.
    ///      Function Prerequisite:
    ///        1. Tokens are held in this contract that correspond to `dydxInfo.fromMarketId` (`fromTokenAddress`), and
    ///        2. Tokens are held in a dydx account that corresponds to `dydxInfo.toMarketId` (`toTokenAddress`)
    ///
    ///      When called, two actions take place:
    ///        1. The total balance held by this contract is deposited into the dydx account OR transferred to `from`.
    ///        2. A portion of tokens (`amount`) from the dydx account are withdrawn to `to` (`dydxInfo.toMarketId`).
    ///
    ///      In the context of a 0x Trade:
    ///        1. The Maker owns a dydx account and this bridge is set to the order's `makerAddress`.
    ///        2. The order's `takerAsset` corresponds to the `fromMarketId`;
    ///           the order's `makerAsset` corresponds to the `toMarketId`.
    ///        3. When the trade is executed on the 0x Exchange, the `takerAsset` is first transferred to this bridge
    ///           and then into the maker's dydx account. (Step 1 above).
    ///        4. In return, the `makerAsset` is withdrawn from the maker's dydx account and transferred to the taker.
    ///           (Step 2 above).
    ///
    /// @param from The sender of the tokens.
    /// @param to The recipient of the tokens.
    /// @param amount Minimum amount of `toTokenAddress` tokens to buy.
    /// @param encodedBridgeData An abi-encoded `BridgeData` struct.
    /// @return success The magic bytes if successful.
    function bridgeTransferFrom(
        address /* toTokenAddress */,
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

        // Cache the balance held by this contract.
        IERC20Token fromToken = IERC20Token(bridgeData.fromTokenAddress);
        uint256 fromTokenAmount = fromToken.balanceOf(address(this));
        uint256 toTokenAmount = amount;

        // Construct dydx account info.
        IDydx.AccountInfo[] memory accounts = new IDydx.AccountInfo[](1);
        accounts[0] = IDydx.AccountInfo({
            owner: bridgeData.dydxAccountOwner,
            number: bridgeData.dydxAccountNumber
        });

        // Construct arguments to `dydx.operate`.
        IDydx.ActionArgs[] memory actions;
        if (bridgeData.shouldDepositIntodydx) {
            // Generate deposit/withdraw actions
            actions = new IDydx.ActionArgs[](2);
            actions[0] = _createDepositAction(
                address(this),                  // deposit `fromToken` into dydx from this contract.
                fromTokenAmount,                // amount to deposit.
                bridgeData                      // bridge data.
            );
            actions[1] = _createWithdrawAction(
                to,                             // withdraw `toToken` from dydx to `to`.
                toTokenAmount,                  // amount to withdraw.
                bridgeData                      // bridge data.
            );

            // Allow dydx to deposit `fromToken` from this contract.
            LibERC20Token.approve(
                bridgeData.fromTokenAddress,
                address(dydx),
                uint256(-1)
            );
        } else {
            // Generate withdraw action
            actions = new IDydx.ActionArgs[](1);
            actions[0] = _createWithdrawAction(to, toTokenAmount, bridgeData);

            // Transfer `fromToken` to `from`
            require(
                fromToken.transfer(from, fromTokenAmount),
                "TRANSFER_OF_FROM_TOKEN_FAILED"
            );
        }

        // Run operations. This will revert on failure.
        dydx.operate(accounts, actions);
        return /* BRIDGE_SUCCESS */ VALID_SIGNATURE_RETURN_VALUE;
    }

    function _createDepositAction(
        address depositFrom,
        uint256 amount,
        BridgeData memory bridgeData
    )
        internal
        pure
        returns (IDydx.ActionArgs memory)
    {
        // Construct action to deposit tokens held by this contract into dydx.
        IDydx.AssetAmount memory amountToDeposit = IDydx.AssetAmount({
            sign: true,                                 // true if positive.
            denomination: IDydx.AssetDenomination.Wei,  // Wei => actual token amount held in account.
            ref: IDydx.AssetReference.Target,           // Target => an absolute amount.
            value: amount                               // amount to deposit.
        });

        IDydx.ActionArgs memory depositAction = IDydx.ActionArgs({
            actionType: IDydx.ActionType.Deposit,           // deposit tokens.
            amount: amountToDeposit,                        // amount to deposit.
            accountId: 0,                                   // index in the `accounts` when calling `operate` below.
            primaryMarketId: bridgeData.dydxFromMarketId,   // indicates which token to deposit.
            otherAddress: depositFrom,                      // deposit tokens from `this` address.
            // unused parameters
            secondaryMarketId: 0,
            otherAccountId: 0,
            data: hex''
        });

        return depositAction;
    }

    function _createWithdrawAction(
        address withdrawTo,
        uint256 amount,
        BridgeData memory bridgeData
    )
        internal
        pure
        returns (IDydx.ActionArgs memory)
    {
        // Construct action to withdraw tokens from dydx into `to`.
        IDydx.AssetAmount memory amountToWithdraw = IDydx.AssetAmount({
            sign: true,                                 // true if positive.
            denomination: IDydx.AssetDenomination.Wei,  // Wei => actual token amount held in account.
            ref: IDydx.AssetReference.Target,           // Target => an absolute amount.
            value: amount                               // amount to withdraw.
        });

        IDydx.ActionArgs memory withdrawAction = IDydx.ActionArgs({
            actionType: IDydx.ActionType.Withdraw,          // withdraw tokens.
            amount: amountToWithdraw,                       // amount to withdraw.
            accountId: 0,                                   // index in the `accounts` when calling `operate` below.
            primaryMarketId: bridgeData.dydxToMarketId,     // indicates which token to withdraw.
            otherAddress: withdrawTo,                       // withdraw tokens to `to` address.
            // unused parameters
            secondaryMarketId: 0,
            otherAccountId: 0,
            data: hex''
        });

        return withdrawAction;
    }

    /// @dev Given a 0x order where the `makerAssetData` corresponds to a dydx transfer via this bridge,
    ///      `isValidSignature` verifies that the corresponding dydx account owner (or operator)
    ///      has authorized the trade by signing the input order.
    /// @param data Signed tuple (ZeroExOrder, hash(ZeroExOrder))
    /// @param signature Proof that `data` has been signed.
    /// @return bytes4(0x20c13b0b) if the signature check succeeds.
    function isValidSignature(
        bytes calldata data,
        bytes calldata signature
    )
        external
        view
        returns (bytes4)
    {
        // Assert that `data` is an encoded `OrderWithHash`.
        require(
            data.readBytes4(0) == EIP1271_ORDER_WITH_HASH_SELECTOR,
            "INVALID_DATA_EXPECTED_EIP1271_ORDER_WITH_HASH"
        );

        // Assert that signature is correct length.
        require(
            signature.length == 65,
            "INVALID_SIGNATURE_LENGTH"
        );

        // Decode the order and hash, plus extract the dydxBridge asset data.
        (
            LibOrder.Order memory order,
            bytes32 orderHash
        ) = abi.decode(
                data.slice(4, data.length),
                (LibOrder.Order, bytes32)
        );

        // Decode and validate the asset proxy id.
        require(
            order.makerAssetData.readBytes4(0) == IAssetData(address(0)).ERC20Bridge.selector,
            "MAKER_ASSET_DATA_NOT_ENCODED_FOR_ERC20_BRIDGE"
        );

        // Decode the ERC20 Bridge asset data.
        (
             /* address tokenAddress */,
            address bridgeAddress,
            bytes memory encodedBridgeData
        ) = abi.decode(
            order.makerAssetData.slice(4, order.makerAssetData.length),
            (address, address, bytes)
        );
        require(
            bridgeAddress == address(this),
            "INVALID_BRIDGE_ADDRESS"
        );

        // Decode and validate the `bridgeData` and extract the expected signer address.
        (BridgeData memory bridgeData) = abi.decode(encodedBridgeData, (BridgeData));
        address signerAddress = bridgeData.dydxAccountOperator != address(0)
            ? bridgeData.dydxAccountOperator
            : bridgeData.dydxAccountOwner;

        // Validate signature.
        address recovered = ecrecover(
            keccak256(abi.encodePacked(
                    "\x19Ethereum Signed Message:\n32",
                    orderHash
            )),
            uint8(signature[0]),        // v
            signature.readBytes32(1),   // r
            signature.readBytes32(33)   // s
        );

        // Return `VALID_SIGNATURE_RETURN_VALUE` iff signature is valid.
       return (signerAddress == recovered)
            ? VALID_SIGNATURE_RETURN_VALUE
            : INVALID_SIGNATURE_RETURN_VALUE;
    }
}

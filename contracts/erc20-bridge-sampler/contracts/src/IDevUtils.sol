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

import "@0x/contracts-exchange-libs/contracts/src/LibOrder.sol";


interface IDevUtils {

    /// @dev Fetches all order-relevant information needed to validate if the supplied orders are fillable.
    /// @param orders Array of order structures.
    /// @param signatures Array of signatures provided by makers that prove the authenticity of the orders.
    /// `0x01` can always be provided if a signature does not need to be validated.
    /// @return The ordersInfo (array of the hash, status, and `takerAssetAmount` already filled for each order),
    /// fillableTakerAssetAmounts (array of amounts for each order's `takerAssetAmount` that is fillable given all on-chain state),
    /// and isValidSignature (array containing the validity of each provided signature).
    /// NOTE: If the `takerAssetData` encodes data for multiple assets, each element of `fillableTakerAssetAmounts`
    /// will represent a "scaled" amount, meaning it must be multiplied by all the individual asset amounts within
    /// the `takerAssetData` to get the final amount of each asset that can be filled.
    function getOrderRelevantStates(LibOrder.Order[] calldata orders, bytes[] calldata signatures)
        external
        view
        returns (
            LibOrder.OrderInfo[] memory ordersInfo,
            uint256[] memory fillableTakerAssetAmounts,
            bool[] memory isValidSignature
        );
}

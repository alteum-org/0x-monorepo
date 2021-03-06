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

import "@0x/contracts-asset-proxy/contracts/src/bridges/UniswapBridge.sol";
import "@0x/contracts-asset-proxy/contracts/src/interfaces/IUniswapExchangeFactory.sol";
import "@0x/contracts-erc20/contracts/src/interfaces/IEtherToken.sol";


contract TestUniswapBridge is
    UniswapBridge
{
    // solhint-disable var-name-mixedcase
    address public TEST_WETH_ADDRESS;
    address public TEST_UNISWAP_EXCHANGE_FACTORY_ADDRESS;

    constructor (
        address testWeth,
        address testUniswapExchangeFactory
    )
        public
    {
        TEST_WETH_ADDRESS = testWeth;
        TEST_UNISWAP_EXCHANGE_FACTORY_ADDRESS = testUniswapExchangeFactory;
    }

    function getWethContract()
        public
        view
        returns (IEtherToken token)
    {
        return IEtherToken(TEST_WETH_ADDRESS);
    }

    function getUniswapExchangeFactoryContract()
        public
        view
        returns (IUniswapExchangeFactory factory)
    {
        return IUniswapExchangeFactory(TEST_UNISWAP_EXCHANGE_FACTORY_ADDRESS);
    }
}

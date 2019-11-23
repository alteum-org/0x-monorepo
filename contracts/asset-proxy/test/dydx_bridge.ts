import {
    blockchainTests,
    constants,
    expect,
    getRandomInteger,
    hexLeftPad,
    hexRandom,
    OrderFactory,
    orderHashUtils,
    randomAddress,
    verifyEventsFromLogs,
} from '@0x/contracts-test-utils';
import { AssetProxyId } from '@0x/types';
import { AbiEncoder, BigNumber } from '@0x/utils';
import { DecodedLogs } from 'ethereum-types';
import * as _ from 'lodash';
import * as ethUtil from 'ethereumjs-util';

import { artifacts } from './artifacts';

import { DydxBridgeContract, IAssetDataContract, TestDydxBridgeContract } from './wrappers';

blockchainTests.resets.only('Dydx unit tests', env => {
    const dydxAccountNumber = new BigNumber(1);
    const dydxFromMarketId = new BigNumber(2);
    const dydxToMarketId = new BigNumber(3);
    let testContract: DydxBridgeContract;
    let owner: string;
    let dydxAccountOwner: string;
    let bridgeDataEncoder: AbiEncoder.DataType;
    let eip1271Encoder: TestDydxBridgeContract;
    let assetDataEncoder: IAssetDataContract;
    let orderFactory: OrderFactory;

    before(async () => {
        // Deploy dydx bridge
        testContract = await DydxBridgeContract.deployFrom0xArtifactAsync(
            artifacts.DydxBridge,
            env.provider,
            env.txDefaults,
            artifacts,
        );

        // Get accounts
        const accounts = await env.web3Wrapper.getAvailableAddressesAsync();
        [owner, dydxAccountOwner] = accounts;
        const dydxAccountOwnerPrivateKey = constants.TESTRPC_PRIVATE_KEYS[accounts.indexOf(dydxAccountOwner)];

        // Create encoder for Bridge Data
        bridgeDataEncoder = AbiEncoder.create([
            {name: 'action', type: 'uint8'},
            {name: 'accountOwner', type: 'address'},
            {name: 'accountNumber', type: 'uint256'},
            {name: 'marketId', type: 'uint256'},
        ]);

        // Create encoders
        assetDataEncoder = new IAssetDataContract(constants.NULL_ADDRESS, env.provider);
    });
});

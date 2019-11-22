import { StakingPoolById, StoredBalance } from '@0x/contracts-staking';
import { expect } from '@0x/contracts-test-utils';
import { BigNumber, logUtils } from '@0x/utils';
import { TxData } from 'ethereum-types';

import { DeploymentManager } from '../deployment_manager';

import { FunctionAssertion, FunctionResult } from './function_assertion';

// tslint:disable:no-unnecessary-type-assertion

/**
 * Returns a FunctionAssertion for `createStakingPool` which assumes valid input is provided. The
 * FunctionAssertion checks that the new poolId is one more than the last poolId.
 */
export function validCreateStakingPoolAssertion(
    deployment: DeploymentManager,
    pools: StakingPoolById,
): FunctionAssertion<[number, boolean], string, string> {
    const { stakingWrapper } = deployment.staking;

    return new FunctionAssertion<[number, boolean], string, string>(stakingWrapper.createStakingPool, {
        // Returns the expected ID of th created pool
        before: async () => {
            const lastPoolId = await stakingWrapper.lastPoolId().callAsync();
            // Effectively the last poolId + 1, but as a bytestring
            return `0x${new BigNumber(lastPoolId)
                .plus(1)
                .toString(16)
                .padStart(64, '0')}`;
        },
        after: async (
            expectedPoolId: string,
            result: FunctionResult,
            args: {
                args: [number, boolean];
                txData: Partial<TxData>;
            },
        ) => {
            console.log(100);
            logUtils.log(`createStakingPool(${args.args[0]}, ${args.args[1]}) => ${expectedPoolId}`);
            console.log(101);

            // Checks the logs for the new poolId, verifies that it is as expected
            console.log(result.receipt);
            const log = result.receipt!.logs[0]; // tslint:disable-line:no-non-null-assertion
            console.log(102);
            const actualPoolId = (log as any).args.poolId;
            console.log(103);
            expect(actualPoolId).to.equal(expectedPoolId);
            console.log(104);

            // Adds the new pool to local state
            pools[actualPoolId] = {
                operator: args.txData.from as string,
                operatorShare: args.args[0],
                delegatedStake: new StoredBalance(),
            };
            console.log(105);
        },
    });
}

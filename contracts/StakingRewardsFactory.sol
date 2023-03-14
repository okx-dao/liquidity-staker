pragma solidity ^0.5.16;

import 'openzeppelin-solidity-2.3.0/contracts/token/ERC20/IERC20.sol';
import 'openzeppelin-solidity-2.3.0/contracts/ownership/Ownable.sol';

import './StakingRewards.sol';
/*
* StakingRewardsFactory就是为了创建多个质押池的一个工厂合约
* 质押池的奖代币为rewardsToken
* 创建质押池的过程为：举例给A代币构建质押池，质押奖励为rewardsToken，奖励总量为S
* 1. StakingRewardsFactory管理员调用deploy(A.address, S), 该过程会部署A代币对应的stakingRewards合约，用于质押和奖励发放
* 2. notifyRewardAmounts(), 会遍历质押代币数组，给所以质押代币对应的是takingRewards合约传入对应数量的奖励代币
* 3. notifyRewardAmount(stakingToken), 可以单独给指定代币进行奖励代币的转入
*/
contract StakingRewardsFactory is Ownable {
    // immutables
    // 奖励代币
    address public rewardsToken;
    // 激活质押奖励池合约的最早时间
    uint public stakingRewardsGenesis;

    // the staking tokens for which the rewards contract has been deployed
    // 拥有stakingRewards合约的代币，即可以被质押的代币数组
    address[] public stakingTokens;

    // info about rewards for a particular staking token
    struct StakingRewardsInfo {
        // stakingRewards合约地址
        address stakingRewards;
        // 总奖励代币数量
        uint rewardAmount;
    }

    // rewards info by staking token
    // 映射质押代币和stakingRewards合约以及奖励总量
    mapping(address => StakingRewardsInfo) public stakingRewardsInfoByStakingToken;

    constructor(
        address _rewardsToken,
        uint _stakingRewardsGenesis
    ) Ownable() public {
        require(_stakingRewardsGenesis >= block.timestamp, 'StakingRewardsFactory::constructor: genesis too soon');

        // 质押奖励代币
        rewardsToken = _rewardsToken;
        // 激活质押奖励池合约的最早时间
        stakingRewardsGenesis = _stakingRewardsGenesis;
    }

    ///// permissioned functions

    // deploy a staking reward contract for the staking token, and store the reward amount
    // the reward will be distributed to the staking reward contract no sooner than the genesis
    // 部署质押代币对应的stakingRewards合约
    function deploy(address stakingToken, uint rewardAmount) public onlyOwner {
        // 获取需要部署的质押代币的StakingRewardsInfo的一个storage引用，即修改后会被持久化到链上合约状态中
        StakingRewardsInfo storage info = stakingRewardsInfoByStakingToken[stakingToken];
        // 需要该质押代币对应的stakingRewards合约未被部署过
        require(info.stakingRewards == address(0), 'StakingRewardsFactory::deploy: already deployed');

        // 部署stakingRewards合约到链上
        info.stakingRewards = address(new StakingRewards(/*_rewardsDistribution=*/ address(this), rewardsToken, stakingToken));
        // 奖励代币的奖励总量
        info.rewardAmount = rewardAmount;
        // 把质押代币记录到stakingTokens数组中
        stakingTokens.push(stakingToken);
    }

    ///// permissionless functions

    // call notifyRewardAmount for all staking tokens.
    // 遍历stakingTokens数组，给每个质押代币的stakingRewards合约中转入对应数量(rewardAmount)的奖励代币，即激活质押奖励池
    function notifyRewardAmounts() public {
        // 确保stakingTokens数组不为空
        require(stakingTokens.length > 0, 'StakingRewardsFactory::notifyRewardAmounts: called before any deploys');
        // 遍历数组，执行notifyRewardAmount，进行奖励代币的转移
        for (uint i = 0; i < stakingTokens.length; i++) {
            notifyRewardAmount(stakingTokens[i]);
        }
    }

    // notify reward amount for an individual staking token.
    // this is a fallback in case the notifyRewardAmounts costs too much gas to call for all contracts
    // 单独给某一个质押代币进行转入对应数量的奖励代币
    function notifyRewardAmount(address stakingToken) public {
        // 需要确保当前时间在激活质押奖励池合约的最早时间之后
        require(block.timestamp >= stakingRewardsGenesis, 'StakingRewardsFactory::notifyRewardAmount: not ready');

        // 获取质押代币对应的StakingRewardsInfo的一个storage引用，方便修改后被持久化到链上合约状态中
        StakingRewardsInfo storage info = stakingRewardsInfoByStakingToken[stakingToken];
        // 需要确保质押代币对应的stakingRewards合约已被部署
        require(info.stakingRewards != address(0), 'StakingRewardsFactory::notifyRewardAmount: not deployed');

        if (info.rewardAmount > 0) {
            uint rewardAmount = info.rewardAmount;
            info.rewardAmount = 0;

            require(
            // 转移对应数量的奖励代币到stakingRewards合约中
                IERC20(rewardsToken).transfer(info.stakingRewards, rewardAmount),
                'StakingRewardsFactory::notifyRewardAmount: transfer failed'
            );
            // 调用stakingRewards合约，进行激活
            StakingRewards(info.stakingRewards).notifyRewardAmount(rewardAmount);
        }
    }
}
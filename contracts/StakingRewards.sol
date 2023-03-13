pragma solidity ^0.5.16;

import "openzeppelin-solidity-2.3.0/contracts/math/Math.sol";
import "openzeppelin-solidity-2.3.0/contracts/math/SafeMath.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/ERC20Detailed.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-solidity-2.3.0/contracts/utils/ReentrancyGuard.sol";

// Inheritance
import "./interfaces/IStakingRewards.sol";
import "./RewardsDistributionRecipient.sol";

/*
* StakingRewards用于特定质押代币进行质押和奖励发放
* RewardsDistributionRecipient：StakingRewardsFactory合约地址, 进行权限控制
* ReentrancyGuard：防止重入攻击
* 该池子工作原理：在固定时间内(rewardsDuration)，发送固定数量的奖励代币(getRewardForDuration)。
* 即：rewardsDuration为可被挖矿的总持续时间，能够挖到getRewardForDuration奖励代币，每秒种可被挖到的奖励代币数量为rewardRate
*（getRewardForDuration = rewardRate.mul(rewardsDuration);）

奖励计算公式推导：

a表示每秒钟的奖励
Pn表示第n秒钟开始的时候矿池的质押代币总量
FAn表示第n秒钟开始的时候用户A获得的总奖励
Tn表示第n秒钟开始的时候，累计的每质押代币可以分配的奖励之和，即:Tn = a / P1 + a / P2 + a / P3 + … + a / Pn

假设 用户A在第2秒钟开始的时候质押了b个质押代币，用户B在第4秒钟开始的时候质押了c个质押代币，那么第6秒钟开始的时候，用户A的奖励 :
FAn = (a/P1*0)+(a/P2*0)+(a/P3*b) + (a/P4*b) + (a/P5*b)+ (a/P6*b)
= b *（a/P3 + a/P4 + a/P5 + a/P6）
= b * ((a/P1 + a/P2 + a/P3 + a/P4 + a/P5 + a/P6) - (a/P1 + a/P2))
= b * (T6 - T2)
T6 表示 用户A在第6秒钟开始结算的时候，累积的每代币分配奖励之和
T2 表示 用户A在第2秒钟开始质押的时候，累积的每代币分配奖励之和
b 表示结算的时候用户A的总质押代币数量
所以，用户在结算的时候的奖励公式 = （结算的时候累计的每代币分配奖励之和 - 质押的时候累计的每代币分配奖励之和） * 结算的时候总质押代币数量 。
所以，如果某个用户在第m秒钟开始的时候质押b个质押代币，在第n秒钟开始的时候结算，那么公式
Fn = b * (Tn - Tm)

以上的公式只适用于用户A的质押代币数量没有变化的情况，如果用户A的质押代币数量增加（或减少）了呢，那要怎么计算？
假设 用户A在第2秒钟开始的时候质押了b个质押代币，用户B在第4秒钟开始的时候质押了c个质押代币，用户A又在第5秒钟开始的时候质押了d个质押代币，那么第6秒钟开始的时候，用户A的奖励 :
此时，用户A在结算时的质押代币数量我们用e表示，e=b+d

我们可以将用户A的两次质押：
第一次是：第2秒钟开始质押，第5秒钟开始结算，质押代币数量是b；
第二次是：第5秒钟开始质押（质押e - b），第6秒钟开始结算，质押代币数量是e。
F5 = b * (T5 - T2)
F6 = e * (T6 - T5)
总和 = F6 + F5 = e * (T6 - T5) + F5
e 表示用户A在结算的时候的总质押代币数量
T6 表示用户A在第6秒钟开始结算的时候，累积的每代币分配奖励之和
T5 表示用户A在第5秒钟开始结算的时候，累积的每代币分配奖励之和
F5 表示用户A在第5秒钟开始质押的时候，计算的总奖励
因此，我们只要记录用户在每次质押的时候的总奖励以及累计的每代币分配奖励之和，即可计算用户在下次结算的时候总奖励
所以最终的公式为：
某个用户在第m秒钟开始的时候质押后，该用户共质押b个质押代币，在第n秒钟开始的时候结算（m到n期间该用户不再质押），那么公式：
奖励总和 = b * (Tn - Tm) + Fm
*/
contract StakingRewards is IStakingRewards, RewardsDistributionRecipient, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // 奖励代币
    IERC20 public rewardsToken;
    // 质押代币
    IERC20 public stakingToken;
    // 表示可被挖矿的结束时间
    uint256 public periodFinish = 0;
    // 奖励比率（每秒能够产生的奖励总数），即公式中的 a
    uint256 public rewardRate = 0;
    // 该质押池可被挖矿时长
    uint256 public rewardsDuration = 60 days;
    // rewardPerTokenStored发生变化的上一次时间，即公式中的 m
    uint256 public lastUpdateTime;
    // 当前每个质押代币可以分配的奖励之和（由于奖励总数固定，所以每当质押代币总数发生变化时，该值会更新），即 公式中的 Tn
    uint256 public rewardPerTokenStored;

    // 用户进行奖励计算时，每个质押代币可分配的奖励之和的起始值，即 公式中的 Tm
    mapping(address => uint256) public userRewardPerTokenPaid;
    // 用户奖励映射
    mapping(address => uint256) public rewards;

    // 质押代币的总量
    uint256 private _totalSupply;
    // 用户质押代币映射
    mapping(address => uint256) private _balances;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _rewardsDistribution,
        address _rewardsToken,
        address _stakingToken
    ) public {
        rewardsToken = IERC20(_rewardsToken);
        stakingToken = IERC20(_stakingToken);
        rewardsDistribution = _rewardsDistribution;
    }

    /* ========== VIEWS ========== */

    // 获取质押代币的总量
    function totalSupply() external view returns (uint256) {
        return _totalSupply;
    }

    // 查询指定用户质押总量
    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    // 进行奖励计算时的时间的右区间
    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    // 计算每个质押代币能够在 [lastUpdateTime, lastTimeRewardApplicable] 时间区间内获取的奖励数
    //并累加到rewardPerTokenStored
    // 即：当前时间，每个质押代币可以分配的奖励之和(公式中的 Tn)
    function rewardPerToken() public view returns (uint256) {
        if (_totalSupply == 0) {
            return rewardPerTokenStored;
        }
        return
            rewardPerTokenStored.add(
                lastTimeRewardApplicable().sub(lastUpdateTime).mul(rewardRate).mul(1e18).div(_totalSupply)
            );
    }

    // 计算时间区间[lastUpdateTime, lastTimeRewardApplicable]内，account账户的奖励，并累计到account账户余额中
    // 奖励总和 = b * (Tn - Tm) + Fm
    // Fm：rewards[account]
    // b：_balances[account]
    // Tn：rewardPerToken()
    // Tm：userRewardPerTokenPaid[account])
    // n：lastTimeRewardApplicable
    // m：lastUpdateTime
    function earned(address account) public view returns (uint256) {
        return _balances[account].mul(rewardPerToken().sub(userRewardPerTokenPaid[account])).div(1e18).add(rewards[account]);
    }

    // 整个挖矿期间可以挖到的奖励代币总数
    function getRewardForDuration() external view returns (uint256) {
        return rewardRate.mul(rewardsDuration);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    // 质押代币支持permit，该方法是在链下签名，进行approve，这样进行质押时，只需要一笔交易
    function stakeWithPermit(uint256 amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        // _totalSupply增加
        _totalSupply = _totalSupply.add(amount);
        // 更新用户质押量映射
        _balances[msg.sender] = _balances[msg.sender].add(amount);

        // permit，根据链下签名进行授权（需要stakingToken实现EIP-2612的permit方法）
        IUniswapV2ERC20(address(stakingToken)).permit(msg.sender, address(this), amount, deadline, v, r, s);

        // 授权成功，将用户的质押代币转移到当前合约中
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    // 质押，增加质押量
    function stake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot stake 0");
        // _totalSupply增加
        _totalSupply = _totalSupply.add(amount);
        // 更新用户质押量映射
        _balances[msg.sender] = _balances[msg.sender].add(amount);
        // 转移用户质押代币到stakingRewards合约(当前合约)
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    // 减少质押量
    function withdraw(uint256 amount) public nonReentrant updateReward(msg.sender) {
        require(amount > 0, "Cannot withdraw 0");
        // _totalSupply减少
        _totalSupply = _totalSupply.sub(amount);
        // 更新用户质押量映射
        _balances[msg.sender] = _balances[msg.sender].sub(amount);
        // 转移质押代币，从当前合约转给用户
        stakingToken.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // 领取奖励
    function getReward() public nonReentrant updateReward(msg.sender) {
        // 获取到更新后的奖励总数
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            // 将奖励代币转给用户
            rewardsToken.safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    // 解除质押，取回全部本金及奖励
    function exit() external {
        // 取回全部本金
        withdraw(_balances[msg.sender]);
        // 领取奖励
        getReward();
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // 质押池接收奖励代币后的检验操作（被StakingRewardsFactory转入奖励代币后调用）
    function notifyRewardAmount(uint256 reward) external onlyRewardsDistribution updateReward(address(0)) {
        if (block.timestamp >= periodFinish) {
            rewardRate = reward.div(rewardsDuration);
        } else {
            uint256 remaining = periodFinish.sub(block.timestamp);
            uint256 leftover = remaining.mul(rewardRate);
            rewardRate = reward.add(leftover).div(rewardsDuration);
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        // 确保stakingPool中拥有的奖励代币不低于reward
        uint balance = rewardsToken.balanceOf(address(this));
        require(rewardRate <= balance.div(rewardsDuration), "Provided reward too high");

        // 更新lastUpdateTime
        lastUpdateTime = block.timestamp;
        // 设置挖矿截止时间
        periodFinish = block.timestamp.add(rewardsDuration);
        emit RewardAdded(reward);
    }

    /* ========== MODIFIERS ========== */

    // 更新奖励，只更新导致_totalSupply发生变化的用户的奖励，其他用户由于质押量为变化，可以根据公式计算出
    // 更新时机：
    // 1. _totalSupply发送变化时，需要更新
    // 2. 领取奖励时，需要更新
    modifier updateReward(address account) {
        // Tn
        rewardPerTokenStored = rewardPerToken();
        // 更新 m 为 n
        lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            // 奖励总和 = b * (Tn - Tm) + Fm
            rewards[account] = earned(account);
            // 更新Tm
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
}

interface IUniswapV2ERC20 {
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
}

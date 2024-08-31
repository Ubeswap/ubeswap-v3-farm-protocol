// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.26;
pragma abicoder v2;

import './uniswap/IUniswapV3Factory.sol';
import './uniswap/IUniswapV3Pool.sol';
import './uniswap/INonfungiblePositionManager.sol';
import './IMulticall_v4.sol';

import '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';
import '@openzeppelin/contracts/token/ERC20/IERC20.sol';

/// @title Ubeswap V3 Farming Interface
/// @notice Allows staking V3 nonfungible liquidity tokens in exchange for reward tokens
interface IUbeswapV3Farming is IERC721Receiver, IMulticall_v4 {
    /// @param rewardToken The token being distributed as a reward
    /// @param pool The Uniswap V3 compatible pool
    /// @param startTime The time when the incentive program begins
    /// @param lockTime Minimum time that is required for unstaking a position
    /// @param minimumTickRange Minimum value of (tickUpper - tickLower) for a position to be staked
    /// @param maxTickLower Maximum value of tickLower for a position to be staked
    /// @param minTickLower Minimum value of tickLower for a position to be staked
    /// @param maxTickUpper Maximum value of tickUpper for a position to be staked
    /// @param minTickUpper Minimum value of tickUpper for a position to be staked
    struct IncentiveKey {
        IERC20 rewardToken;
        IUniswapV3Pool pool;
        uint32 startTime;
        uint32 lockTime;
        int24 minimumTickRange;
        int24 maxTickLower;
        int24 minTickLower;
        int24 maxTickUpper;
        int24 minTickUpper;
    }

    /// @notice The Uniswap V3 compatible Factory
    function factory() external view returns (IUniswapV3Factory);

    /// @notice The nonfungible position manager with which this staking contract is compatible
    function nonfungiblePositionManager() external view returns (INonfungiblePositionManager);

    /// @notice The max amount of seconds into the future the incentive startTime can be set
    function maxIncentiveStartLeadTime() external view returns (uint256);

    /// @notice The max duration of an incentive in seconds
    function maxIncentivePeriodDuration() external view returns (uint256);

    /// @notice The max duration oc lock time that can be given to an incentive
    function maxLockTime() external view returns (uint256);

    /// @notice Address of the external reward distributor for the liquidity managers
    function externalRewardDistributor() external view returns (address);

    /// @notice Update function for externalRewardDistributor
    function updateExternalRewardDistributor(address _new) external;

    /// @notice Represents a staking incentive
    /// @param incentiveId The ID of the incentive computed from its parameters
    /// @return currentPeriodId current reward distribution period id
    /// @return lastUpdateTime time of last update of cumulativeReward and IncentiveDistributionInfo
    /// @return endTime End time of incentive
    /// @return numberOfStakes Number of tokens that are staked on the incentive
    function incentives(
        bytes32 incentiveId
    )
        external
        view
        returns (
            uint32 currentPeriodId,
            uint32 lastUpdateTime,
            uint32 endTime,
            uint32 numberOfStakes,
            uint128 distributedRewards,
            bytes32 merkleRoot,
            bytes32 ipfsHash,
            uint128 excessRewards,
            uint128 externalRewards
        );

    /// @notice
    function incentivePeriods(
        bytes32 incentiveId,
        uint32 periodId
    ) external view returns (uint128 rewardPerSecond, uint32 startTime, uint32 endTime);

    /// @notice Returns information about a deposited NFT
    /// @return owner The owner of the deposited NFT
    /// @return numberOfStakes Counter of how many incentives for which the liquidity is staked
    /// @return tickLower The lower tick of the range
    /// @return tickUpper The upper tick of the range
    function deposits(
        uint256 tokenId
    )
        external
        view
        returns (address owner, uint48 numberOfStakes, int24 tickLower, int24 tickUpper);

    /// @notice Returns information about a staked liquidity NFT
    /// @param incentiveId The ID of the incentive for which the token is staked
    /// @param tokenId The ID of the staked token
    function stakes(
        bytes32 incentiveId,
        uint256 tokenId
    ) external view returns (uint128 claimedReward, uint32 stakeTime, uint32 initialSecondsInside);

    /// @notice Creates a new liquidity mining incentive program
    /// @param key Details of the incentive to create
    /// @param duration The amount of seconds for the first period
    /// @param reward The amount of reward tokens to be distributed on the first period
    function createIncentive(IncentiveKey memory key, uint32 duration, uint128 reward) external;

    /// @notice Creates a new period for the incentive
    /// @param key Details of the incentive to extend
    /// @param newPeriodId the id for the new period. It should be one more from the previous period. This is taken for security
    /// @param duration The amount of seconds for the new period
    /// @param reward The amount of reward tokens to be distributed on the new period
    function extendIncentive(
        IncentiveKey memory key,
        uint32 newPeriodId,
        uint32 duration,
        uint128 reward
    ) external;

    /// @notice Add reward for already created and not started period
    function increasePeriodReward(
        IncentiveKey memory key,
        uint32 periodId,
        uint128 reward
    ) external;

    function getAccumulatedReward(
        bytes32 incentiveId,
        uint32 timestamp
    ) external view returns (uint128 accumulatedReward, uint32 lastPeriodId);

    /// @notice Update function for total liqudity seconds that is calculated off-chain
    /// @param incentiveId The ID of the incentive to be updated
    /// @param timestamp The timestamp of the block that the calculation is done on
    function updateIncentiveDistributionInfo(
        bytes32 incentiveId,
        uint32 timestamp,
        bytes32 merkleRoot,
        bytes32 ipfsHash,
        uint128 distributedRewardsSinceLastUpdate,
        uint128 activeTvlNative,
        uint128 externalTvlNative
    ) external;

    /// @notice Refunds excess rewards for the given incentive
    /// @param key Details of the incentive to end
    function refundExcessRewards(IncentiveKey memory key) external;

    /// @notice Transfers ownership of a deposit from the sender to the given recipient
    /// @param tokenId The ID of the token (and the deposit) to transfer
    /// @param to The new owner of the deposit
    function transferDeposit(uint256 tokenId, address to) external;

    /// @notice
    function collectFee(
        INonfungiblePositionManager.CollectParams calldata params
    ) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Withdraws a Ubeswap V3 LP token `tokenId` from this contract to the recipient `to`
    /// @param tokenId The unique identifier of an Ubeswap V3 LP token
    /// @param to The address where the LP token will be sent
    /// @param data An optional data array that will be passed along to the `to` address via the NFT safeTransferFrom
    function withdrawToken(uint256 tokenId, address to, bytes memory data) external;

    /// @notice Stakes a Ubeswap V3 LP token
    /// @param key The key of the incentive for which to stake the NFT
    /// @param tokenId The ID of the token to stake
    function stakeToken(IncentiveKey memory key, uint256 tokenId) external;

    /// @notice Unstakes a Ubeswap V3 LP token
    /// @param key The key of the incentive for which to unstake the NFT
    /// @param tokenId The ID of the token to unstake
    function unstakeToken(IncentiveKey memory key, uint256 tokenId) external;

    /// @notice Transfers the rewards that are accumulated for the token in the incentive
    /// @param key The key of the incentive for which to unstake the NFT
    /// @param tokenId The ID of the token that has rewards
    /// @param accumulatedRewards accumulated rewards for the position
    /// @param proof Merkle proof for rewards
    function collectReward(
        IncentiveKey memory key,
        uint256 tokenId,
        uint128 accumulatedRewards,
        bytes32[] memory proof
    ) external;

    /// @notice Transfers the rewards that are accumulated for the external reward distributor
    function collectExternalReward(IncentiveKey memory key) external;

    function getStakedTokenByIndex(
        bytes32 incentiveId,
        uint256 index
    ) external view returns (uint256);

    /// @notice Event emitted when a liquidity mining incentive has been created
    /// @param rewardToken The token being distributed as a reward
    /// @param pool The Uniswap V3 compatible pool
    /// @param startTime The time when the incentive program begins
    /// @param lockTime Minimum time that is required for unstaking a position
    /// @param minimumTickRange Minimum value of (tickUpper - tickLower) for a position to be staked
    /// @param maxTickLower Maximum value of tickLower for a position to be staked
    /// @param minTickLower Minimum value of tickLower for a position to be staked
    /// @param maxTickUpper Maximum value of tickUpper for a position to be staked
    /// @param minTickUpper Minimum value of tickUpper for a position to be staked
    event IncentiveCreated(
        bytes32 indexed incentiveId,
        IERC20 indexed rewardToken,
        IUniswapV3Pool indexed pool,
        uint32 startTime,
        uint32 lockTime,
        int24 minimumTickRange,
        int24 maxTickLower,
        int24 minTickLower,
        int24 maxTickUpper,
        int24 minTickUpper
    );

    /// @notice
    event IncentiveExtended(
        bytes32 indexed incentiveId,
        uint32 newPeriodId,
        uint32 duration,
        uint128 reward
    );

    /// @notice
    event PeriodRewardIncreased(bytes32 indexed incentiveId, uint32 periodId, uint128 reward);

    /// @notice
    event IncentiveUpdated(
        bytes32 indexed incentiveId,
        uint32 timestamp,
        uint32 newPeriodId,
        bytes32 merkleRoot,
        bytes32 ipfsHash,
        uint128 distributedRewardsSinceLastUpdate,
        uint128 activeTvlNative,
        uint128 externalTvlNative
    );

    /// @notice Event that can be emitted when excess rewards refunded
    /// @param incentiveId The incentive which has excess rewards
    event ExcessRewardsRefunded(bytes32 indexed incentiveId, uint128 refund);

    /// @notice Emitted when ownership of a deposit changes
    /// @param tokenId The ID of the deposit (and token) that is being transferred
    /// @param oldOwner The owner before the deposit was transferred
    /// @param newOwner The owner after the deposit was transferred
    event DepositTransferred(
        uint256 indexed tokenId,
        address indexed oldOwner,
        address indexed newOwner
    );

    /// @notice Event emitted when a Ubeswap V3 LP token has been staked
    /// @param tokenId The unique identifier of an Ubeswap V3 LP token
    /// @param liquidity The amount of liquidity staked
    /// @param incentiveId The incentive in which the token is staking
    event TokenStaked(
        uint256 indexed tokenId,
        bytes32 indexed incentiveId,
        uint128 liquidity,
        uint32 initialSecondsInside
    );

    /// @notice Event emitted when a Ubeswap V3 LP token has been unstaked
    /// @param tokenId The unique identifier of an Ubeswap V3 LP token
    /// @param incentiveId The incentive in which the token is staking
    event TokenUnstaked(uint256 indexed tokenId, bytes32 indexed incentiveId);

    /// @notice Event emitted when a reward collected for an incentive
    /// @param tokenId The unique identifier of an Ubeswap V3 LP token
    /// @param incentiveId The incentive
    /// @param to The address where claimed rewards were sent to
    /// @param reward The amount of reward tokens claimed
    event RewardCollected(
        uint256 indexed tokenId,
        bytes32 indexed incentiveId,
        address indexed to,
        uint256 reward
    );

    /// @notice Event emitted when externalRewardDistributor contract collects reward
    /// @param incentiveId The incentive
    /// @param to externalRewardDistributor address at the time on transaction
    /// @param reward The amount of reward tokens claimed
    event ExternalRewardCollected(bytes32 indexed incentiveId, address to, uint256 reward);

    /// @notice Event emitted when a fee collected from a pool
    /// @param owner Owner account of the deposited token when the fee collected
    /// @param tokenId The unique identifier of an Ubeswap V3 LP token
    /// @param recipient Fee recepient
    event FeeCollected(
        address indexed owner,
        uint256 indexed tokenId,
        address recipient,
        uint128 amount0Max,
        uint128 amount1Max
    );
}

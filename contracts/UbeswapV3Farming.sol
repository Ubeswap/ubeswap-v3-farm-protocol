// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.26;
pragma abicoder v2;

import './interfaces/IUbeswapV3Farming.sol';
import './libraries/IncentiveId.sol';
import './libraries/NFTPositionInfo.sol';
import './interfaces/uniswap/IUniswapV3Factory.sol';
import './interfaces/uniswap/IUniswapV3Pool.sol';
import './interfaces/uniswap/INonfungiblePositionManager.sol';
import './Multicall_v4.sol';
import './libraries/KnownLengthSet.sol';

import '@openzeppelin/contracts/utils/cryptography/MerkleProof.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

/// @title Off-chain assisted Ubeswap V3 Farming Protocol
contract UbeswapV3Farming is IUbeswapV3Farming, AccessControl, Multicall_v4 {
    using KnownLengthSet for KnownLengthSet.UintSet;

    bytes32 public constant INCENTIVE_MANAGER_ROLE = keccak256('INCENTIVE_MANAGER_ROLE');
    bytes32 public constant INCENTIVE_UPDATER_ROLE = keccak256('INCENTIVE_UPDATER_ROLE');
    bytes32 public constant REWARD_DISTRIBUTOR_ROLE = keccak256('REWARD_DISTRIBUTOR_ROLE');

    /// @notice Represents a staking incentive
    struct Incentive {
        uint32 currentPeriodId;
        uint32 lastUpdateTime;
        uint32 endTime;
        uint32 numberOfStakes;
        uint128 distributedRewards;
        // -----------
        bytes32 merkleRoot;
        // -----------
        bytes32 ipfsHash;
        // -----------
        uint128 excessRewards;
        uint128 externalRewards;
    }

    struct IncentivePeriod {
        uint128 rewardPerSecond;
        uint32 startTime;
        uint32 endTime;
    }

    /// @notice Represents the deposit of a liquidity NFT
    struct Deposit {
        address owner;
        uint48 numberOfStakes;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @notice Represents a staked liquidity NFT
    struct Stake {
        uint128 claimedReward;
        uint32 stakeTime;
        uint32 initialSecondsInside;
    }

    /// @inheritdoc IUbeswapV3Farming
    IUniswapV3Factory public immutable override factory;
    /// @inheritdoc IUbeswapV3Farming
    INonfungiblePositionManager public immutable override nonfungiblePositionManager;

    /// @inheritdoc IUbeswapV3Farming
    uint256 public immutable override maxIncentiveStartLeadTime;
    /// @inheritdoc IUbeswapV3Farming
    uint256 public immutable override maxIncentivePeriodDuration;
    /// @inheritdoc IUbeswapV3Farming
    uint256 public immutable override maxLockTime;

    /// @inheritdoc IUbeswapV3Farming
    address public override externalRewardDistributor;

    /// @dev bytes32 refers to the return value of IncentiveId.compute
    mapping(bytes32 => Incentive) public override incentives;

    /// @dev incentivePeriods[incentiveId][periodId] => IncentivePeriod
    mapping(bytes32 => mapping(uint32 => IncentivePeriod)) public override incentivePeriods;

    /// @dev deposits[tokenId] => Deposit
    mapping(uint256 => Deposit) public override deposits;

    /// @dev stakes[incentiveId][tokenId] => Stake
    mapping(bytes32 => mapping(uint256 => Stake)) public override stakes;

    // incentiveId => staked tokens set
    mapping(bytes32 => KnownLengthSet.UintSet) private _stakedTokens;

    /// @param _factory the Uniswap V3 compatible factory
    /// @param _nonfungiblePositionManager the NFT position manager contract address
    /// @param _maxIncentiveStartLeadTime the max duration of an incentive in seconds
    /// @param _maxIncentivePeriodDuration the max amount of seconds into the future the incentive startTime can be set
    constructor(
        IUniswapV3Factory _factory,
        INonfungiblePositionManager _nonfungiblePositionManager,
        uint256 _maxIncentiveStartLeadTime,
        uint256 _maxIncentivePeriodDuration,
        uint256 _maxLockTime
    ) {
        factory = _factory;
        nonfungiblePositionManager = _nonfungiblePositionManager;
        maxIncentiveStartLeadTime = _maxIncentiveStartLeadTime;
        maxIncentivePeriodDuration = _maxIncentivePeriodDuration;
        maxLockTime = _maxLockTime;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(INCENTIVE_MANAGER_ROLE, msg.sender);
        _grantRole(INCENTIVE_UPDATER_ROLE, msg.sender);
        _grantRole(REWARD_DISTRIBUTOR_ROLE, msg.sender);
    }

    function updateExternalRewardDistributor(
        address _new
    ) public override onlyRole(INCENTIVE_MANAGER_ROLE) {
        externalRewardDistributor = _new;
    }

    /// @inheritdoc IUbeswapV3Farming
    function createIncentive(
        IncentiveKey memory key,
        uint32 duration,
        uint128 reward
    ) external override onlyRole(INCENTIVE_MANAGER_ROLE) {
        uint32 endTime = key.startTime + duration;
        require(reward > 0, 'reward must be positive');
        require(duration > 0, 'duration must be positive');
        require(block.timestamp <= key.startTime, 'startTime must be after now');
        require(
            key.startTime - block.timestamp <= maxIncentiveStartLeadTime,
            'start time too far into future'
        );
        require(duration <= maxIncentivePeriodDuration, 'incentive duration is too long');
        require(key.lockTime <= maxLockTime, 'wrong lock time');
        require(key.maxTickLower > key.minTickLower, 'wrong tickLower range');
        require(key.maxTickUpper > key.minTickUpper, 'wrong tickUpper range');

        bytes32 incentiveId = IncentiveId.compute(key);

        require(incentives[incentiveId].endTime == 0, 'incentive already exists');

        incentives[incentiveId].endTime = endTime;
        incentives[incentiveId].lastUpdateTime = key.startTime;
        incentivePeriods[incentiveId][0] = IncentivePeriod({
            rewardPerSecond: reward / duration,
            startTime: key.startTime,
            endTime: endTime
        });

        SafeERC20.safeTransferFrom(key.rewardToken, msg.sender, address(this), reward);

        emit IncentiveCreated(
            incentiveId,
            key.rewardToken,
            key.pool,
            key.startTime,
            key.lockTime,
            key.minimumTickRange,
            key.maxTickLower,
            key.minTickLower,
            key.maxTickUpper,
            key.minTickUpper
        );
        emit IncentiveExtended(incentiveId, 0, duration, reward);
    }

    /// @inheritdoc IUbeswapV3Farming
    function extendIncentive(
        IncentiveKey memory key,
        uint32 newPeriodId,
        uint32 duration,
        uint128 reward
    ) external override onlyRole(REWARD_DISTRIBUTOR_ROLE) {
        require(reward > 0, 'reward must be positive');
        require(duration > 0, 'duration must be positive');
        require(duration <= maxIncentivePeriodDuration, 'incentive duration is too long');

        bytes32 incentiveId = IncentiveId.compute(key);
        uint32 currentEndTime = incentives[incentiveId].endTime;
        require(currentEndTime > 0, 'non-existent incentive');
        require(incentives[incentiveId].currentPeriodId == (newPeriodId - 1), 'wrong period id');

        uint32 newEndTime = currentEndTime + duration;
        incentivePeriods[incentiveId][newPeriodId] = IncentivePeriod({
            rewardPerSecond: reward / duration,
            startTime: currentEndTime,
            endTime: newEndTime
        });
        incentives[incentiveId].endTime = newEndTime;

        SafeERC20.safeTransferFrom(key.rewardToken, msg.sender, address(this), reward);

        emit IncentiveExtended(incentiveId, newPeriodId, duration, reward);
    }

    /// @inheritdoc IUbeswapV3Farming
    function increasePeriodReward(
        IncentiveKey memory key,
        uint32 periodId,
        uint128 reward
    ) external override onlyRole(REWARD_DISTRIBUTOR_ROLE) {
        require(reward > 0, 'reward must be positive');
        bytes32 incentiveId = IncentiveId.compute(key);
        IncentivePeriod memory period = incentivePeriods[incentiveId][periodId];
        require(period.rewardPerSecond > 0, 'non-existent incentive or period');
        require(block.timestamp <= period.startTime, 'period is started');

        period.rewardPerSecond += reward / (period.endTime - period.startTime);
        incentivePeriods[incentiveId][periodId] = period;

        SafeERC20.safeTransferFrom(key.rewardToken, msg.sender, address(this), reward);

        emit PeriodRewardIncreased(incentiveId, periodId, reward);
    }

    /// @inheritdoc IUbeswapV3Farming
    function getAccumulatedReward(
        bytes32 incentiveId,
        uint32 timestamp
    ) public view override returns (uint128 accumulatedReward, uint32 lastPeriodId) {
        uint32 currentPeriodId = incentives[incentiveId].currentPeriodId;
        uint32 lastUpdateTime = incentives[incentiveId].lastUpdateTime;
        lastPeriodId = currentPeriodId;
        IncentivePeriod memory currPeriod = incentivePeriods[incentiveId][currentPeriodId];
        accumulatedReward = 0;
        if (timestamp > currPeriod.endTime) {
            accumulatedReward = (currPeriod.endTime - lastUpdateTime) * currPeriod.rewardPerSecond;
            lastPeriodId += 1;
            IncentivePeriod memory nextPeriod = incentivePeriods[incentiveId][lastPeriodId];
            require(nextPeriod.rewardPerSecond > 0, 'next period not exists');
            require(timestamp <= nextPeriod.endTime, 'next period ended too');
            accumulatedReward += (timestamp - currPeriod.endTime) * nextPeriod.rewardPerSecond;
        } else {
            accumulatedReward = (timestamp - lastUpdateTime) * currPeriod.rewardPerSecond;
        }
    }

    /// @inheritdoc IUbeswapV3Farming
    function updateIncentiveDistributionInfo(
        bytes32 incentiveId,
        uint32 timestamp,
        bytes32 merkleRoot,
        bytes32 ipfsHash,
        uint128 distributedRewardsSinceLastUpdate,
        uint128 activeTvlNative,
        uint128 externalTvlNative
    ) external override onlyRole(INCENTIVE_UPDATER_ROLE) {
        require(timestamp < block.timestamp, 'time must be before now');
        Incentive memory incentive = incentives[incentiveId];
        require(incentive.lastUpdateTime > 0, 'non-existent incentive');
        require(timestamp > incentive.lastUpdateTime, 'timestamp > lastUpdateTime');

        (uint128 accumulatedReward, uint32 lastPeriodId) = getAccumulatedReward(
            incentiveId,
            timestamp
        );

        uint128 tvlNative = activeTvlNative + externalTvlNative;

        if (tvlNative == 0) {
            // this means, no rewards has been disributed, so rewards will be refunded later
            require(incentive.merkleRoot == merkleRoot, 'invalid merkleRoot');
            require(distributedRewardsSinceLastUpdate == 0, 'reward must be 0');
            incentive.excessRewards += accumulatedReward;
        } else {
            require(incentive.merkleRoot != merkleRoot, 'same merkleRoot');
            require(incentive.ipfsHash != ipfsHash, 'same ipfsHash');
            require(distributedRewardsSinceLastUpdate == accumulatedReward, 'invalid reward');
            incentive.externalRewards += uint128(
                (uint256(accumulatedReward) * uint256(externalTvlNative)) / uint256(tvlNative)
            );
        }

        incentive.currentPeriodId = lastPeriodId;
        incentive.distributedRewards += accumulatedReward;
        incentive.lastUpdateTime = timestamp;
        incentive.merkleRoot = merkleRoot;
        incentive.ipfsHash = ipfsHash;
        incentives[incentiveId] = incentive;

        emit IncentiveUpdated(
            incentiveId,
            timestamp,
            incentive.currentPeriodId,
            merkleRoot,
            ipfsHash,
            accumulatedReward,
            activeTvlNative,
            externalTvlNative
        );
    }

    /// @inheritdoc IUbeswapV3Farming
    function refundExcessRewards(
        IncentiveKey memory key
    ) external override onlyRole(INCENTIVE_MANAGER_ROLE) {
        bytes32 incentiveId = IncentiveId.compute(key);
        uint128 excessRewards = incentives[incentiveId].excessRewards;

        require(excessRewards > 0, 'no excess rewards');

        incentives[incentiveId].excessRewards = 0;

        SafeERC20.safeTransfer(key.rewardToken, msg.sender, excessRewards);

        emit ExcessRewardsRefunded(incentiveId, excessRewards);
    }

    /// @notice Upon receiving a Ubeswap V3 ERC721, creates the token deposit setting owner to `from`. Also stakes token
    /// in one or more incentives if properly formatted `data` has a length > 0.
    /// @inheritdoc IERC721Receiver
    function onERC721Received(
        address,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        require(msg.sender == address(nonfungiblePositionManager), 'not a univ3 nft');

        (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = nonfungiblePositionManager
            .positions(tokenId);

        deposits[tokenId] = Deposit({
            owner: from,
            numberOfStakes: 0,
            tickLower: tickLower,
            tickUpper: tickUpper
        });
        emit DepositTransferred(tokenId, address(0), from);

        if (data.length > 0) {
            if (data.length == 288) {
                _stakeToken(abi.decode(data, (IncentiveKey)), tokenId);
            } else {
                IncentiveKey[] memory keys = abi.decode(data, (IncentiveKey[]));
                for (uint256 i = 0; i < keys.length; i++) {
                    _stakeToken(keys[i], tokenId);
                }
            }
        }
        return this.onERC721Received.selector;
    }

    /// @inheritdoc IUbeswapV3Farming
    function transferDeposit(uint256 tokenId, address to) external override {
        require(to != address(this), 'cannot transfer to farm');
        require(to != address(0), 'invalid to address');
        address owner = deposits[tokenId].owner;
        require(owner == msg.sender, 'only owner can transfer');
        deposits[tokenId].owner = to;
        emit DepositTransferred(tokenId, owner, to);
    }

    /// @inheritdoc IUbeswapV3Farming
    function collectFee(
        INonfungiblePositionManager.CollectParams calldata params
    ) external payable override returns (uint256 amount0, uint256 amount1) {
        address owner = deposits[params.tokenId].owner;
        require(owner == msg.sender, 'only owner can collect');
        (amount0, amount1) = nonfungiblePositionManager.collect{ value: msg.value }(params);
        emit FeeCollected(
            msg.sender,
            params.tokenId,
            params.recipient,
            params.amount0Max,
            params.amount1Max
        );
    }

    /// @inheritdoc IUbeswapV3Farming
    function withdrawToken(uint256 tokenId, address to, bytes memory data) external override {
        require(to != address(this), 'cannot withdraw to farm');
        require(to != address(0), 'invalid to address');
        Deposit memory deposit = deposits[tokenId];
        require(deposit.numberOfStakes == 0, 'token is staked');
        require(deposit.owner == msg.sender, 'only owner can withdraw');

        delete deposits[tokenId];
        emit DepositTransferred(tokenId, deposit.owner, address(0));

        nonfungiblePositionManager.safeTransferFrom(address(this), to, tokenId, data);
    }

    /// @inheritdoc IUbeswapV3Farming
    function stakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        require(deposits[tokenId].owner == msg.sender, 'only owner can stake token');

        _stakeToken(key, tokenId);
    }

    /// @inheritdoc IUbeswapV3Farming
    function unstakeToken(IncentiveKey memory key, uint256 tokenId) external override {
        require(deposits[tokenId].owner == msg.sender, 'only owner can unstake');

        bytes32 incentiveId = IncentiveId.compute(key);
        require(stakes[incentiveId][tokenId].stakeTime > 0, 'token not staked');
        Incentive memory incentive = incentives[incentiveId];

        if (key.lockTime > 0) {
            require(
                key.lockTime < (block.timestamp - stakes[incentiveId][tokenId].stakeTime),
                'token locked'
            );
        }

        _stakedTokens[incentiveId].remove(tokenId, incentive.numberOfStakes);

        stakes[incentiveId][tokenId] = Stake({
            claimedReward: stakes[incentiveId][tokenId].claimedReward,
            stakeTime: 0,
            initialSecondsInside: 0
        });

        deposits[tokenId].numberOfStakes--;
        incentives[incentiveId].numberOfStakes--;

        emit TokenUnstaked(tokenId, incentiveId);
    }

    /// @inheritdoc IUbeswapV3Farming
    function collectReward(
        IncentiveKey memory key,
        uint256 tokenId,
        uint128 accumulatedRewards,
        bytes32[] memory proof
    ) external override {
        require(deposits[tokenId].owner == msg.sender, 'only owner can collect');

        bytes32 incentiveId = IncentiveId.compute(key);

        bytes32 firstHash = keccak256(abi.encode(tokenId, accumulatedRewards));
        bytes32 leaf = keccak256(bytes.concat(firstHash));

        require(
            MerkleProof.verify(proof, incentives[incentiveId].merkleRoot, leaf),
            'Invalid proof'
        );

        uint256 reward = accumulatedRewards - stakes[incentiveId][tokenId].claimedReward;
        require(reward > 0, 'no rewards');

        stakes[incentiveId][tokenId].claimedReward = accumulatedRewards;

        SafeERC20.safeTransferFrom(key.rewardToken, address(this), msg.sender, reward);

        emit RewardCollected(tokenId, incentiveId, msg.sender, reward);
    }

    /// @inheritdoc IUbeswapV3Farming
    function collectExternalReward(IncentiveKey memory key) external override {
        require(externalRewardDistributor == msg.sender, 'not externalRewardDistributor');

        bytes32 incentiveId = IncentiveId.compute(key);
        uint128 reward = incentives[incentiveId].externalRewards;
        require(reward > 0, 'no rewards');

        incentives[incentiveId].externalRewards = 0;

        SafeERC20.safeTransferFrom(key.rewardToken, address(this), msg.sender, reward);

        emit ExternalRewardCollected(incentiveId, msg.sender, reward);
    }

    /// @inheritdoc IUbeswapV3Farming
    function getStakedTokenByIndex(
        bytes32 incentiveId,
        uint256 index
    ) external view override returns (uint256) {
        return _stakedTokens[incentiveId].at(index);
    }

    /// @dev Stakes a deposited token without doing an ownership check
    function _stakeToken(IncentiveKey memory key, uint256 tokenId) private {
        bytes32 incentiveId = IncentiveId.compute(key);
        uint32 endTime = incentives[incentiveId].endTime;
        uint32 numberOfStakes = incentives[incentiveId].numberOfStakes;

        require(endTime > 0, 'non-existent incentive');
        require(
            block.timestamp >= key.startTime && block.timestamp < endTime,
            'incentive not active'
        );
        require(stakes[incentiveId][tokenId].stakeTime == 0, 'token already staked');

        (IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) = NFTPositionInfo
            .getPositionInfo(factory, nonfungiblePositionManager, tokenId);

        require(pool == key.pool, 'token pool is not the incentive pool');
        require(key.minimumTickRange <= (tickUpper - tickLower), 'wrong tick range');
        require(key.maxTickLower >= tickLower && key.minTickLower <= tickLower, 'wrong tickLower');
        require(key.maxTickUpper >= tickUpper && key.minTickUpper <= tickUpper, 'wrong tickUpper');
        require(liquidity > 0, 'cannot stake token with 0 liquidity');

        _stakedTokens[incentiveId].add(tokenId, numberOfStakes);

        deposits[tokenId].numberOfStakes++;
        incentives[incentiveId].numberOfStakes++;

        (, , uint32 secondsInside) = pool.snapshotCumulativesInside(tickLower, tickUpper);

        stakes[incentiveId][tokenId] = Stake({
            claimedReward: stakes[incentiveId][tokenId].claimedReward,
            stakeTime: uint32(block.timestamp),
            initialSecondsInside: secondsInside
        });

        emit TokenStaked(tokenId, incentiveId, liquidity, secondsInside);
    }
}

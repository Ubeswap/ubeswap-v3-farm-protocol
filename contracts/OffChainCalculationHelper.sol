// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity =0.8.26;
import './interfaces/IOffChainCalculationHelper.sol';
import './interfaces/IUbeswapV3Farming.sol';
import './interfaces/uniswap/IQuoterV2.sol';
import './libraries/IncentiveId.sol';
import { SqrtPriceMath } from './libraries/SqrtPriceMath.sol';
import { TickMath } from './libraries/TickMath.sol';
import { FullMath } from './libraries/FullMath.sol';
import './Multicall_v4.sol';

import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

/*
    This contract provides helper functions for calculating liquiditySeconds for all tokens in the farm, off-chain.
    These calculations are very costly and should _not_ be called on chain.

    Database
        incentive_id
        token_id
        accumulatd_reward
        last_seconds_for_tickrange
        last_tvl_native
        merkle_proof

    Pseudocode
    -----------------------
    function lastSecondsForToken(incentiveId, tokenId)

    // these calls should be done on the same block number
    var timestamp = ... // timestamp of the selected block
    var key = ... // information of the incentive
    var incentiveId = ... // id of the incentive, calculated from key
    var incentive = UbeswapV3Farming.incentives(incentiveId)
    var actualDuration = timestamp - incentive.lastUpdateTime
    var length = incentive.numberOfStakes
    var tokens = []
    for (var index =  0 ... length) {
        var tokenInfo =  UbeswapV3Farming.getStakedTokenInfo(incentiveId, key.pool, index)
        var duration = tokenInfo.stakeTime < incentive.lastUpdateTime
                            ? (timestamp - incentive.lastUpdateTime)
                            : (timestamp - tokenInfo.stakeTime);
        var secondsInside = tokenInfo.stakeTime < incentive.lastUpdateTime
                            ? tokenInfo.secondsInsideOfTickRange - lastSecondsForToken(incentiveId, tokenId)
                            : tokenInfo.secondsInsideOfTickRange - tokenInfo.initialSecondsInside
        if (secondsInside > (duration * 0.8)) {
            tokenInfo.duration = duration
            tokens.push(tokenInfo)
        }
    }

    var totalTvlNative = 0
    for(var tokenInfo in tokens) {
        var tvlNative = UbeswapV3Farming.calculateTokensTvlNative(key.pool, [tokenInfo.tokenId])
        tokenInfo.tvlNative = tvlNative * (tokenInfo.duration / actualDuration)
        totalTvlNative += tokenInfo.tvlNative
    }

    var rewardToDistribute = 0
    if (totalTvlNative > 0) {
        rewardToDistribute = UbeswapV3Farming.rewardToDistribute(incentiveId, timestamp)
    }

    for(var tokenInfo in tokens) {
        tokenInfo.reward = rewardToDistribute * (tokenInfo.tvlNative / totalTvlNative);
    }

    var tree = CreateMerleTree(tokens)
    var ipfsHash = SaveToIPFS(tree)

    WriteToDB(tokens)

    UbeswapV3Farming.updateIncentiveDistributionInfo(incentiveId, timestamp, tree.root, ipfsHash, rewardToDistribute, totalTvlNative)
*/

contract OffChainCalculationHelper is IOffChainCalculationHelper, Ownable, Multicall_v4 {
    /// @inheritdoc IOffChainCalculationHelper
    IUbeswapV3Farming public immutable override farm;

    /// @inheritdoc IOffChainCalculationHelper
    IQuoterV2 public immutable override quoter;

    // tokenAddress => path
    mapping(address => bytes) public tokenToNativePath;

    constructor(
        address initialOwner,
        IUbeswapV3Farming _farm,
        IQuoterV2 _quoter
    ) Ownable(initialOwner) {
        farm = _farm;
        quoter = _quoter;
    }

    /// @inheritdoc IOffChainCalculationHelper
    function updateTokenToNativePath(address token, bytes memory path) public override onlyOwner {
        tokenToNativePath[token] = path;
    }

    function getStakedTokenInfo(
        IUbeswapV3Farming.IncentiveKey memory key,
        uint256 index
    )
        public
        view
        override
        returns (
            uint256 tokenId,
            uint32 stakeTime,
            uint32 secondsInsideOfTickRange,
            uint32 initialSecondsInside,
            int24 tickLower,
            int24 tickUpper
        )
    {
        bytes32 incentiveId = IncentiveId.compute(key);
        tokenId = farm.getStakedTokenByIndex(incentiveId, index);
        (, stakeTime, initialSecondsInside) = farm.stakes(incentiveId, tokenId);
        (, , tickLower, tickUpper) = farm.deposits(tokenId);
        (, , secondsInsideOfTickRange) = key.pool.snapshotCumulativesInside(tickLower, tickUpper);
    }

    function quoteToken(address token, uint256 amount) public returns (uint256 amountOut) {
        if (token == 0x471EcE3750Da237f93B8E339c536989b8978a438) {
            return amount;
        }
        (amountOut, , , ) = quoter.quoteExactInput(tokenToNativePath[token], amount);
    }

    function getAmounts(
        uint256 tokenId,
        int24 currTick,
        uint160 sqrtPriceX96
    ) public view returns (uint256 amount0, uint256 amount1) {
        (, , , , , int24 tickLower, int24 tickUpper, uint128 liquidity, , , , ) = farm
            .nonfungiblePositionManager()
            .positions(tokenId);

        if (currTick < tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity,
                false
            );
        } else if (currTick < tickUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(
                sqrtPriceX96,
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity,
                false
            );
        } else {
            amount0 = 0;
        }

        if (currTick < tickLower) {
            amount1 = 0;
        } else if (currTick < tickUpper) {
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                sqrtPriceX96,
                liquidity,
                false
            );
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity,
                false
            );
        }
    }

    function calculateTokensTvlNative(
        IUniswapV3Pool pool,
        uint256[] calldata tokenIds
    ) external override returns (uint256[] memory) {
        (uint160 sqrtPriceX96, int24 currTick, , , , , ) = pool.slot0();
        address token0 = pool.token0();
        address token1 = pool.token1();
        uint256 token0decimals = IERC20Metadata(token0).decimals();
        uint256 token1decimals = IERC20Metadata(token1).decimals();
        uint256 token0price = quoteToken(token0, 10 ** token0decimals);
        uint256 token1price = quoteToken(token1, 10 ** token1decimals);

        uint256[] memory result = new uint256[](tokenIds.length);
        uint256 amount0 = 0;
        uint256 amount1 = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (amount0, amount1) = getAmounts(tokenIds[i], currTick, sqrtPriceX96);
            amount0 = FullMath.mulDiv(amount0, token0price, 10 ** token0decimals);
            amount1 = FullMath.mulDiv(amount1, token1price, 10 ** token1decimals);
            result[i] = amount0 + amount1;
        }
        return result;
    }
}

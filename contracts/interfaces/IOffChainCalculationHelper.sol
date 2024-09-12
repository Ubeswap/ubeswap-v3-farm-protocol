// SPDX-License-Identifier: GPL-2.0
pragma solidity =0.8.26;
pragma abicoder v2;

import './uniswap/IUniswapV3Pool.sol';
import './uniswap/IQuoterV2.sol';
import './IUbeswapV3Farming.sol';
import './IMulticall_v4.sol';

interface IOffChainCalculationHelper is IMulticall_v4 {
    /// @notice Ubeswap V3 farm
    function farm() external view returns (IUbeswapV3Farming);

    /// @notice The quoter for price calculations
    function quoter() external view returns (IQuoterV2);

    /// @notice tokenId => path
    function tokenToNativePath(address token) external returns (bytes memory path);

    /// @notice Sets the path to Native token for given token
    function updateTokenToNativePath(address token, bytes memory path) external;

    function getStakedTokenInfo(
        IUbeswapV3Farming.IncentiveKey memory key,
        uint256 index
    )
        external
        view
        returns (
            uint256 tokenId,
            uint32 stakeTime,
            uint32 secondsInsideOfTickRange,
            uint32 initialSecondsInside,
            int24 tickLower,
            int24 tickUpper
        );

    function quoteToken(address token, uint256 amount) external returns (uint256 amountOut);

    function getAmounts(
        uint256 tokenId,
        int24 currTick,
        uint160 sqrtPriceX96
    ) external view returns (uint256 amount0, uint256 amount1);

    function calculateTokensTvlNative(
        IUniswapV3Pool pool,
        uint256[] calldata tokenIds
    ) external returns (uint256[] memory);
}

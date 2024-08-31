// SPDX-License-Identifier: UNLICENSED
// Taken from https://github.com/Uniswap/v4-periphery/blob/main/src/interfaces/IMulticall_v4.sol
pragma solidity =0.8.26;

/// @title Multicall_v4 interface
/// @notice Enables calling multiple methods in a single call to the contract
interface IMulticall_v4 {
    /// @notice Call multiple functions in the current contract and return the data from all of them if they all succeed
    /// @dev The `msg.value` should not be trusted for any method callable from multicall.
    /// @param data The encoded function data for each of the calls to make to this contract
    /// @return results The results from each of the calls passed in via data
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}

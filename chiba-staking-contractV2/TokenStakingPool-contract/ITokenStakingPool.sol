// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @author RetreebInc
/// @title Interface Staking Platform with fixed APY and lockup
interface ITokenStakingPool {
  /**
   * @notice function that returns the amount of total Staked tokens
   * for a specific user
   * @param stakeHolder, address of the user to check
   * @return uint amount of the total deposited Tokens by the caller
   */
  function amountStaked(uint256 pid, address stakeHolder) external view returns (uint);

  /**
   * @notice function that returns the amount of total Staked tokens
   * on the smart contract
   * @return uint amount of the total deposited Tokens
   */
  function totalDeposited(uint256 pid) external view returns (uint);

  /**
   * @notice function that returns the amount of pending rewards
   * that can be claimed by the user
   * @param stakeHolder, address of the user to be checked
   * @return uint amount of claimable rewards
   */
  function rewardOf(uint256 pid, address stakeHolder) external view returns (uint);

  /**
   * @notice function that claims pending rewards
   * @dev transfer the pending rewards to the `msg.sender`
   */
  function claimRewards(uint256 pid) external;

  /**
   * @dev Emitted when `amount` tokens are deposited into
   * staking platform
   */
  event Deposit(uint256 pid, address indexed owner, uint amount);

  /**
   * @dev Emitted when user withdraw deposited `amount`
   */
  event Withdraw(uint256 pid, address indexed owner, uint amount);

  /**
   * @dev Emitted when `stakeHolder` claim rewards
   */
  event Claim(uint256 pid, address indexed stakeHolder, uint amount);

  /**
   * @dev Emitted when staking has started
   */
  event StartStaking(uint startPeriod, uint endingPeriod);
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import './Ownable.sol';
import './IERC20.sol';
import './SafeERC20.sol';
import './ITokenStakingPool.sol';
import './IPoolExtension.sol';

/// @author www.github.com/jscrui
/// @title Staking Platform with fixed APY and lockup
contract TokenStakingPool is IPoolExtension, ITokenStakingPool, Ownable {
  using SafeERC20 for IERC20;

  address public immutable mainPool;
  IERC20 public immutable token;
  uint[] public fixedAPR;

  uint[] private _totalStaked;

  mapping(address => mapping(uint256 => uint)) public staked;
  mapping(address => mapping(uint256 => uint)) private _rewardsToClaim;
  mapping(address => mapping(uint256 => uint)) public _userStartTime;

  modifier onlyPool() {
    require(_msgSender() == mainPool, 'Unauthorized');
    _;
  }

  /**
   * @notice constructor contains all the parameters of the staking platform
   * @dev all parameters are immutable
   * @param _token, address of the token to be staked
   */
  constructor(address _mainPool, IERC20 _token) {
    mainPool = _mainPool;
    token = _token;
  }

  function setShare(
    uint256 pid,
    address wallet,
    uint256 balanceChange,
    bool isRemoving
  ) external override onlyPool {
    if (isRemoving) {
      _withdraw(pid, wallet, balanceChange);
    } else {
      _deposit(pid, wallet, balanceChange);
    }
  }

  /**
   * @notice function that allows a user to deposit tokens
   * @dev user must first approve the amount to deposit before calling this function,
   * cannot exceed the `maxAmountStaked`
   * @param amount, the amount to be deposited
   * @dev that the amount deposited should greater than 0
   */
  function _deposit(uint256 pid, address wallet, uint amount) internal {
    require(amount > 0, 'Amount must be greater than 0');

    if (_userStartTime[wallet][pid] == 0) {
      _userStartTime[wallet][pid] = block.timestamp;
    }

    _updateRewards(pid, wallet);

    staked[wallet][pid] += amount;
    _totalStaked[pid] += amount;
    emit Deposit(pid, wallet, amount);
  }

  /**
   * @notice function that allows a user to withdraw its initial deposit
   * @param amount, amount to withdraw
   * @dev `amount` must be higher than `0`
   * @dev `amount` must be lower or equal to the amount staked
   * withdraw reset all states variable for the `msg.sender` to 0, and claim rewards
   * if rewards to claim
   */
  function _withdraw(uint256 pid, address wallet, uint amount) internal {
    require(amount > 0, 'Amount must be greater than 0');
    require(amount <= staked[wallet][pid], 'Amount higher than stakedAmount');

    _updateRewards(pid, wallet);
    if (_rewardsToClaim[wallet][pid] > 0) {
      _claimRewards(pid, wallet);
    }
    _totalStaked[pid] -= amount;
    staked[wallet][pid] -= amount;

    emit Withdraw(pid, wallet, amount);
  }

  /**
   * @notice claim all remaining balance on the contract
   * Residual balance is all the remaining tokens that have not been distributed
   * (e.g, in case the number of stakeholders is not sufficient)
   * @dev Can only be called after the end of the staking period
   * Cannot claim initial stakeholders deposit
   */
  function withdrawResidualBalance() external onlyOwner {
    uint totalStakedAmount = totalStakedOfContract();
    uint residualBalance = token.balanceOf(address(this)) - totalStakedAmount;
    require(residualBalance > 0, 'No residual Balance to withdraw');
    token.safeTransfer(_msgSender(), residualBalance);
  }

  function totalStakedOfContract() internal onlyOwner view returns (uint) {
    uint totalStakedAmount = 0;
    for (uint256 _i; _i < _totalStaked.length; _i++)
      totalStakedAmount += _totalStaked[_i];
    return totalStakedAmount;
  }

  /**
   * @notice function that allows the owner to set the APY
   * @param _newAPR, the new APY to be set (in %) 10 = 10%, 50 = 50
   */
  function setAPR(uint256 pid, uint8 _newAPR) external onlyOwner {
    fixedAPR[pid] = _newAPR;
  }

  /**
   * @notice function that returns the amount of total Staked tokens
   * for a specific user
   * @param stakeHolder, address of the user to check
   * @return uint amount of the total deposited Tokens by the caller
   */
  function amountStaked(uint256 pid, address stakeHolder) external view override returns (uint) {
    return staked[stakeHolder][pid];
  }

  /**
   * @notice function that returns the amount of total Staked tokens
   * on the smart contract
   * @return uint amount of the total deposited Tokens
   */
  function totalDeposited(uint256 pid) external view override returns (uint) {
    return _totalStaked[pid];
  }

  /**
   * @notice function that returns the amount of pending rewards
   * that can be claimed by the user
   * @param stakeHolder, address of the user to be checked
   * @return uint amount of claimable rewards
   */
  function rewardOf(uint256 pid, address stakeHolder) external view override returns (uint) {
    return _calculateRewards(pid, stakeHolder);
  }

  /**
   * @notice function that claims pending rewards
   * @dev transfer the pending rewards to the `msg.sender`
   */
  function claimRewards(uint256 pid) external override {
    _claimRewards(pid, _msgSender());
  }

  /**
   * @notice calculate rewards based on the `fixedAPR`
   * @param stakeHolder, address of the user to be checked
   * @return uint amount of claimable tokens of the specified address
   */
  function _calculateRewards(uint256 pid, address stakeHolder) internal view returns (uint) {
    uint _timeStaked = block.timestamp - _userStartTime[stakeHolder][pid];
    return
      ((staked[stakeHolder][pid] * fixedAPR[pid] * _timeStaked) / 365 days / 100) +
      _rewardsToClaim[stakeHolder][pid];
  }

  /**
   * @notice internal function that claims pending rewards
   * @dev transfer the pending rewards to the user address
   */
  function _claimRewards(uint256 pid, address stakeHolder) private {
    _updateRewards(pid, stakeHolder);

    uint rewardsToClaim = _rewardsToClaim[stakeHolder][pid];
    require(rewardsToClaim > 0, 'Nothing to claim');

    _rewardsToClaim[stakeHolder][pid] = 0;
    token.safeTransfer(stakeHolder, rewardsToClaim);
    emit Claim(pid, stakeHolder, rewardsToClaim);
  }

  /**
   * @notice function that update pending rewards
   * and shift them to rewardsToClaim
   * @dev update rewards claimable
   * and check the time spent since deposit for the `msg.sender`
   */
  function _updateRewards(uint256 pid, address stakeHolder) private {
    _rewardsToClaim[stakeHolder][pid] = _calculateRewards(pid, stakeHolder);
    _userStartTime[stakeHolder][pid] = block.timestamp;
  }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Ownable.sol";
import "./ReentrancyGuard.sol";
import "./IERC20.sol";
import "./SafeERC20.sol";
import "./Context.sol";
import "./IUniswapV2Router02.sol";
import "./IPoolExtension.sol";

contract StakingPool is Context, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV2Router02 immutable _router = IUniswapV2Router02(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    uint256 constant MULTIPLIER = 10**36;
    uint256 constant FACTOR = 10000; // 10000: 100% 100: 1%
    address public token;
    uint256 _totalPercentages;

    struct PoolInfo {
        uint256 percentage;
        uint256 lockupPeriod;
        uint256 totalStakedUsers;
        uint256 totalSharesDeposited;
        uint256 rewardsPerShare;
        uint256 totalDistributed;
        uint256 totalRewards;
    }

    PoolInfo[] public pools;

    IPoolExtension public extension;

    struct Share {
        uint256 amount;
        uint256 stakedTime;
    }
    struct Reward {
        uint256 excluded;
        uint256 realised;
    }
    mapping(address => mapping(uint256 => Share)) public shares;
    mapping(address => mapping(uint256 => Reward)) public rewards;

    event Stake(uint256 pid, address indexed user, uint256 amount);
    event Unstake(uint256 pid, address indexed user, uint256 amount);
    event ClaimReward(uint256 pid, address user);
    event DepositRewards(uint256 pid, address indexed user, uint256 amountTokens);
    event DistributeReward(uint256 pid, address indexed user, uint256 amount, bool _wasCompounded);

    // pool 0: 14 days, 1.5% (1209600, 150)
    // pool 1: 28 days, 12.5% (2419200, 1250)
    // pool 2: 56 days, 86% (4838400, 8600)
    constructor(address _token, uint256[] memory _lockupPeriod, uint256[] memory _percentage) {
        token = _token;
        require(_lockupPeriod.length == _percentage.length, "INVALID_LENGTH");
        for (uint8 _i; _i < _lockupPeriod.length; _i++) {
            createPool(_lockupPeriod[_i], _percentage[_i], 0);            
        }
    }

    function getAllPools() external view returns (PoolInfo[] memory) {
        return pools;
    }

    function createPool(uint256 _lockupSeconds, uint256 _percentage, uint8 _addedAPR) public onlyOwner {
        require(_totalPercentages + _percentage <= FACTOR, "max percentage");
        _totalPercentages += _percentage;
        pools.push(
            PoolInfo({
                lockupPeriod: _lockupSeconds,
                percentage: _percentage,
                totalStakedUsers: 0,
                totalSharesDeposited: 0,
                rewardsPerShare: 0,
                totalDistributed: 0,
                totalRewards: 0
            })
        );
        if (address(extension) != address(0)) {
            try extension.addTokenPool(_addedAPR) {} catch {}
        }
    }

    function removePool(uint256 _idx) external onlyOwner {
        PoolInfo memory _pool = pools[_idx];
        _totalPercentages -= _pool.percentage;
        pools[_idx] = pools[pools.length - 1];
        pools.pop();
    }

    function stake(uint256 pid, uint256 _amount) external nonReentrant {
        IERC20(token).safeTransferFrom(_msgSender(), address(this), _amount);
        _setShare(pid, _msgSender(), _amount, false);
    }

    function stakeForWallets(uint256 pid, address[] memory _wallets, uint256[] memory _amounts) external nonReentrant {
        require(_wallets.length == _amounts.length, "INSYNC");
        uint256 _totalAmount;
        for (uint256 _i; _i < _wallets.length; _i++) {
            _totalAmount += _amounts[_i];
            _setShare(pid, _wallets[_i], _amounts[_i], false);
        }
        IERC20(token).safeTransferFrom(
            _msgSender(),
            address(this),
            _totalAmount
        );
    }

    function unstake(uint256 pid, uint256 _amount) external nonReentrant {
        IERC20(token).safeTransfer(_msgSender(), _amount);
        _setShare(pid, _msgSender(), _amount, true);
    }

    function _setShare(uint256 pid, address wallet, uint256 balanceUpdate, bool isRemoving) internal {
        if (address(extension) != address(0)) {
            try extension.setShare(pid, wallet, balanceUpdate, isRemoving) {} catch {}
        }
        if (isRemoving) {
            _removeShares(pid, wallet, balanceUpdate);
            emit Unstake(pid, wallet, balanceUpdate);
        } else {
            _addShares(pid, wallet, balanceUpdate);
            emit Stake(pid, wallet, balanceUpdate);
        }
    }

    function _addShares(uint256 pid, address wallet, uint256 amount) private {
        if (shares[wallet][pid].amount > 0) {
            _distributeReward(pid, wallet, false, 0);
        }
        uint256 sharesBefore = shares[wallet][pid].amount;
        pools[pid].totalSharesDeposited += amount;
        shares[wallet][pid].amount += amount;
        shares[wallet][pid].stakedTime = block.timestamp;
        if (sharesBefore == 0 && shares[wallet][pid].amount > 0) {
            pools[pid].totalStakedUsers++;
        }
        rewards[wallet][pid].excluded = _cumulativeRewards(
            pid,
            shares[wallet][pid].amount
        );
    }

    function _removeShares(uint256 pid, address wallet, uint256 amount) private {
        require(
            shares[wallet][pid].amount > 0 &&
                amount <= shares[wallet][pid].amount,
            "REM: amount"
        );
        require(
            block.timestamp >
                shares[wallet][pid].stakedTime + pools[pid].lockupPeriod,
            "REM: timelock"
        );
        uint256 _unclaimed = getUnpaid(pid, wallet);
        bool _otherStakersPresent = pools[pid].totalSharesDeposited - amount >
            0;
        if (!_otherStakersPresent) {
            _distributeReward(pid, wallet, false, 0);
        }
        pools[pid].totalSharesDeposited -= amount;
        shares[wallet][pid].amount -= amount;
        if (shares[wallet][pid].amount == 0) {
            pools[pid].totalStakedUsers--;
        }
        rewards[wallet][pid].excluded = _cumulativeRewards(
            pid,
            shares[wallet][pid].amount
        );
        // if there are other stakers and unclaimed rewards,
        // deposit them back into the pool for other stakers to claim
        if (_otherStakersPresent && _unclaimed > 0) {
            _depositRewards(pid, wallet, _unclaimed);
        }
    }

    function depositRewards() external payable {
        require(msg.value > 0, "no rewards");
        uint256 _totalETH;
        for (uint256 _i; _i < pools.length; _i++) {
            uint256 _totalBefore = _totalETH;
            _totalETH += (msg.value * pools[_i].percentage) / FACTOR;
            _depositRewards(_i, _msgSender(), _totalETH - _totalBefore);
        }
        uint256 _refund = msg.value - _totalETH;
        if (_refund > 0) {
            (bool _refunded, ) = payable(_msgSender()).call{value: _refund}("");
            require(_refunded, "could not refund");
        }
    }

    function _depositRewards(uint256 pid, address _wallet, uint256 _amountETH) internal {
        require(_amountETH > 0, "ETH");
        require(pools[pid].totalSharesDeposited > 0, "SHARES");
        pools[pid].totalRewards += _amountETH;
        pools[pid].rewardsPerShare += (MULTIPLIER * _amountETH) / pools[pid].totalSharesDeposited;
        emit DepositRewards(pid, _wallet, _amountETH);
    }

    function _distributeReward(uint256 pid, address _wallet, bool _compound, uint256 _compoundMinTokensToReceive) internal {
        if (shares[_wallet][pid].amount == 0) {
            return;
        }
        shares[_wallet][pid].stakedTime = block.timestamp; // reset every claim
        uint256 _amountWei = getUnpaid(pid, _wallet);
        rewards[_wallet][pid].realised += _amountWei;
        rewards[_wallet][pid].excluded = _cumulativeRewards(pid, shares[_wallet][pid].amount);
        if (_amountWei > 0) {
            pools[pid].totalDistributed += _amountWei;
            if (_compound) {
                _compoundRewards(pid, _wallet, _amountWei, _compoundMinTokensToReceive);
            } else {
                uint256 _balBefore = address(this).balance;
                (bool success, ) = payable(_wallet).call{value: _amountWei}("");
                require(success, "DIST0");
                require(address(this).balance >= _balBefore - _amountWei, "DIST1");
            }
            emit DistributeReward(pid, _wallet, _amountWei, _compound);
        }
    }

    function _compoundRewards(uint256 pid, address _wallet, uint256 _wei, uint256 _minTokensToReceive) internal {
        address[] memory path = new address[](2);
        path[0] = _router.WETH();
        path[1] = token;

        IERC20 _token = IERC20(token);
        uint256 _tokenBalBefore = _token.balanceOf(address(this));
        _router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: _wei}(
            _minTokensToReceive,
            path,
            address(this),
            block.timestamp
        );
        uint256 _compoundAmount = _token.balanceOf(address(this)) - _tokenBalBefore;
        _setShare(pid, _wallet, _compoundAmount, false);
    }

    function claimReward(uint256 pid, bool _compound, uint256 _compMinTokensToReceive) external nonReentrant {
        _distributeReward(pid, _msgSender(), _compound, _compMinTokensToReceive);
        emit ClaimReward(pid, _msgSender());
    }

    function claimRewardAdmin(
        uint256 pid,
        address _wallet,
        bool _compound,
        uint256 _compMinTokensToReceive
    ) external nonReentrant onlyOwner {
        _distributeReward(pid, _wallet, _compound, _compMinTokensToReceive);
        emit ClaimReward(pid, _wallet);
    }

    function getUnpaid(uint256 pid, address wallet) public view returns (uint256) {
        if (shares[wallet][pid].amount == 0) {
            return 0;
        }
        uint256 earnedRewards = _cumulativeRewards(
            pid,
            shares[wallet][pid].amount
        );
        uint256 rewardsExcluded = rewards[wallet][pid].excluded;
        if (earnedRewards <= rewardsExcluded) {
            return 0;
        }
        return earnedRewards - rewardsExcluded;
    }

    function _cumulativeRewards(uint256 pid, uint256 share) internal view returns (uint256) {
        return (share * pools[pid].rewardsPerShare) / MULTIPLIER;
    }

    function setPoolExtension(IPoolExtension _extension) external onlyOwner {
        extension = _extension;
    }

    function setLockupPeriods(uint256[] memory _seconds) external onlyOwner {
        for (uint256 _i; _i < _seconds.length; _i++) {
            pools[_i].lockupPeriod = _seconds[_i];
            require(_seconds[_i] < 365 days, "lte 1 year");
        }
    }

    function setPercentages(uint256[] memory _percentages) external onlyOwner {
        _totalPercentages = 0;
        for (uint256 _i; _i < _percentages.length; _i++) {
            _totalPercentages += _percentages[_i];
            pools[_i].percentage = _percentages[_i];
        }
        require(_totalPercentages <= FACTOR, "lte 100%");
    }

    function withdrawTokens(uint256 _amount) external onlyOwner {
        IERC20 _token = IERC20(token);
        _token.safeTransfer(
            _msgSender(),
            _amount == 0 ? _token.balanceOf(address(this)) : _amount
        );
    }
}

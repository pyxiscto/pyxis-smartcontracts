// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './interfaces/IPYXStaking.sol';
import './interfaces/IAutoStaking.sol';
import './interfaces/IPYXToken.sol';

contract PYXStaking is IPYXStaking, AccessControl {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    struct UserStaking {
        address account;
        uint256 steps;
        uint256 stakingId;
        uint256 startDate;
        uint256 unstakeDate;
        uint256 pyx;
        uint256 shares;
    }

    struct Settings {
        uint256 LATE_PENALTY_RATE_PER_STEP; // 1
        uint256 BASE_BONUS_STEPS; // 30
        uint256 MAX_STAKE_STEPS; // 1820
        uint256 MAX_LATE_STEPS; // 28
        uint256 STEP_SECONDS; // 86400
        uint256 BURN_PENALTY_RATE; // 5
    }

    struct Addresses {
        IPYXToken PYX_TOKEN;
        IAutoStaking AUTO_STAKING;
    }

    event Stake(
        address indexed account,
        address caller,
        uint256 steps,
        uint256 startDate,
        uint256 indexed stakingId,
        uint256 indexed shares,
        uint256 pyx,
        uint256 stakeBonus,
        uint256 daysBonus,
        uint256 totalStakedPYX,
        uint256 totalUnstakedPYX,
        uint256 totalStakedShares,
        uint256 totalUnstakedShares
    );

    event Unstake(
        address indexed account,
        uint256 unstakeDate,
        uint256 indexed stakingId,
        uint256 indexed payoutPYX,
        uint256 penaltyRate,
        uint256 penaltyPYX,
        uint256 totalStakedPYX,
        uint256 totalUnstakedPYX,
        uint256 totalStakedShares,
        uint256 totalUnstakedShares
    );

    event UnstakeFullPenalty(
        address indexed caller,
        uint256 indexed stakingId,
        uint256 date,
        uint256 indexed pyx
    );

    event AddPYXToPool(uint256 indexed pyx, address indexed caller);

    event SetAutoStaking(address indexed caller, address indexed autoStaking);

    event UpdateSettings(
        bytes32 indexed setting,
        uint256 indexed newValue,
        address indexed caller
    );

    bytes32 public constant SETTER_ROLE = keccak256('SETTER_ROLE');
    bytes32 public constant STAKER_ROLE = keccak256('STAKER_ROLE');
    bytes32 public constant PYX_ADDER_ROLE = keccak256('PYX_ADDER_ROLE');
    bytes32 public constant SETTINGS_MANAGER_ROLE =
        keccak256('SETTINGS_MANAGER_ROLE');

    // SETTINGS
    Settings public SETTINGS;
    Addresses public ADDRESSES;

    // states
    uint256 public totalStakedPYX;
    uint256 public totalUnstakedPYX;

    uint256 public interestPoolPYX;
    uint256 public totalPaidPYX;

    uint256 public totalStakedShares;
    uint256 public totalUnstakedShares;

    uint256 public currentStakingId;

    // stakingId => UserStaking
    mapping(uint256 => UserStaking) public userStakingOf;

    // account => stakingId[]
    mapping(address => EnumerableSet.UintSet) private stakingIdsOf;

    modifier onlySetter() {
        require(
            hasRole(SETTER_ROLE, msg.sender),
            'PYXStaking: Caller is not a setter'
        );
        _;
    }

    modifier onlyStaker() {
        require(
            hasRole(STAKER_ROLE, msg.sender),
            'PYXStaking: Caller is not a staker'
        );
        _;
    }

    modifier onlyPYXAdder() {
        require(
            hasRole(PYX_ADDER_ROLE, msg.sender),
            'PYXStaking: Caller is not a pyx adder'
        );
        _;
    }

    modifier onlySettingsManager() {
        require(
            hasRole(SETTINGS_MANAGER_ROLE, msg.sender),
            'PYXStaking: Caller is not a settings manager'
        );
        _;
    }

    constructor() public {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(SETTER_ROLE, msg.sender);
    }

    function init(
        address _pyxToken,
        address _autoStaking,
        uint256 _latePenaltyRatePerStep,
        uint256 _maxStakeSteps,
        uint256 _maxLateSteps,
        uint256 _baseBonusSteps,
        uint256 _stepSeconds,
        uint256 _burnPenaltyRate,
        address[] calldata _stakerAccounts,
        address[] calldata _pyxAdderAccounts
    ) external onlySetter {
        ADDRESSES.PYX_TOKEN = IPYXToken(_pyxToken);
        ADDRESSES.AUTO_STAKING = IAutoStaking(_autoStaking);

        SETTINGS.STEP_SECONDS = _stepSeconds;
        SETTINGS.MAX_STAKE_STEPS = _maxStakeSteps;
        SETTINGS.MAX_LATE_STEPS = _maxLateSteps;
        SETTINGS.LATE_PENALTY_RATE_PER_STEP = _latePenaltyRatePerStep;
        SETTINGS.BASE_BONUS_STEPS = _baseBonusSteps;
        SETTINGS.BURN_PENALTY_RATE = _burnPenaltyRate;

        for (uint256 idx = 0; idx < _stakerAccounts.length; idx = idx.add(1)) {
            _setupRole(STAKER_ROLE, _stakerAccounts[idx]);
        }

        for (
            uint256 idx = 0;
            idx < _pyxAdderAccounts.length;
            idx = idx.add(1)
        ) {
            _setupRole(PYX_ADDER_ROLE, _pyxAdderAccounts[idx]);
        }

        renounceRole(SETTER_ROLE, msg.sender);
    }

    function userStake(uint256 _stakeSteps, uint256 _pyx) external {
        // pyx - burn
        ADDRESSES.PYX_TOKEN.burn(msg.sender, _pyx);

        _stake(msg.sender, _stakeSteps, _pyx, 0);

        // add PYX to the "for sale pool"
        ADDRESSES.AUTO_STAKING.addInflatedForSalePYX(_stakeSteps, _pyx);
    }

    /* contract must burn the tokens before calling this method */
    function contractStake(
        address _account,
        uint256 _stakeSteps,
        uint256 _stakedPYX,
        uint256 _rewardPYX,
        uint256 _stakeBonus
    ) external override onlyStaker {
        _stake(_account, _stakeSteps, _stakedPYX, _stakeBonus);

        if (_rewardPYX != 0) {
            _addPYXToPool(_rewardPYX);
        }
    }

    function _stake(
        address userAccount,
        uint256 _stakeSteps,
        uint256 _pyx,
        uint256 _stakeBonus
    ) private {
        require(_stakeSteps > 0, 'PYXStaking[stake]: _stakeSteps <= 0');
        require(_pyx > 0, 'PYXStaking[stake]: _pyx <= 0');
        require(
            _stakeSteps <= SETTINGS.MAX_STAKE_STEPS,
            'Staking[stake]: _stakeSteps > SETTINGS.MAX_STAKE_STEPS'
        );

        (uint256 shares, uint256 daysBonus) =
            getShares(_stakeSteps, _pyx, _stakeBonus);
        uint256 startDate = block.timestamp;

        // state - update
        uint256 stakingId = currentStakingId;
        userStakingOf[currentStakingId] = UserStaking({
            account: userAccount,
            steps: _stakeSteps,
            stakingId: stakingId,
            startDate: startDate,
            unstakeDate: 0,
            pyx: _pyx,
            shares: shares
        });
        stakingIdsOf[userAccount].add(currentStakingId);

        totalStakedPYX = totalStakedPYX.add(_pyx);
        totalStakedShares = totalStakedShares.add(shares);

        currentStakingId = currentStakingId.add(1);

        // [event]
        emit Stake(
            userAccount,
            msg.sender,
            _stakeSteps,
            startDate,
            stakingId,
            shares,
            _pyx,
            _stakeBonus,
            daysBonus,
            totalStakedPYX,
            totalUnstakedPYX,
            totalStakedShares,
            totalUnstakedShares
        );
    }

    function unstake(uint256 stakingId) external {
        UserStaking storage userStaking = userStakingOf[stakingId];
        address userAccount = msg.sender;

        require(
            userStaking.account == userAccount,
            'PYXStaking[unstake]: userStaking.account != userAccount'
        );
        require(
            userStaking.unstakeDate == 0,
            'PYXStaking[unstake]: userStaking.unstakeDate != 0'
        );

        uint256 pyxLeftInPool = interestPoolPYX.sub(totalPaidPYX);
        uint256 sharesLeft = totalStakedShares.sub(totalUnstakedShares);

        uint256 fullStakedBonusPYX =
            pyxLeftInPool.mul(userStaking.shares).div(sharesLeft);

        uint256 fullPayoutWithoutPenalty =
            userStaking.pyx.add(fullStakedBonusPYX);

        uint256 actualStakeSteps = getActualSteps(userStaking.startDate);
        uint256 penaltyRateWei =
            getPenaltyRateWei(userStaking.startDate, userStaking.steps);
        uint256 ratePYXToGetBack = uint256(1e18).sub(penaltyRateWei);
        uint256 payoutPYX = 0;

        if (actualStakeSteps < userStaking.steps) {
            payoutPYX = userStaking.pyx.mul(ratePYXToGetBack).div(1e18);
        } else {
            payoutPYX = (userStaking.pyx.add(fullStakedBonusPYX))
                .mul(ratePYXToGetBack)
                .div(1e18);
        }
        uint256 penaltyPYX = fullPayoutWithoutPenalty.sub(payoutPYX);

        if (payoutPYX > 0) {
            // pyx - mint
            ADDRESSES.PYX_TOKEN.mint(userAccount, payoutPYX);
        }

        if (penaltyPYX > 0) {
            _addPYXToPool(
                penaltyPYX
                    .mul(uint256(100).sub(SETTINGS.BURN_PENALTY_RATE))
                    .div(100)
            );
        }

        // state - update
        uint256 unstakeDate = block.timestamp;
        userStaking.unstakeDate = unstakeDate;

        totalUnstakedPYX = totalUnstakedPYX.add(userStaking.pyx);
        totalUnstakedShares = totalUnstakedShares.add(userStaking.shares);
        totalPaidPYX = totalPaidPYX.add(fullStakedBonusPYX);

        // [event]
        emit Unstake(
            userAccount,
            unstakeDate,
            userStaking.stakingId,
            payoutPYX,
            penaltyRateWei,
            penaltyPYX,
            totalStakedPYX,
            totalUnstakedPYX,
            totalStakedShares,
            totalUnstakedShares
        );
    }

    function unstakeFullPenalty(uint256 stakingId) external {
        UserStaking storage userStaking = userStakingOf[stakingId];

        require(
            userStaking.unstakeDate == 0,
            'PYXStaking[unstakeFullPenalty]: userStaking.unstakeDate != 0'
        );

        uint256 endDate =
            userStaking.startDate.add(
                (SETTINGS.STEP_SECONDS.mul(userStaking.steps))
            );
        require(
            block.timestamp > endDate,
            'PYXStaking[unstakeFullPenalty]: the stake is not ended yet'
        );

        uint256 penaltyRate =
            getPenaltyRateWei(userStaking.startDate, userStaking.steps);

        require(
            penaltyRate == 1e18,
            'PYXStaking[unstakeFullPenalty]: the stake is not full penalty'
        );

        uint256 unstakeDate = block.timestamp;

        // state - update
        userStaking.unstakeDate = unstakeDate;
        totalUnstakedPYX = totalUnstakedPYX.add(userStaking.pyx);
        totalUnstakedShares = totalUnstakedShares.add(userStaking.shares);

        _addPYXToPool(userStaking.pyx);

        emit UnstakeFullPenalty(
            msg.sender,
            stakingId,
            unstakeDate,
            userStaking.pyx
        );
    }

    function userAddPYXToPool(uint256 _pyx) external {
        ADDRESSES.PYX_TOKEN.burn(msg.sender, _pyx);

        _addPYXToPool(_pyx);
    }

    /** Settings */
    function setAutoStaking(address _autoStaking) external onlySettingsManager {
        ADDRESSES.AUTO_STAKING = IAutoStaking(_autoStaking);
        emit SetAutoStaking(msg.sender, _autoStaking);
    }

    function setLatePenaltyRatePerStep(uint256 _rate)
        external
        onlySettingsManager
    {
        SETTINGS.LATE_PENALTY_RATE_PER_STEP = _rate;
        emit UpdateSettings('LATE_PENALTY_RATE_PER_STEP', _rate, msg.sender);
    }

    function setBaseBonusSteps(uint256 _steps) external onlySettingsManager {
        SETTINGS.BASE_BONUS_STEPS = _steps;
        emit UpdateSettings('BASE_BONUS_STEPS', _steps, msg.sender);
    }

    function setMaxStakeSteps(uint256 _steps) external onlySettingsManager {
        SETTINGS.MAX_STAKE_STEPS = _steps;
        emit UpdateSettings('MAX_STAKE_STEPS', _steps, msg.sender);
    }

    function setMaxLateSteps(uint256 _steps) external onlySettingsManager {
        SETTINGS.MAX_LATE_STEPS = _steps;
        emit UpdateSettings('MAX_LATE_STEPS', _steps, msg.sender);
    }

    function setBurnPenaltyRate(uint256 _rate) external onlySettingsManager {
        SETTINGS.BURN_PENALTY_RATE = _rate;
        emit UpdateSettings('BURN_PENALTY_RATE', _rate, msg.sender);
    }

    /* end settings */

    /* contract must burn the tokens before calling this method */
    function contractAddPYXToPool(uint256 _pyx) external override onlyPYXAdder {
        _addPYXToPool(_pyx);
    }

    function _addPYXToPool(uint256 _pyx) private {
        interestPoolPYX = interestPoolPYX.add(_pyx);

        // [event]
        emit AddPYXToPool(_pyx, msg.sender);
    }

    /*
     * 100% = 1e18
     */
    function getPenaltyRateWei(uint256 _startDate, uint256 expectedSteps)
        public
        view
        returns (uint256)
    {
        uint256 actualSteps = getActualSteps(_startDate);

        // no penalty
        if (actualSteps == expectedSteps) {
            return 0;
        }

        // early penalty
        if (actualSteps < expectedSteps) {
            return
                (expectedSteps.sub(actualSteps)).mul(1e18).div(expectedSteps);
        }

        // late penalty
        uint256 lateSteps = actualSteps.sub(expectedSteps);

        if (lateSteps <= SETTINGS.MAX_LATE_STEPS) {
            return 0;
        }
        uint256 penaltyLateSteps = lateSteps.sub(SETTINGS.MAX_LATE_STEPS);

        uint256 latePenalty =
            penaltyLateSteps.mul(1e16).div(SETTINGS.LATE_PENALTY_RATE_PER_STEP);

        if (latePenalty > 1e18) {
            return 1e18;
        }

        return latePenalty;
    }

    function getActualSteps(uint256 _startDate) public view returns (uint256) {
        return (block.timestamp.sub(_startDate)).div(SETTINGS.STEP_SECONDS);
    }

    function getShares(
        uint256 _stakeSteps,
        uint256 _pyx,
        uint256 _stakeBonus // 0, 20
    ) public view returns (uint256 shares, uint256 daysBonus) {
        uint256 base = _stakeSteps.mul(_pyx);
        uint256 stakeBonus = (_stakeBonus.add(100));
        daysBonus = getDaysBonus(_stakeSteps);
        shares = base.mul(stakeBonus).mul(daysBonus).div(1e20);
    }

    function getDaysBonus(uint256 _stakeSteps) public view returns (uint256) {
        uint256 bonusScore =
            _stakeSteps.mul(1e9).div(SETTINGS.BASE_BONUS_STEPS);
        uint256 bonusBase = bonusScore.add(100e9);

        return bonusBase.mul(bonusBase).div(1e18);
    }

    function getUserStakingCount(address _account)
        external
        view
        returns (uint256)
    {
        return stakingIdsOf[_account].length();
    }

    function getUserStakingId(address _account, uint256 idx)
        external
        view
        returns (uint256)
    {
        return stakingIdsOf[_account].at(idx);
    }
}

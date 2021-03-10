// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';
import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';

import './interfaces/IAutoStaking.sol';
import './interfaces/IPYXStaking.sol';
import './interfaces/IPYXToken.sol';

/**
 * this contract is to convert ETH into PYX and then stake interfaces
 * the PYX is purchased from pancakeswap for the market price and then staked.
 */
contract ETHAutoStaking is AccessControl, IAutoStaking {
    using SafeMath for uint256;

    struct Settings {
        uint256 MIN_AUTO_STAKE_STEPS; // 90
        uint256 STAKE_BONUS; // 20
        uint256 INFLATION_RATE; // 12
        uint256 INFLATION_RATE_DIVIDER; // 364
        uint256 STEP_SECONDS; // 86400
    }

    struct Addresses {
        IPYXToken PYX_TOKEN;
        IPYXStaking PYX_STAKING;
        IUniswapV2Router02 UNISWAP;
        address RECIPIENT;
    }

    event ETHStake(
        address indexed account,
        uint256 indexed eth,
        uint256 indexed buyBackPYX,
        uint256 pyx
    );

    event AddForSalePYX(
        address indexed account,
        uint256 indexed pyx,
        uint256 indexed totalForSalePYX
    );

    event AddInflatedForSalePYX(
        address indexed account,
        uint256 indexed pyx,
        uint256 indexed totalForSalePYX
    );

    event WithdrawSlippagePYX(
        uint256 indexed pyx,
        address indexed recipient,
        address indexed account
    );

    event UpdateSettings(bytes32 indexed setting, uint256 indexed newValue);

    // constants
    bytes32 public constant SETTER_ROLE = keccak256('SETTER_ROLE');
    bytes32 public constant PYX_ADDER_ROLE = keccak256('PYX_ADDER_ROLE');
    bytes32 public constant SETTINGS_MANAGER_ROLE =
        keccak256('SETTINGS_MANAGER_ROLE');

    // settings
    Settings public SETTINGS;
    Addresses public ADDRESSES;
    // numDay => open
    mapping(uint256 => bool) public IS_OPEN_OF;

    // states
    uint256 public totalForSalePYX;
    uint256 public totalSoldPYX;

    uint256 public totalSlippagePYX;
    uint256 public withdrawnSlippagePYX;

    modifier onlySetter() {
        require(
            hasRole(SETTER_ROLE, msg.sender),
            'ETHAutoStaking: Caller is not a setter'
        );
        _;
    }

    modifier onlyPYXAdder() {
        require(
            hasRole(PYX_ADDER_ROLE, msg.sender),
            'ETHAutoStaking: Caller is not a PYX adder'
        );
        _;
    }

    modifier onlySettingsManager() {
        require(
            hasRole(SETTINGS_MANAGER_ROLE, msg.sender),
            'ETHAutoStaking: Caller is not a settings manager'
        );
        _;
    }

    constructor() public {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(SETTER_ROLE, msg.sender);
    }

    function init(
        uint256 _minimumAutoStakeSteps,
        uint256 _stakeBonus,
        uint256 _inflationRate,
        uint256 _inflationRateDivider,
        uint256 _stepSeconds,
        address _pyxToken,
        address _pyxStaking,
        address _uniswap,
        address _recipient,
        address[] calldata _pyxAdderAccounts
    ) external onlySetter {
        SETTINGS.MIN_AUTO_STAKE_STEPS = _minimumAutoStakeSteps;
        SETTINGS.STAKE_BONUS = _stakeBonus;
        SETTINGS.INFLATION_RATE = _inflationRate;
        SETTINGS.INFLATION_RATE_DIVIDER = _inflationRateDivider;
        SETTINGS.STEP_SECONDS = _stepSeconds;

        IS_OPEN_OF[6] = true; // wednesday
        IS_OPEN_OF[1] = true; // friday
        IS_OPEN_OF[3] = true; // sunday

        ADDRESSES.PYX_TOKEN = IPYXToken(_pyxToken);
        ADDRESSES.PYX_STAKING = IPYXStaking(_pyxStaking);
        ADDRESSES.UNISWAP = IUniswapV2Router02(_uniswap);
        ADDRESSES.RECIPIENT = _recipient;

        for (
            uint256 idx = 0;
            idx < _pyxAdderAccounts.length;
            idx = idx.add(1)
        ) {
            _setupRole(PYX_ADDER_ROLE, _pyxAdderAccounts[idx]);
        }

        renounceRole(SETTER_ROLE, msg.sender);
    }

    function ethStake(uint256 _stakeSteps, uint256 _pyxToGet) external payable {
        require(
            _stakeSteps >= SETTINGS.MIN_AUTO_STAKE_STEPS,
            'ETHAutoStaking[ethStake]: _stakeSteps < SETTINGS.MIN_AUTO_STAKE_STEPS'
        );

        uint256 numDayInWeek = getNumDayInWeek();
        require(
            IS_OPEN_OF[numDayInWeek],
            'ETHAutoStaking[ethStake]: staking closed'
        );

        uint256 pyxAvailableForSale = totalForSalePYX.sub(totalSoldPYX);
        require(
            _pyxToGet <= pyxAvailableForSale,
            'ETHAutoStaking[ethStake]: _pyxToGet > pyxAvailableForSale'
        );

        // use eth to buy from uniswap
        uint256 buyBackPYX = _buyBack(msg.value, _pyxToGet);

        // calculate fees and ref bonus
        uint256 slippagePYX = buyBackPYX.sub(_pyxToGet);

        // transfer the slippage token to the recipient
        if (slippagePYX > 0) {
            totalSlippagePYX = totalSlippagePYX.add(slippagePYX);
        }

        // state - update
        totalSoldPYX = totalSoldPYX.add(_pyxToGet);

        ADDRESSES.PYX_STAKING.contractStake(
            msg.sender,
            _stakeSteps,
            _pyxToGet,
            _pyxToGet,
            SETTINGS.STAKE_BONUS
        );

        _addInflatedForSalePYX(_stakeSteps, _pyxToGet);

        // [event]
        emit ETHStake(msg.sender, msg.value, buyBackPYX, _pyxToGet);
    }

    function withdrawSlippagePYX() external {
        uint256 slippagePYXLeft = totalSlippagePYX.sub(withdrawnSlippagePYX);
        require(
            slippagePYXLeft > 0,
            'ETHAutoStaking[withdrawSlippagePYX]: slippagePYXLeft <= 0'
        );
        ADDRESSES.PYX_TOKEN.mint(ADDRESSES.RECIPIENT, slippagePYXLeft);

        withdrawnSlippagePYX = withdrawnSlippagePYX.add(slippagePYXLeft);

        // [event]
        emit WithdrawSlippagePYX(
            slippagePYXLeft,
            ADDRESSES.RECIPIENT,
            msg.sender
        );
    }

    function addForSalePYX(uint256 _pyx) external {
        ADDRESSES.PYX_TOKEN.burn(msg.sender, _pyx);

        totalForSalePYX = totalForSalePYX.add(_pyx);

        // [event]
        emit AddForSalePYX(msg.sender, _pyx, totalForSalePYX);
    }

    /* settings */
    function addStakedDay(uint256 _day) external onlySettingsManager {
        IS_OPEN_OF[_day] = true;
        emit UpdateSettings('IS_OPEN_OF:add', _day);
    }

    function removeStakedDay(uint256 _day) external onlySettingsManager {
        delete IS_OPEN_OF[_day];
        emit UpdateSettings('IS_OPEN_OF:remove', _day);
    }

    function setMinAutoStakeSteps(uint256 _steps) external onlySettingsManager {
        SETTINGS.MIN_AUTO_STAKE_STEPS = _steps;
        emit UpdateSettings('MIN_AUTO_STAKE_STEPS', _steps);
    }

    function setStakeBonus(uint256 _bonus) external onlySettingsManager {
        SETTINGS.STAKE_BONUS = _bonus;
        emit UpdateSettings('STAKE_BONUS', _bonus);
    }

    function setInflationRate(uint256 _inflationRate)
        external
        onlySettingsManager
    {
        SETTINGS.INFLATION_RATE = _inflationRate;
        emit UpdateSettings('INFLATION_RATE', _inflationRate);
    }

    function setInflationRateDivider(uint256 _inflationRateDivider)
        external
        onlySettingsManager
    {
        SETTINGS.INFLATION_RATE_DIVIDER = _inflationRateDivider;
        emit UpdateSettings('INFLATION_RATE_DIVIDER', _inflationRateDivider);
    }

    /* end settings */

    function addInflatedForSalePYX(uint256 _stakeSteps, uint256 _pyx)
        external
        override
        onlyPYXAdder
    {
        _addInflatedForSalePYX(_stakeSteps, _pyx);
    }

    function _addInflatedForSalePYX(uint256 _stakeSteps, uint256 _pyx) private {
        uint256 inflatedPYX = getInflatedPYXAmount(_stakeSteps, _pyx);
        totalForSalePYX = totalForSalePYX.add(inflatedPYX);

        // [event]
        emit AddInflatedForSalePYX(msg.sender, inflatedPYX, totalForSalePYX);
    }

    function getInflatedPYXAmount(uint256 _stakeSteps, uint256 _pyx)
        public
        view
        returns (uint256)
    {
        return
            (_pyx.mul(_stakeSteps).mul(SETTINGS.INFLATION_RATE)).div(
                SETTINGS.INFLATION_RATE_DIVIDER.mul(100)
            );
    }

    /** timestamp 0 = 00:00:00 UTC Thursday, 1 January 1970
     * 0 - Thursday
     * 1 - Friday
     * 2 - Saturday
     * 3 - Sunday
     * 4 - Monday
     * 5 - Tuesday
     * 6 - Wednesday
     */
    function getNumDayInWeek() public view returns (uint256) {
        return (block.timestamp / SETTINGS.STEP_SECONDS) % 7;
    }

    function _buyBack(uint256 _eth, uint256 _pyxOutMin)
        private
        returns (uint256)
    {
        uint256 deadline = block.timestamp.add(uint256(60).mul(30)); // + 30 minutes

        address[] memory path = new address[](2);
        path[0] = ADDRESSES.UNISWAP.WETH();
        path[1] = address(ADDRESSES.PYX_TOKEN);

        ADDRESSES.UNISWAP.swapExactETHForTokens{value: _eth}(
            _pyxOutMin,
            path,
            address(this),
            deadline
        );

        uint256 buyBackPYX = ADDRESSES.PYX_TOKEN.getBalanceOf(address(this));

        // pyx - burn
        ADDRESSES.PYX_TOKEN.burn(address(this), buyBackPYX);

        return buyBackPYX;
    }
}

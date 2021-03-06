// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './interfaces/ICMPSToken.sol';
import './interfaces/IPYXToken.sol';
import './interfaces/IPYXStaking.sol';

/** A contract to swap CMPS(Presale token) to PYX(Main token) */
contract CMPSToPYXSwapper is AccessControl {
    using SafeMath for uint256;

    struct Settings {
        uint256 STEP_SECONDS;
        uint256 START_DATE;
        uint256 END_DATE;
        uint256 TOTAL_CMPS_SUPPLY; // WEI Unit
    }

    struct Addresses {
        ICMPSToken CMPS_TOKEN;
        IPYXToken PYX_TOKEN;
        IPYXStaking PYX_STAKING;
    }

    event Swap(
        address indexed account,
        uint256 cmps,
        uint256 indexed pyx,
        uint256 indexed penaltyCMPS,
        uint256 penaltyRate
    );

    event MoveUnswappedToken(address indexed account, uint256 indexed cmps);

    // constants
    bytes32 public constant SETTER_ROLE = keccak256('SETTER_ROLE');

    // settings
    Settings public SETTINGS;
    Addresses public ADDRESSES;

    // states
    uint256 public totalSwappedCMPS; // WEI Unit

    bool public unswappedCMPSMoved;

    modifier onlySetter() {
        require(
            hasRole(SETTER_ROLE, msg.sender),
            'CMPSSwapper: Caller is not a setter'
        );
        _;
    }

    constructor() public {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(SETTER_ROLE, msg.sender);
    }

    function init(
        address _cmpsToken,
        address _pyxToken,
        address _pyxStaking,
        uint256 _stepSeconds, // the step period in seconds.
        uint256 _startDate, // start time for conversion period.
        uint256 _endDate, // end time for conversion period.
        uint256 _totalCMPSSupply // WEI Unit - the total of all CMPS tokens.
    ) external onlySetter {
        ADDRESSES.CMPS_TOKEN = ICMPSToken(_cmpsToken);
        ADDRESSES.PYX_TOKEN = IPYXToken(_pyxToken);
        ADDRESSES.PYX_STAKING = IPYXStaking(_pyxStaking);

        SETTINGS.STEP_SECONDS = _stepSeconds;
        SETTINGS.START_DATE = _startDate;
        SETTINGS.END_DATE = _endDate;
        SETTINGS.TOTAL_CMPS_SUPPLY = _totalCMPSSupply;

        renounceRole(SETTER_ROLE, msg.sender);
    }

    /**
     * Swap CMPS to PYX. Late swap penalty is increased 1% per day.
     */
    function swap(uint256 _cmps) external {
        require(!unswappedCMPSMoved, 'CMPSSwapper[swap]: unswappedCMPSMoved');
        require(_cmps > 0, 'CMPSSwapper[swap]: _cmps <= 0');

        // adjust the amount to mint using the penalty rate.
        uint256 penaltyRate = getPenaltyRate();
        uint256 penaltyCMPS = _cmps.mul(penaltyRate).div(100);
        uint256 toMintPYX = _cmps.sub(penaltyCMPS);
        address sender = msg.sender;

        // [state] - update
        totalSwappedCMPS = totalSwappedCMPS.add(_cmps);
        // [burn] - CMPS
        ADDRESSES.CMPS_TOKEN.burn(sender, _cmps);
        // [mint] - PYX
        ADDRESSES.PYX_TOKEN.mint(sender, toMintPYX);

        // move penalty to staking reward pool
        if (penaltyCMPS > 0) {
            ADDRESSES.PYX_STAKING.contractAddPYXToPool(penaltyCMPS);
        }

        // [event]
        emit Swap(sender, _cmps, toMintPYX, penaltyCMPS, penaltyRate);
    }

    // This method can be called only once after the penaltyRate == 100
    function moveUnswappedToken() external {
        require(
            !unswappedCMPSMoved,
            'CMPSSwapper[moveUnswappedToken]: unswappedCMPSMoved'
        );
        require(
            getPenaltyRate() == 100,
            'CMPSSwapper[moveUnswappedToken]: penaltyRate != 100'
        );
        uint256 unswappedCMPS =
            SETTINGS.TOTAL_CMPS_SUPPLY.sub(totalSwappedCMPS);
        require(
            unswappedCMPS > 0,
            'CMPSSwapper[moveUnswappedToken]: unswappedCMPS <= 0'
        );
        // CMPS 1:1 PYX
        ADDRESSES.PYX_STAKING.contractAddPYXToPool(unswappedCMPS);

        // [event]
        emit MoveUnswappedToken(msg.sender, unswappedCMPS);

        // state - update
        unswappedCMPSMoved = true;
    }

    function getPenaltyRate() public view returns (uint256) {
        uint256 blockTime = block.timestamp;

        if (blockTime < SETTINGS.START_DATE.add(SETTINGS.STEP_SECONDS)) {
            return 0;
        }

        if (blockTime >= SETTINGS.END_DATE) {
            return 100;
        }

        uint256 currentStep =
            blockTime.sub(SETTINGS.START_DATE).div(SETTINGS.STEP_SECONDS);
        uint256 totalSteps =
            SETTINGS.END_DATE.sub(SETTINGS.START_DATE).div(
                SETTINGS.STEP_SECONDS
            );

        return currentStep.mul(100).div(totalSteps);
    }
}

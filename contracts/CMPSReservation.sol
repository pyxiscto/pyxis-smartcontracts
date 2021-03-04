// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './interfaces/ICMPSToken.sol';

/*
 * CMPS reservation to be conducted for a limited time before PYX token goes on main net
 */
contract CMPSReservation is AccessControl {
    using SafeMath for uint256;

    struct Settings {
        uint256 CMPS_PER_ETH; // the number CMPS per ETH in eth unit
        uint256 MAX_CMPS_SUPPLY; // the max CMPS supply in eth unit
        uint256 END_DATE;
        uint256 MAX_ETH_PER_ACCOUNT; // max eth per account in wei unit
    }

    struct Addresses {
        address payable RECIPIENT_ACCOUNT;
        ICMPSToken CMPS_TOKEN;
    }

    event Reserve(
        uint256 indexed eth,
        uint256 indexed cmps,
        address indexed account
    );

    event WithdrawEth(
        uint256 indexed eth,
        address indexed recipient,
        address indexed account
    );

    // constants
    bytes32 public constant SETTER_ROLE = keccak256('SETTER_ROLE'); // renounce after init

    // settings
    Settings public SETTINGS;
    Addresses public ADDRESSES;

    // states
    uint256 public reservedCMPS;
    mapping(address => uint256) public reservedEthOf;

    modifier onlySetter() {
        require(
            hasRole(SETTER_ROLE, msg.sender),
            'CMPSReservation: Caller is not a setter'
        );
        _;
    }

    constructor() public {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(SETTER_ROLE, msg.sender);
    }

    function init(
        uint256 _cmpsPerEth, // the number CMPS per ETH in eth unit
        uint256 _maxCMPSSupply, // the max CMPS supply in eth unit
        uint256 _endDate, // end date of the reservation period
        uint256 _maxEthPerAccount, // max eth per account in eth unit
        address _cmpsToken,
        address payable _recipientAccount
    ) external onlySetter {
        SETTINGS.CMPS_PER_ETH = _cmpsPerEth;
        SETTINGS.MAX_CMPS_SUPPLY = _maxCMPSSupply;
        SETTINGS.MAX_ETH_PER_ACCOUNT = _maxEthPerAccount.mul(1e18); // convert eth per account to wei per account
        SETTINGS.END_DATE = _endDate;

        ADDRESSES.RECIPIENT_ACCOUNT = _recipientAccount;
        ADDRESSES.CMPS_TOKEN = ICMPSToken(_cmpsToken);

        renounceRole(SETTER_ROLE, msg.sender);
    }

    /* reserve() to reserve CMPS tokens for the presale price in eth unit */
    function reserve() external payable {
        require(msg.value > 0, 'CMPSReservation[reserve]: msg.value <= 0');
        require(
            block.timestamp <= SETTINGS.END_DATE,
            'CMPSReservation[reserve]: block.timestamp > END_DATE'
        );

        // make sure the total reserved is not over the _maxEthPerAccount a restriction on whales
        uint256 newReservedEth = reservedEthOf[msg.sender] + msg.value;
        require(
            newReservedEth <= SETTINGS.MAX_ETH_PER_ACCOUNT,
            'CMPSReservation[reserve]: newReservedEth > MAX_ETH_PER_ACCOUNT'
        );

        uint256 mintAmount = SETTINGS.CMPS_PER_ETH * msg.value;
        uint256 newReservedCMPS = reservedCMPS + mintAmount;

        // make sure we haven't exceeded the max supply of CMPS
        require(
            newReservedCMPS <= SETTINGS.MAX_CMPS_SUPPLY * 1e18,
            'CMPSReservation[reserve]: newReservedCMPS > MAX_CMPS_SUPPLY'
        );

        // cmps - mint
        ADDRESSES.CMPS_TOKEN.mint(msg.sender, mintAmount);

        // [state] - reservedCMPS
        reservedCMPS = newReservedCMPS;

        // [state] - reservedEthOf
        reservedEthOf[msg.sender] = newReservedEth;

        // [event]
        emit Reserve(msg.value, mintAmount, msg.sender);
    }

    function withdrawEth() external {
        uint256 contractEth = address(this).balance; // current eth amount of this contract
        ADDRESSES.RECIPIENT_ACCOUNT.transfer(contractEth); // transfer all eth to the recipient

        // [event]
        emit WithdrawEth(contractEth, ADDRESSES.RECIPIENT_ACCOUNT, msg.sender);
    }
}

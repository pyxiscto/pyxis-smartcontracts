// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './interfaces/ICMPSToken.sol';

/** a contract for presalers to purcahse CMPS using BNB
 *  note: CMPS is a presale token, it has no value and need to be swapped to PYX token.
 */
contract CMPSReservation is AccessControl {
    using SafeMath for uint256;

    struct Settings {
        uint256 CMPS_PER_ETH; // ETH Unit
        uint256 MAX_CMPS_SUPPLY; // WEI Unit
        uint256 MAX_ETH_PER_ACCOUNT; // WEI Unit
        uint256 END_DATE; // End date of the presale
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
        uint256 _cmpsPerEth, // ETH Unit
        uint256 _maxCMPSSupply, // ETH Unit
        uint256 _endDate,
        uint256 _maxEthPerAccount, // ETH Unit
        address _cmpsToken,
        address payable _recipientAccount
    ) external onlySetter {
        SETTINGS.CMPS_PER_ETH = _cmpsPerEth;
        SETTINGS.MAX_CMPS_SUPPLY = _maxCMPSSupply.mul(1e18); // convert ETH unit to WEI unit
        SETTINGS.MAX_ETH_PER_ACCOUNT = _maxEthPerAccount.mul(1e18); // convert ETH unit to WEI unit
        SETTINGS.END_DATE = _endDate;

        ADDRESSES.RECIPIENT_ACCOUNT = _recipientAccount;
        ADDRESSES.CMPS_TOKEN = ICMPSToken(_cmpsToken);

        // revoke setter
        renounceRole(SETTER_ROLE, msg.sender);
    }

    /** external method for the presalers to purchase CMPS using BNB */
    function reserve() external payable {
        require(msg.value > 0, 'CMPSReservation[reserve]: msg.value <= 0');
        require(
            block.timestamp <= SETTINGS.END_DATE,
            'CMPSReservation[reserve]: block.timestamp > END_DATE'
        );

        // make sure the total reserved is not over the MAX_ETH_PER_ACCOUNT
        uint256 newReservedEth = reservedEthOf[msg.sender].add(msg.value);
        require(
            newReservedEth <= SETTINGS.MAX_ETH_PER_ACCOUNT,
            'CMPSReservation[reserve]: newReservedEth > MAX_ETH_PER_ACCOUNT'
        );

        uint256 mintAmount = SETTINGS.CMPS_PER_ETH.mul(msg.value);
        uint256 newReservedCMPS = reservedCMPS.add(mintAmount);

        // make sure we haven't exceeded the max supply of CMPS
        require(
            newReservedCMPS <= SETTINGS.MAX_CMPS_SUPPLY,
            'CMPSReservation[reserve]: newReservedCMPS > MAX_CMPS_SUPPLY'
        );

        // [mint] - CMPS
        ADDRESSES.CMPS_TOKEN.mint(msg.sender, mintAmount);

        // [state] - reservedCMPS
        reservedCMPS = newReservedCMPS;

        // [state] - reservedEthOf
        reservedEthOf[msg.sender] = newReservedEth;

        // [event]
        emit Reserve(msg.value, mintAmount, msg.sender);
    }

    function withdrawEth() external {
        // current eth amount of this contract
        uint256 contractEth = address(this).balance;

        // transfer all eth to the recipient
        ADDRESSES.RECIPIENT_ACCOUNT.transfer(contractEth);

        // [event]
        emit WithdrawEth(contractEth, ADDRESSES.RECIPIENT_ACCOUNT, msg.sender);
    }
}

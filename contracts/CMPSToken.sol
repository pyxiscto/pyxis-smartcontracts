// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './interfaces/ICMPSToken.sol';

/** CMPS is a presale token, it has no value and need to be swapped to Pyxis token. */
contract CMPSToken is ICMPSToken, ERC20, AccessControl {
    using SafeMath for uint256;

    bytes32 public constant MINTER_ROLE = keccak256('MINTER_ROLE'); // only smart contracts
    bytes32 public constant SETTER_ROLE = keccak256('SETTER_ROLE'); // renounce after init

    modifier onlyMinter() {
        require(
            hasRole(MINTER_ROLE, msg.sender),
            'CMPSToken: Caller is not a minter'
        );
        _;
    }

    modifier onlySetter() {
        require(
            hasRole(SETTER_ROLE, msg.sender),
            'CMPSToken: Caller is not a setter'
        );
        _;
    }

    constructor() public ERC20('COMPASS', 'CMPS') {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(SETTER_ROLE, msg.sender);
    }

    function init(address[] calldata _minterAccounts) external onlySetter {
        /* only smart contracts can mint the token */
        for (uint256 idx = 0; idx < _minterAccounts.length; idx = idx.add(1)) {
            _setupRole(MINTER_ROLE, _minterAccounts[idx]);
        }

        /* revoke setter role */
        renounceRole(SETTER_ROLE, msg.sender);
    }

    /** only smart contracts can mint the token */
    function mint(address _to, uint256 _amount) external override onlyMinter {
        _mint(_to, _amount);
    }

    /** only smart contracts can burn the token */
    function burn(address _from, uint256 _amount) external override onlyMinter {
        _burn(_from, _amount);
    }
}

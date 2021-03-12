// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

import '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/math/SafeMath.sol';

import './interfaces/IPYXToken.sol';
import './interfaces/IPYXStaking.sol';

/** Main token of Pyxis.network */
contract PYXToken is IPYXToken, IERC20, AccessControl {
    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    event Transfer(address indexed from, address indexed to, uint256 value);

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    event AddSellingFees(
        address indexed origin,
        address indexed recipient,
        address caller,
        address sender,
        uint256 indexed amount,
        uint256 time
    );

    event SetSellFees(address indexed caller, uint256 indexed value);

    event UpdateAddress(
        bytes32 indexed setting,
        address indexed newValue,
        address indexed caller
    );

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;
    uint256 public override totalSupply;

    string public constant name = 'PYXIS';
    string public constant symbol = 'PYX';
    uint8 public constant decimals = 18;
    uint256 public SELL_FEES; // 3

    IPYXStaking public PYX_STAKING;

    EnumerableSet.AddressSet private recipientContractAddresses;
    EnumerableSet.AddressSet private senderContractAddresses;

    /* additional constants */
    bytes32 public constant MINTER_ROLE = keccak256('MINTER_ROLE'); // only smart contracts
    bytes32 public constant SETTER_ROLE = keccak256('SETTER_ROLE'); // renounce after init
    bytes32 public constant SETTINGS_MANAGER_ROLE =
        keccak256('SETTINGS_MANAGER_ROLE'); // need this to be able to extend the ecosystem.

    /* additional modifiers */
    modifier onlyMinter() {
        require(
            hasRole(MINTER_ROLE, msg.sender),
            'PYXToken: Caller is not a minter'
        );
        _;
    }

    modifier onlySetter() {
        require(
            hasRole(SETTER_ROLE, msg.sender),
            'PYXToken: Caller is not a setter'
        );
        _;
    }

    modifier onlySettingsManager() {
        require(
            hasRole(SETTINGS_MANAGER_ROLE, msg.sender),
            'PYXToken: Caller is not a settings manager'
        );
        _;
    }

    constructor() public {
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(SETTINGS_MANAGER_ROLE, msg.sender);
        _setupRole(SETTER_ROLE, msg.sender);
    }

    /* additional methods */
    function init(
        uint256 _sellFees,
        uint256 _liquidityAmount,
        address _recipient,
        address _pyxStaking,
        address[] calldata _minterAccounts
    ) external onlySetter {
        SELL_FEES = _sellFees;
        PYX_STAKING = IPYXStaking(_pyxStaking);

        /* only smart contracts can mint the token */
        for (uint256 idx = 0; idx < _minterAccounts.length; idx = idx.add(1)) {
            _setupRole(MINTER_ROLE, _minterAccounts[idx]);
        }

        // liquidity amount(eth unit) to the recipient to add the liquidity
        _mint(_recipient, _liquidityAmount.mul(1e18));

        // revoke setter role
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

    function getBalanceOf(address _account)
        external
        view
        override
        returns (uint256)
    {
        return balanceOf[_account];
    }

    /** settings */
    function setSellFees(uint256 _fees) external onlySettingsManager {
        SELL_FEES = _fees;
        emit SetSellFees(msg.sender, _fees);
    }

    function addRecipientContractAddress(address account)
        external
        onlySettingsManager
    {
        recipientContractAddresses.add(account);
        emit UpdateAddress('addRecipientContractAddress', account, msg.sender);
    }

    function removeRecipientContractAddress(address account)
        external
        onlySettingsManager
    {
        recipientContractAddresses.remove(account);
        emit UpdateAddress(
            'removeRecipientContractAddress',
            account,
            msg.sender
        );
    }

    function getRecipientContractAddressCount()
        external
        view
        returns (uint256)
    {
        return recipientContractAddresses.length();
    }

    function getRecipientContractAddress(uint256 idx)
        external
        view
        returns (address)
    {
        return recipientContractAddresses.at(idx);
    }

    function addSenderContractAddress(address account)
        external
        onlySettingsManager
    {
        senderContractAddresses.add(account);
        emit UpdateAddress('addSenderContractAddress', account, msg.sender);
    }

    function removeSenderContractAddress(address account)
        external
        onlySettingsManager
    {
        senderContractAddresses.remove(account);
        emit UpdateAddress('removeSenderContractAddress', account, msg.sender);
    }

    function getSenderContractAddressCount() external view returns (uint256) {
        return senderContractAddresses.length();
    }

    function getSenderContractAddress(uint256 idx)
        external
        view
        returns (address)
    {
        return senderContractAddresses.at(idx);
    }

    /* modified methods */
    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal virtual {
        require(sender != address(0), 'ERC20: transfer from the zero address');
        require(recipient != address(0), 'ERC20: transfer to the zero address');

        balanceOf[sender] = balanceOf[sender].sub(
            amount,
            'ERC20: transfer amount exceeds balance'
        );

        address originAddress = tx.origin;

        // buy order - recipient is the same as a person who creates the transaction.
        // * exclude smart contract addresses in our system - e.g., auto staking contract
        if (
            SELL_FEES == 0 ||
            originAddress == recipient ||
            recipientContractAddresses.contains(recipient) ||
            senderContractAddresses.contains(sender)
        ) {
            balanceOf[recipient] = balanceOf[recipient].add(amount);
        }
        // sell order - person who starts the transaction send it to someone else.
        else {
            uint256 feesAmount = amount.mul(SELL_FEES).div(100);
            balanceOf[recipient] = balanceOf[recipient].add(
                amount.sub(feesAmount)
            );
            // fees amount will be locked in the interest pool, so we burn it here
            totalSupply = totalSupply.sub(feesAmount);

            // half of the fees will be added to the staking reward pool
            // another half will be burned
            PYX_STAKING.contractAddPYXToPool(feesAmount.div(2));
            emit AddSellingFees(
                originAddress,
                recipient,
                _msgSender(),
                sender,
                feesAmount,
                block.timestamp
            );
        }
        emit Transfer(sender, recipient, amount);
    }

    /* default methods */
    function transfer(address recipient, uint256 amount)
        public
        virtual
        override
        returns (bool)
    {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(
            sender,
            _msgSender(),
            allowance[sender][_msgSender()].sub(
                amount,
                'ERC20: transfer amount exceeds allowance'
            )
        );
        return true;
    }

    function approve(address spender, uint256 amount)
        public
        virtual
        override
        returns (bool)
    {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue)
        public
        virtual
        returns (bool)
    {
        _approve(
            _msgSender(),
            spender,
            allowance[_msgSender()][spender].add(addedValue)
        );
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue)
        public
        virtual
        returns (bool)
    {
        _approve(
            _msgSender(),
            spender,
            allowance[_msgSender()][spender].sub(
                subtractedValue,
                'ERC20: decreased allowance below zero'
            )
        );
        return true;
    }

    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), 'ERC20: mint to the zero address');

        totalSupply = totalSupply.add(amount);
        balanceOf[account] = balanceOf[account].add(amount);
        emit Transfer(address(0), account, amount);
    }

    function _burn(address account, uint256 amount) internal virtual {
        require(account != address(0), 'ERC20: burn from the zero address');

        balanceOf[account] = balanceOf[account].sub(
            amount,
            'ERC20: burn amount exceeds balance'
        );
        totalSupply = totalSupply.sub(amount);
        emit Transfer(account, address(0), amount);
    }

    function _approve(
        address owner,
        address spender,
        uint256 amount
    ) internal virtual {
        require(owner != address(0), 'ERC20: approve from the zero address');
        require(spender != address(0), 'ERC20: approve to the zero address');

        allowance[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

interface IPYXToken {
    function mint(address _to, uint256 _amount) external;

    function burn(address _from, uint256 _amount) external;

    function getBalanceOf(address _account) external view returns (uint256);
}

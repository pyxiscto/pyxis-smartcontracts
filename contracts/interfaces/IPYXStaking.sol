// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;

interface IPYXStaking {
    function contractStake(
        address _account,
        uint256 _stakeSteps,
        uint256 _stakedPYX,
        uint256 _rewardPYX,
        uint256 _stakeBonus
    ) external;

    function contractAddPYXToPool(uint256 _pyx) external;
}

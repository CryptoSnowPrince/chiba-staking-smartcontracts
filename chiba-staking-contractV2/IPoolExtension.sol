// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPoolExtension {
  function setShare(
    uint256 pid,
    address wallet,
    uint256 balanceChange,
    bool isRemoving
  ) external;
  
  function addTokenPool(
    uint256 _addedAPR
  ) external;
}
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function balanceOf(address owner) external view returns (uint256);
}

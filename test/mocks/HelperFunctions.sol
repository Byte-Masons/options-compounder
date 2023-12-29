//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "oz/token/ERC20/IERC20.sol";

interface IWeth is IERC20 {
    function deposit() external payable;

    function withdraw(uint) external;
}

contract Helper {
    constructor() {}

    /** Function to get WETH from ETH
     * @param wethAddress - address of WETH contract (0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 for mainnet)
     */
    function getWethFromEth(
        address wethAddress
    ) external payable returns (uint256) {
        IWeth wEth = IWeth(wethAddress);
        wEth.deposit{value: msg.value}();
        //wEth.approve(msg.sender, wEth.balanceOf(address(this)));
        wEth.transfer(msg.sender, wEth.balanceOf(address(this)));
        return wEth.balanceOf(msg.sender);
    }
}

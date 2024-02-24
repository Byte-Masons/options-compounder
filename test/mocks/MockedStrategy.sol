// SPDX-License-Identifier: BUSL1.1

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {SwapProps, OptionsCompounder} from "../../src/OptionsCompounder.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {IOracle} from "optionsToken/src/oracles/ThenaOracle.sol";

contract MockedLendingPool {
    address optionsCompounder;

    constructor(address _optionsCompounder) {
        optionsCompounder = _optionsCompounder;
    }

    function getLendingPool() external view returns (address) {
        return address(this);
    }

    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external {
        require(
            optionsCompounder != address(0),
            "Address of strategy is not set"
        );
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = 0;
        IERC20(assets[0]).transfer(optionsCompounder, amounts[0]);
        OptionsCompounder(optionsCompounder).executeOperation(
            assets,
            amounts,
            premiums,
            msg.sender,
            params
        );
        IERC20(assets[0]).transferFrom(
            address(optionsCompounder),
            address(this),
            amounts[0] + premiums[0]
        );
    }
}

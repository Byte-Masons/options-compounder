//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {console2} from "forge-std/Test.sol";
import "./interfaces/IOptionsToken.sol";
import "aave-v2/flashloan/base/FlashLoanReceiverBase.sol";

//import "openzeppelin/token/ERC20/IERC20.sol";

//import "Swapper.sol";

contract OptionsCompounder is FlashLoanReceiverBase {
    IERC20 private paymentToken;
    IOptionsToken private optionToken;

    error OptionsCompounder__NotOption();

    constructor(
        address _paymentToken,
        address _optionToken
    ) FlashLoanReceiverBase(ILendingPoolAddressesProvider(_addressProvider)) {
        paymentToken = IERC20(_paymentToken);
        optionToken = IOptionsToken(_optionToken);
    }

    /**
        This function is called after your contract has received the flash loaned amount
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        //
        // This contract now has the funds requested.
        // Your logic goes here.
        //
        (uint256 amount, address option) = abi.decode(
            params,
            (uint256, address)
        );
        console2.log("Amount: ", amount);
        console2.log("Option: ", option);
        console2.log(
            "BalanceOfPaymentToken: ",
            paymentToken.balanceOf(address(this))
        );
        console2.log(
            "BalanceOfOptionToken: ",
            optionToken.balanceOf(address(this))
        );
        paymentToken.approve(amount, address(optionToken));
        optionToken.exercise(amount, address(this), option);
        console2.log(
            "BalanceOfPaymentToken: ",
            paymentToken.balanceOf(address(this))
        );
        console2.log(
            "BalanceOfOptionToken: ",
            optionToken.balanceOf(address(this))
        );
        // At the end of your logic above, this contract owes
        // the flashloaned amounts + premiums.
        // Therefore ensure your contract has enough to repay
        // these amounts.

        // Approve the LendingPool contract allowance to *pull* the owed amount
        for (uint i = 0; i < assets.length; i++) {
            uint amountOwing = amounts[i].add(premiums[i]);
            IERC20(assets[i]).approve(address(LENDING_POOL), amountOwing);
        }

        return true;
    }

    function myFlashLoanCall(uint256 amount, address option) public {
        if (FALSE == optionToken.isOption(option)) {
            revert OptionsCompounder__NotOption();
        }

        address receiverAddress = address(this);

        address[] memory assets = new address[](1);
        assets[0] = address(paymentToken);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = optionToken.getPaymentAmount(amount, option);

        // 0 = no debt, 1 = stable, 2 = variable
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;

        address onBehalfOf = address(this);
        bytes memory params = abi.encode(amount, option);
        uint16 referralCode = 0;

        LENDING_POOL.flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            onBehalfOf,
            params,
            referralCode
        );
    }

    function compoundOptions() external {}
}

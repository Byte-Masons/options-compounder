//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import {console2} from "forge-std/Test.sol";
import "./interfaces/IOptionsToken.sol";
import "aave-v3/flashloan/base/FlashLoanSimpleReceiverBase.sol";
import {DiscountExerciseParams} from "./interfaces/IExercise.sol";
import "./interfaces/IERC20.sol";
import {ISwapperSwaps, MinAmountOutData, MinAmountOutKind} from "./helpers/ReaperSwapper.sol";

error OptionsCompounder__NotOption();
error OptionsCompounder__NotEnoughFunsToPayFlashloan(
    uint256 fundsAvailable,
    uint256 fundsToPay
);

contract OptionsCompounder is FlashLoanSimpleReceiverBase {
    IERC20 private paymentToken;
    IERC20 private underlyingToken;
    IOptionsToken private optionToken;
    ISwapperSwaps private swapperSwaps;
    address vaultAddress = 0xBA12222222228d8Ba445958a75a0704d566BF2C8; // TODO ?? BEETx vault not a strategy vault

    address lastExecutor;
    bool flashloanFinished = true;
    mapping(address => uint256) senderToBalance;

    constructor(
        address _paymentToken,
        address _optionToken,
        address _underlyingToken,
        address _addressProvider,
        address _reaperSwapper
    ) FlashLoanSimpleReceiverBase(IPoolAddressesProvider(_addressProvider)) {
        paymentToken = IERC20(_paymentToken);
        underlyingToken = IERC20(_underlyingToken);
        optionToken = IOptionsToken(_optionToken);
        swapperSwaps = ISwapperSwaps(_reaperSwapper);
    }

    /**
        This function is called after your contract has received the flash loaned amount
     */
    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        //
        // This contract now has the funds requested.
        // Your logic goes here.
        //
        (uint256 optionsAmount, address option, address sender) = abi.decode(
            params,
            (uint256, address, address)
        );
        console2.log(
            "0.Balance of asset: ",
            IERC20(asset).balanceOf(address(this))
        );
        console2.log("Options Amount: ", optionsAmount);
        console2.log("Payment Amount: ", amount);
        console2.log("Option: ", option);
        console2.log(
            "1. BalanceOfPaymentToken: ",
            paymentToken.balanceOf(address(this))
        );
        console2.log(
            "1. BalanceOfOptionToken: ",
            IERC20(address(optionToken)).balanceOf(address(this))
        );
        paymentToken.approve(option, amount);
        bytes memory exerciseParams = abi.encode(
            DiscountExerciseParams({maxPaymentAmount: amount + 100})
        ); //Temporary magic number - later percentage relation
        optionToken.exercise(
            optionsAmount,
            address(this),
            option,
            exerciseParams,
            block.timestamp + 10
        ); //Temporary magic number
        console2.log("Initiatior: ", initiator);
        console2.log(
            "BalanceOfPaymentToken: ",
            paymentToken.balanceOf(address(this))
        );
        console2.log(
            "BalanceOfOptionToken: ",
            IERC20(address(optionToken)).balanceOf(address(this))
        );
        uint256 balanceOfUnderlyingToken = IERC20(address(underlyingToken))
            .balanceOf(address(this));
        console2.log("BalanceOfOATHToken: ", balanceOfUnderlyingToken);

        // At the end of your logic above, this contract owes
        // the flashloaned amounts + premiums.
        // Therefore ensure your contract has enough to repay
        // these amounts.

        // Approve the LendingPool contract allowance to *pull* the owed amount
        IERC20(address(underlyingToken)).approve(
            address(swapperSwaps),
            balanceOfUnderlyingToken
        );
        uint256 totalAmount = amount + premium;
        console2.log(totalAmount);
        MinAmountOutData memory minAmountOutData = MinAmountOutData(
            MinAmountOutKind.Absolute,
            0
        );
        console2.log(
            "1.Balance of asset: ",
            IERC20(asset).balanceOf(address(this))
        );
        swapperSwaps.swapBal(
            address(underlyingToken),
            asset,
            balanceOfUnderlyingToken,
            minAmountOutData,
            vaultAddress
        );
        console2.log(
            "2.Balance of asset: ",
            IERC20(asset).balanceOf(address(this))
        );
        uint256 assetBalance = IERC20(asset).balanceOf(address(this));
        if (assetBalance < totalAmount) {
            revert OptionsCompounder__NotEnoughFunsToPayFlashloan(
                assetBalance,
                totalAmount
            );
        }
        senderToBalance[sender] = assetBalance - totalAmount;
        IERC20(asset).approve(address(POOL), totalAmount);

        return true;
    }

    function myFlashLoanCall(uint256 _amount, address option) public {
        if (false == optionToken.isOption(option)) {
            revert OptionsCompounder__NotOption();
        }
        flashloanFinished = false;
        lastExecutor = msg.sender;
        address receiverAddress = address(this);
        uint16 referralCode = 0;
        uint256 paymentAmount;

        paymentAmount = optionToken.getPaymentAmount(_amount, option);

        // 0 = no debt, 1 = stable, 2 = variable
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;

        bytes memory params = abi.encode(_amount, option, msg.sender);

        POOL.flashLoanSimple(
            receiverAddress,
            address(paymentToken),
            paymentAmount,
            params,
            referralCode
        );
    }

    function withdrawProfit() external {
        uint256 allSendersFunds = senderToBalance[msg.sender];
        senderToBalance[msg.sender] = 0;
        IERC20(paymentToken).transfer(msg.sender, allSendersFunds);
    }
}

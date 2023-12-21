//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/* Imports */
import {console2} from "forge-std/Test.sol";
import "./interfaces/IOptionsToken.sol";
import "aave-v2/flashloan/base/FlashLoanReceiverBase.sol";
import {DiscountExerciseParams} from "./interfaces/IExercise.sol";
//import "./interfaces/IERC20.sol";
import {ISwapperSwaps, MinAmountOutData, MinAmountOutKind} from "./helpers/ReaperSwapper.sol";
import "openzeppelin/access/Ownable.sol";

/* Errors */
error OptionsCompounder__NotOption();
error OptionsCompounder__TooMuchAssetsLoaned();
error OptionsCompounder__NotEnoughFunds();
error OptionsCompounder__NotAStrategy();
error OptionsCompounder__StrategyNotFound();
error OptionsCompounder__StrategyAlreadyExists();
error OptionsCompounder__FlashloanNotProfitable(
    uint256 fundsAvailable,
    uint256 fundsToPay
);
address constant BEETX_VAULT_OP = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

/* Main contract */
contract OptionsCompounder is FlashLoanReceiverBase {
    /* Constants */
    uint8 constant MIN_NR_OF_FLASHLOAN_ASSETS = 1;

    /* Storages */
    IOptionsToken private optionToken;
    ISwapperSwaps private swapperSwaps;
    uint256 gain = 0;

    bool flashloanFinished = true;
    mapping(address => uint256) senderToBalance; // storage variable which tracks amount to withdraw by address

    /**
     * List of params which are initiated at the begining:
     * @param _optionToken - option token address which allows to redeem underlying token via operation "exercise"
     * @param _addressProvider - address lending pool address provider - necessary for flashloan operations
     * @param _reaperSwapper - address to contract allowing to swap tokens in easy way
     * */
    constructor(
        address _optionToken,
        address _addressProvider,
        address _reaperSwapper
    ) FlashLoanReceiverBase(ILendingPoolAddressesProvider(_addressProvider)) {
        optionToken = IOptionsToken(_optionToken);
        swapperSwaps = ISwapperSwaps(_reaperSwapper);
    }

    /***************************** Setters ***********************************/
    /* Only owner functions - in the future multi level access control*/
    /* TODO: Access control to add ! */
    function setSwapper(address _swapper) external {
        swapperSwaps = ISwapperSwaps(_swapper);
    }

    /* TODO: Access control to add ! */
    function setOptionToken(address _optionToken) external {
        optionToken = IOptionsToken(_optionToken);
    }

    /**
        @dev This function is called after your contract has received the flash loaned amount
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        if (
            assets.length > MIN_NR_OF_FLASHLOAN_ASSETS ||
            amounts.length > MIN_NR_OF_FLASHLOAN_ASSETS ||
            premiums.length > MIN_NR_OF_FLASHLOAN_ASSETS
        ) {
            revert OptionsCompounder__TooMuchAssetsLoaned();
        }
        /* Later the gain can be local variable */
        gain = exerciseOptionAndReturnDebt(
            assets[0],
            amounts[0],
            premiums[0],
            params
        );

        return true;
    }

    /**
     * @dev function initiate flashloan in order to exercise option tokens and compound rewards
     * in underlying tokens to want token
     */
    function harvestOTokens(uint256 amount, address option) external {
        if (false == optionToken.isOption(option)) {
            revert OptionsCompounder__NotOption();
        }
        console2.log(
            "Balance in this contract: ",
            IERC20(address(optionToken)).balanceOf(address(this))
        );
        IERC20 paymentToken = IERC20(optionToken.getPaymentToken(option));
        address receiverAddress = address(this);
        address onBehalfOf = address(this);
        uint16 referralCode = 0;
        uint256 initialBalance = paymentToken.balanceOf(address(this));
        flashloanFinished = false;

        address[] memory assets = new address[](1);
        assets[0] = address(paymentToken);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = optionToken.getPaymentAmount(amount, option);

        // 0 = no debt, 1 = stable, 2 = variable
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;

        bytes memory params = abi.encode(
            amount,
            option,
            msg.sender,
            initialBalance
        );

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

    /** @dev Function withdraws all profit for specific sender (based on senderToBalance mapping) */
    function withdrawProfit(address option) external {
        uint256 allSendersFunds = senderToBalance[msg.sender];
        if (allSendersFunds == 0) {
            revert OptionsCompounder__NotEnoughFunds();
        }
        senderToBalance[msg.sender] = 0;
        /* Get payment tokens again to make sure there is no change between 
        harvest and excersice */
        IERC20 paymentToken = IERC20(optionToken.getPaymentToken(option));
        IERC20(paymentToken).transfer(msg.sender, allSendersFunds);
    }

    /** @dev private function that helps to execute flashloan and makes it more modular */
    function exerciseOptionAndReturnDebt(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata params
    ) internal returns (uint256) {
        (
            uint256 optionsAmount,
            address option,
            address sender,
            uint256 initialBalance
        ) = abi.decode(params, (uint256, address, address, uint256));
        uint256 operationGain = 0;
        /* Get underlying and payment tokens again to make sure there is no change between 
        harvest and excersice */
        address underlyingToken = optionToken.getUnderlyingToken(option);
        IERC20 paymentToken = IERC20(optionToken.getPaymentToken(option));
        bytes memory exerciseParams = abi.encode(
            DiscountExerciseParams({maxPaymentAmount: amount})
        );

        // temporary logs
        console2.log(
            "[Before] BalanceOfPaymentToken: ",
            paymentToken.balanceOf(address(this))
        );
        console2.log(
            "[Before] BalanceOfOptionToken: ",
            IERC20(address(optionToken)).balanceOf(address(this))
        );

        /* Approve spending option token and exercise in order to get underlying token */
        paymentToken.approve(option, amount);
        optionToken.exercise(
            optionsAmount,
            address(this),
            option,
            exerciseParams,
            block.timestamp + 10
        ); //Temporary magic number

        // temporary logs
        console2.log(
            "[After] BalanceOfPaymentToken: ",
            paymentToken.balanceOf(address(this))
        );
        console2.log(
            "[After] BalanceOfOptionToken: ",
            IERC20(address(optionToken)).balanceOf(address(this))
        );
        uint256 balanceOfUnderlyingToken = IERC20(underlyingToken).balanceOf(
            address(this)
        );
        console2.log("[After] BalanceOfOATHToken: ", balanceOfUnderlyingToken);

        /* Calculate total amount to return */
        uint256 totalAmount = amount + premium;
        MinAmountOutData memory minAmountOutData = MinAmountOutData(
            MinAmountOutKind.Absolute,
            0 // temporar 0
        );

        /* Approve the underlying token to make swap */
        IERC20(underlyingToken).approve(
            address(swapperSwaps),
            balanceOfUnderlyingToken
        );
        /* Swap underlying token to payment token (asset) */
        // Question: Now there is an assumption that payment token is the strategy "want" token
        // If we would like to have different want token, here is the place to querry strategy about it
        // For the sake of tests it is not yet done
        swapperSwaps.swapBal(
            underlyingToken,
            asset,
            balanceOfUnderlyingToken,
            minAmountOutData,
            BEETX_VAULT_OP
        );
        console2.log(
            "2.Balance of asset: ",
            IERC20(asset).balanceOf(address(this))
        );
        /* Asset and paymentToken are the same addresses */
        /* Repay the debt and revert if it is not profitable */
        uint256 assetBalance = paymentToken.balanceOf(address(this));
        console2.log("2.Balance of paymentToken: ", assetBalance);
        console2.log("2.Amount to pay back: ", totalAmount);

        if ((assetBalance - initialBalance) <= totalAmount) {
            revert OptionsCompounder__FlashloanNotProfitable(
                (assetBalance - initialBalance),
                totalAmount
            );
        }
        /* Protected by statement above */
        operationGain = (assetBalance - initialBalance) - totalAmount;

        /* Transfer gain to the sender */
        IERC20(paymentToken).transfer(sender, operationGain);

        /* Approve lending pool to spend borrowed tokens + premium */
        IERC20(asset).approve(address(LENDING_POOL), totalAmount);

        return operationGain;
    }

    /***************************** Getters ***********************************/
    /* Temporary for testing - apy will be caluclated in vault */
    function getLastGain() external view returns (uint256) {
        return gain;
    }
}

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
error OptionsCompounder__NotEnoughFunsToPayFlashloan(
    uint256 fundsAvailable,
    uint256 fundsToPay
);

/* Main contract */
contract OptionsCompounder is FlashLoanReceiverBase, Ownable {
    /* Constants */
    uint8 constant MIN_NR_OF_FLASHLOAN_ASSETS = 1;

    /* Storages */
    IOptionsToken private optionToken;
    ISwapperSwaps private swapperSwaps;
    address private vaultAddress; // BEETx vault not a strategy vault
    address[] private strategies;
    uint256 gain = 0;

    address lastExecutor;
    bool flashloanFinished = true;
    mapping(address => uint256) senderToBalance; // storage variable which tracks amount to withdraw by address

    modifier onlyStrategy() {
        if (false == isStrategyAdded(msg.sender)) {
            revert OptionsCompounder__NotAStrategy();
        }
        _;
    }

    /**
     * List of params which are initiated at the begining:
     * @param _optionToken - option token address which allows to redeem underlying token via operation "exercise"
     * @param _addressProvider - address lending pool address provider - necessary for flashloan operations
     * @param _reaperSwapper - address to contract allowing to swap tokens in easy way
     * @param _strategies - strategies which can use this module
     * */
    constructor(
        address _optionToken,
        address _addressProvider,
        address _reaperSwapper,
        address[] memory _strategies
    )
        FlashLoanReceiverBase(ILendingPoolAddressesProvider(_addressProvider))
        Ownable(msg.sender)
    {
        optionToken = IOptionsToken(_optionToken);
        swapperSwaps = ISwapperSwaps(_reaperSwapper);

        /* address to balancer-like vault (default is address to Beetx vault on optimism chain) */
        vaultAddress = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
        for (uint8 idx = 0; idx < _strategies.length; idx++) {
            strategies.push(_strategies[idx]);
        }
    }

    /***************************** Setters ***********************************/
    /* Only owner functions */
    function addStrategy(address _strategy) external onlyOwner {
        if (false == isStrategyAdded(_strategy)) {
            strategies.push(_strategy);
        } else {
            revert OptionsCompounder__StrategyAlreadyExists();
        }
    }

    function removeStrategy(address _strategy) external onlyOwner {
        address[] memory tmpStrategies = strategies;
        bool strategyFound = false;
        for (uint8 idx = 0; idx < tmpStrategies.length; idx++) {
            if (
                (tmpStrategies[idx] == _strategy) &&
                (idx != (tmpStrategies.length - 1))
            ) {
                strategies[idx] = tmpStrategies[tmpStrategies.length - 1];
                strategyFound = true;
            }
        }
        if (false != strategyFound) {
            strategies.pop();
        } else {
            revert OptionsCompounder__StrategyNotFound();
        }
    }

    function setSwapper(address _swapper) external onlyOwner {
        swapperSwaps = ISwapperSwaps(_swapper);
    }

    function setOptionToken(address _optionToken) external onlyOwner {
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
    function harvestOTokens(
        uint256 amount,
        address option
    ) public onlyStrategy {
        if (false == optionToken.isOption(option)) {
            revert OptionsCompounder__NotOption();
        }
        IERC20(address(optionToken)).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        IERC20 paymentToken = IERC20(optionToken.getPaymentToken(option));
        address receiverAddress = address(this);
        address onBehalfOf = address(this);
        uint16 referralCode = 0;
        uint256 paymentAmount;

        flashloanFinished = false;
        lastExecutor = msg.sender;

        paymentAmount = optionToken.getPaymentAmount(amount, option);

        address[] memory assets = new address[](1);
        assets[0] = address(paymentToken);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = optionToken.getPaymentAmount(amount, option);

        // 0 = no debt, 1 = stable, 2 = variable
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;

        bytes memory params = abi.encode(amount, option, msg.sender);

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
    function withdrawProfit(address option) external onlyStrategy {
        uint256 allSendersFunds = senderToBalance[msg.sender];
        if (allSendersFunds == 0) {
            revert OptionsCompounder__NotEnoughFunds();
        }
        senderToBalance[msg.sender] = 0;
        IERC20 paymentToken = IERC20(optionToken.getPaymentToken(option));
        IERC20(paymentToken).transfer(msg.sender, allSendersFunds);
    }

    /** @dev private function that helps to execute flashloan and makes it more modular */
    function exerciseOptionAndReturnDebt(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata params
    ) private returns (uint256) {
        (uint256 optionsAmount, address option, address sender) = abi.decode(
            params,
            (uint256, address, address)
        );
        uint256 _gain = 0;
        address underlyingToken = optionToken.getUnderlyingToken(option);
        IERC20 paymentToken = IERC20(optionToken.getPaymentToken(option));
        uint256 initialBalance = paymentToken.balanceOf(address(this));
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

        /* Approve the LendingPool contract allowance to *pull* the owed amount */
        IERC20(underlyingToken).approve(
            address(swapperSwaps),
            balanceOfUnderlyingToken
        );
        /* Calculate total amount to return */
        uint256 totalAmount = amount + premium;
        MinAmountOutData memory minAmountOutData = MinAmountOutData(
            MinAmountOutKind.Absolute,
            0 // temporar 0
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
            vaultAddress
        );
        console2.log(
            "2.Balance of asset: ",
            IERC20(asset).balanceOf(address(this))
        );

        /* Repay the debt and revert if it is not profitable */
        uint256 assetBalance = paymentToken.balanceOf(address(this));
        console2.log("2.Balance of paymentToken: ", assetBalance);
        console2.log("2.Amount to pay back: ", totalAmount);

        if (assetBalance < totalAmount) {
            revert OptionsCompounder__NotEnoughFunsToPayFlashloan(
                assetBalance,
                totalAmount
            );
        }
        _gain = assetBalance - initialBalance;
        senderToBalance[sender] = assetBalance - totalAmount; // Question: still we shall use safe math ?
        IERC20(asset).approve(address(LENDING_POOL), totalAmount);

        return _gain;
    }

    /***************************** Getters ***********************************/
    function isStrategyAdded(address _strategy) public view returns (bool) {
        address[] memory tmpStrategies = strategies;
        bool strategyFound = false;
        for (uint8 idx = 0; idx < tmpStrategies.length; idx++) {
            if (tmpStrategies[idx] == _strategy) {
                strategyFound = true;
                break;
            }
        }
        return strategyFound;
    }

    function getNumberOfStrategiesAvailable() external view returns (uint256) {
        return strategies.length;
    }

    function getLastGain() external view returns (uint256) {
        return gain;
    }
}

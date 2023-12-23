//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/* Imports */
import {console2} from "forge-std/Test.sol";
import "./interfaces/IOptionsToken.sol";
import {IFlashLoanReceiver} from "aave-v2/flashloan//interfaces/IFlashLoanReceiver.sol";
import {ILendingPoolAddressesProvider} from "aave-v2/interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPool} from "aave-v2/interfaces/ILendingPool.sol";
import {DiscountExerciseParams} from "./interfaces/IExercise.sol";
import "./interfaces/IERC20.sol";
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
error OptionsCompounder__AssetNotEqualToPaymentToken();
error OptionsCompounder__NotFinished();

address constant BEETX_VAULT_OP = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

/* Main contract */
contract OptionsCompounder is IFlashLoanReceiver {
    /* Constants */
    uint8 constant MIN_NR_OF_FLASHLOAN_ASSETS = 1;

    /* Storages */
    IOptionsToken private optionToken;
    ILendingPoolAddressesProvider private addressProvider;
    ISwapperSwaps private swapperSwaps;
    ILendingPool private lendingPool;
    address wantToken;
    bool flashloanFinished;
    uint256 gain = 0; // TODO: remove at the end

    /**
     * List of params which are initiated at the begining:
     * @param _optionToken - option token address which allows to redeem underlying token via operation "exercise"
     * @param _addressProvider - address lending pool address provider - necessary for flashloan operations
     * @param _reaperSwapper - address to contract allowing to swap tokens in easy way
     * */
    // TODO: Add initializer !
    function _OptionsCompounder_Init(
        address _optionToken,
        address _addressProvider,
        address _reaperSwapper,
        address _wantToken
    ) internal {
        optionToken = IOptionsToken(_optionToken);
        addressProvider = ILendingPoolAddressesProvider(_addressProvider);
        lendingPool = ILendingPool(addressProvider.getLendingPool());
        swapperSwaps = ISwapperSwaps(_reaperSwapper);
        wantToken = _wantToken;
        flashloanFinished = true;
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
        flashloanFinished = true;
        return true;
    }

    /**
     * @dev function initiate flashloan in order to exercise option tokens and compound rewards
     * in underlying tokens to want token
     */
    function harvestOTokens(uint256 amount, address option) external {
        if (optionToken.isOption(option) == false) {
            revert OptionsCompounder__NotOption();
        }
        if (false == flashloanFinished) {
            revert OptionsCompounder__NotFinished();
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

        lendingPool.flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            onBehalfOf,
            params,
            referralCode
        );
        flashloanFinished = false;
    }

    /** @dev private function that helps to execute flashloan and makes it more modular */
    function exerciseOptionAndReturnDebt(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata params
    ) private returns (uint256) {
        (
            uint256 optionsAmount,
            address option,
            address sender,
            uint256 initialBalance
        ) = abi.decode(params, (uint256, address, address, uint256));

        uint256 gainInPaymentToken = 0;
        uint256 gainInWantToken = 0;
        /* Get underlying and payment tokens again to make sure there is no change between 
        harvest and excersice */
        address underlyingToken = optionToken.getUnderlyingToken(option);
        IERC20 paymentToken = IERC20(optionToken.getPaymentToken(option));
        /* Asset and paymentToken should be the same addresses */
        if (asset != address(paymentToken)) {
            revert OptionsCompounder__AssetNotEqualToPaymentToken();
        }
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
        // Question: Here is some room for optimization. Instead of swapping all underlying tokens
        // to payment tokens, we can swap necessary payment tokens (totalAmount) and the rest
        // underlying tokens can be swapped to the want token but swapper doesn't allow to put
        // here amountOut (it is amountIn acceptable for swapBal). Is it worth to play with this ?
        swapperSwaps.swapBal(
            underlyingToken,
            asset,
            balanceOfUnderlyingToken,
            minAmountOutData,
            BEETX_VAULT_OP
        );

        /* Console log area - temporary */
        console2.log(
            "2.Balance of underlyingToken: ",
            IERC20(underlyingToken).balanceOf(address(this))
        );
        console2.log(
            "2.Balance of wantToken: ",
            IERC20(wantToken).balanceOf(address(this))
        );
        console2.log(
            "2.Balance of paymentToken: ",
            paymentToken.balanceOf(address(this))
        );

        /* Repay the debt and revert if it is not profitable */
        uint256 assetBalance = paymentToken.balanceOf(address(this));

        if ((assetBalance - initialBalance) <= totalAmount) {
            revert OptionsCompounder__FlashloanNotProfitable(
                (assetBalance - initialBalance),
                totalAmount
            );
        }
        /* Protected by statement above */
        gainInPaymentToken = (assetBalance - initialBalance) - totalAmount;

        /* Approve the underlying token to make swap */
        IERC20(asset).approve(address(swapperSwaps), gainInPaymentToken);

        /* Transfer gain to the sender */
        swapperSwaps.swapBal(
            asset,
            wantToken,
            gainInPaymentToken,
            minAmountOutData,
            BEETX_VAULT_OP
        );

        gainInWantToken = IERC20(wantToken).balanceOf(address(this));

        /* Approve lending pool to spend borrowed tokens + premium */
        IERC20(asset).approve(address(lendingPool), totalAmount);

        /* Console log area - temporary */
        console2.log(
            "3.Balance of underlyingToken: ",
            IERC20(underlyingToken).balanceOf(address(this))
        );
        console2.log("3.Balance of wantToken: ", gainInWantToken);
        console2.log(
            "3.Balance of paymentToken: ",
            paymentToken.balanceOf(address(this))
        );
        console2.log("3.Amount paid back: ", totalAmount);

        return gainInWantToken;
    }

    /***************************** Getters ***********************************/
    /* Temporary for testing - apy will be caluclated in vault */
    function getLastGain() external view returns (uint256) {
        return gain;
    }

    function ADDRESSES_PROVIDER()
        external
        view
        returns (ILendingPoolAddressesProvider)
    {
        return addressProvider;
    }

    function LENDING_POOL() external view returns (ILendingPool) {
        return lendingPool;
    }
}

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/* Imports */
import {console2} from "forge-std/Test.sol";

import {IFlashLoanReceiver} from "aave-v2/flashloan//interfaces/IFlashLoanReceiver.sol";
import {ILendingPoolAddressesProvider} from "aave-v2/interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPool} from "aave-v2/interfaces/ILendingPool.sol";
import {DiscountExerciseParams, DiscountExercise} from "optionsToken/src/exercise/DiscountExercise.sol"; // temporary path with test relation
import {IOptionsToken} from "optionsToken/src/interfaces/IOptionsToken.sol";
import {ReaperAccessControl} from "vault-v2/mixins/ReaperAccessControl.sol";
import {ISwapperSwaps, MinAmountOutData, MinAmountOutKind} from "vault-v2/ReaperSwapper.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import "oz-upgradeable/proxy/utils/Initializable.sol";

// import "./helpers/UUPSUpgradeable.sol";

address constant BEETX_VAULT_OP = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

/* Main contract */
abstract contract OptionsCompounder is IFlashLoanReceiver, Initializable {
    /* Errors */
    error OptionsCompounder__NotExerciseContract();
    error OptionsCompounder__TooMuchAssetsLoaned();
    error OptionsCompounder__FlashloanNotProfitable();
    error OptionsCompounder__AssetNotEqualToPaymentToken();
    error OptionsCompounder__FlashloanNotFinished();
    error OptionsCompounder__OnlyKeeperAllowed();
    error OptionsCompounder__OnlyAdminsAllowed();
    error OptionsCompounder__FlashloanNotTriggered();

    /* Constants */
    uint8 constant MIN_NR_OF_FLASHLOAN_ASSETS = 1;

    /* Storages */
    ILendingPoolAddressesProvider private addressProvider;
    ILendingPool private lendingPool;
    bool private flashloanFinished;
    IOptionsToken public optionToken;
    uint256 gain = 0; // TODO: remove at the end

    /* Events */
    event OTokenCompounded(
        uint256 indexed gainInWant,
        uint256 indexed returned
    );

    /* Modifiers */
    modifier onlyKeeper() {
        if (
            _hasRoleForOptionsCompounder(getKeeperRole(), msg.sender) == false
        ) {
            revert OptionsCompounder__OnlyKeeperAllowed();
        }
        _;
    }

    modifier onlyAdmins() {
        bool hasRole = false;
        bytes32[] memory admins = getAdminRoles();
        for (uint8 idx = 0; idx < admins.length; idx++) {
            if (
                _hasRoleForOptionsCompounder(admins[idx], msg.sender) != false
            ) {
                hasRole = true;
                break;
            }
        }
        if (hasRole == false) {
            revert OptionsCompounder__OnlyAdminsAllowed();
        }
        _;
    }

    /**
     * List of params which are initiated at the begining:
     * @param _optionToken - option token address which allows to redeem underlying token via operation "exercise"
     * @param _addressProvider - address lending pool address provider - necessary for flashloan operations
     * */
    function __OptionsCompounder_init(
        address _optionToken,
        address _addressProvider
    ) internal onlyInitializing {
        optionToken = IOptionsToken(_optionToken);
        addressProvider = ILendingPoolAddressesProvider(_addressProvider);
        lendingPool = ILendingPool(addressProvider.getLendingPool());
        flashloanFinished = true;
    }

    /***************************** Setters ***********************************/
    /* Only owner functions - in the future multi level access control*/
    /**
     * @dev Sets option token address. Can be executed only by admins
     * @param _optionToken - address of option token contract
     */
    function setOptionToken(address _optionToken) external onlyAdmins {
        optionToken = IOptionsToken(_optionToken);
    }

    /**
        @dev This function is called after your contract has received the flash loaned amount
     */
    function executeOperation(
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata premiums,
        address,
        bytes calldata params
    ) external override returns (bool) {
        if (flashloanFinished != false) {
            revert OptionsCompounder__FlashloanNotTriggered();
        }
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
     * @dev Function initiate flashloan in order to exercise option tokens and compound rewards
     * in underlying tokens to want token. Can be executed only by keeper role.
     * @param amount - amount of option tokens to exercise
     * @param exerciseContract - address of exercise contract (DiscountContract)
     */
    function harvestOTokens(
        uint256 amount,
        address exerciseContract
    ) external onlyKeeper {
        if (optionToken.isExerciseContract(exerciseContract) == false) {
            revert OptionsCompounder__NotExerciseContract();
        }
        if (flashloanFinished == false) {
            revert OptionsCompounder__FlashloanNotFinished();
        }
        console2.log(
            "Balance in this contract: ",
            IERC20(address(optionToken)).balanceOf(address(this))
        );
        IERC20 paymentToken = DiscountExercise(exerciseContract).paymentToken();
        address receiverAddress = address(this);
        address onBehalfOf = address(this);
        uint16 referralCode = 0;
        uint256 initialBalance = paymentToken.balanceOf(address(this));

        address[] memory assets = new address[](1);
        assets[0] = address(paymentToken);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = DiscountExercise(exerciseContract).getPaymentAmount(
            amount
        );

        // 0 = no debt, 1 = stable, 2 = variable
        uint256[] memory modes = new uint256[](2);
        modes[0] = 0;

        bytes memory params = abi.encode(
            amount,
            exerciseContract,
            initialBalance
        );
        flashloanFinished = false;
        lendingPool.flashLoan(
            receiverAddress,
            assets,
            amounts,
            modes,
            onBehalfOf,
            params,
            referralCode
        );
    }

    /** @dev Private function that helps to execute flashloan and makes it more modular
     *  @return gainInWantToken - gain from the option exercise after repayment of all debt from flashloan
     */
    function exerciseOptionAndReturnDebt(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata params
    ) private returns (uint256) {
        (uint256 optionsAmount, address option, uint256 initialBalance) = abi
            .decode(params, (uint256, address, uint256));

        uint256 gainInPaymentToken = 0;
        uint256 gainInWantToken = 0;
        /* Get underlying and payment tokens again to make sure there is no change between 
        harvest and excersice */
        IERC20 underlyingToken = DiscountExercise(option).underlyingToken();
        IERC20 paymentToken = DiscountExercise(option).paymentToken();
        /* Asset and paymentToken should be the same addresses */
        if (asset != address(paymentToken)) {
            revert OptionsCompounder__AssetNotEqualToPaymentToken();
        }
        bytes memory exerciseParams = abi.encode(
            DiscountExerciseParams({
                maxPaymentAmount: amount,
                deadline: type(uint256).max
            })
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
            exerciseParams
        );

        // temporary logs
        console2.log(
            "[After] BalanceOfPaymentToken: ",
            paymentToken.balanceOf(address(this))
        );
        console2.log(
            "[After] BalanceOfOptionToken: ",
            IERC20(address(optionToken)).balanceOf(address(this))
        );
        uint256 balanceOfUnderlyingToken = underlyingToken.balanceOf(
            address(this)
        );
        console2.log("[After] BalanceOfOATHToken: ", balanceOfUnderlyingToken);

        /* Calculate total amount to return */
        uint256 totalAmount = amount + premium;
        MinAmountOutData memory minAmountOutData = MinAmountOutData(
            MinAmountOutKind.Absolute,
            0 // could use the oracle to set a min price from the options token
        );

        /* Approve the underlying token to make swap */
        underlyingToken.approve(swapperSwaps(), balanceOfUnderlyingToken);
        /* Swap underlying token to payment token (asset) */
        // Question: Here is some room for optimization. Instead of swapping all underlying tokens
        // to payment tokens, we can swap necessary amount of payment tokens (totalAmount) and the rest
        // underlying tokens can be swapped to the want token but swapper doesn't allow to put
        // here amountOut (it is amountIn acceptable for swapBal). Is it worth to play with this ?
        ISwapperSwaps(swapperSwaps()).swapBal(
            address(underlyingToken),
            asset,
            balanceOfUnderlyingToken,
            minAmountOutData,
            BEETX_VAULT_OP
        );

        /* Console log area - temporary */
        console2.log(
            "2.Balance of underlyingToken: ",
            underlyingToken.balanceOf(address(this))
        );
        console2.log(
            "2.Balance of wantToken: ",
            IERC20(wantToken()).balanceOf(address(this))
        );
        console2.log(
            "2.Balance of paymentToken: ",
            paymentToken.balanceOf(address(this))
        );

        /* Calculate profit and revert if it is not profitable */
        uint256 assetBalance = paymentToken.balanceOf(address(this));

        if ((assetBalance - initialBalance) <= totalAmount) {
            revert OptionsCompounder__FlashloanNotProfitable();
        }
        /* Protected by statement above */
        gainInPaymentToken = (assetBalance - initialBalance) - totalAmount;

        /* Approve the underlying token to make swap */
        IERC20(asset).approve(swapperSwaps(), gainInPaymentToken);

        /* Get strategies want token */
        if (wantToken() != asset) {
            ISwapperSwaps(swapperSwaps()).swapBal(
                asset,
                wantToken(),
                gainInPaymentToken,
                minAmountOutData,
                BEETX_VAULT_OP
            );
        }

        gainInWantToken = IERC20(wantToken()).balanceOf(address(this));

        /* Approve lending pool to spend borrowed tokens + premium */
        IERC20(asset).approve(address(lendingPool), totalAmount);

        /* Console log area - temporary */
        console2.log(
            "3.Balance of underlyingToken: ",
            underlyingToken.balanceOf(address(this))
        );
        console2.log("3.Balance of wantToken: ", gainInWantToken);
        console2.log(
            "3.Balance of paymentToken: ",
            paymentToken.balanceOf(address(this))
        );
        console2.log("3.Amount paid back: ", totalAmount);
        emit OTokenCompounded(gainInWantToken, totalAmount);
        return gainInWantToken;
    }

    /***************************** Getters ***********************************/
    /* Temporary for testing */
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

    /* Virtual functions */
    function wantToken() internal view virtual returns (address);

    function swapperSwaps() internal view virtual returns (address);

    /**
     * @dev Returns an array of all the relevant roles arranged in descending order of privilege.
     *      Subclasses should override this to specify their unique roles arranged in the correct
     *      order, for example, [SUPER-ADMIN, ADMIN, GUARDIAN, STRATEGIST].
     */
    function _hasRoleForOptionsCompounder(
        bytes32 _role,
        address _account
    ) internal view virtual returns (bool);

    function getKeeperRole() internal pure virtual returns (bytes32);

    function getAdminRoles() internal pure virtual returns (bytes32[] memory);
}

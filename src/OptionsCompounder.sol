// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

/* Imports */
import {console2} from "forge-std/Test.sol";

import {IFlashLoanReceiver} from "aave-v2/flashloan//interfaces/IFlashLoanReceiver.sol";
import {ILendingPoolAddressesProvider} from "aave-v2/interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPool} from "aave-v2/interfaces/ILendingPool.sol";
import {DiscountExerciseParams, DiscountExercise} from "optionsToken/src/exercise/DiscountExercise.sol";
import {IOptionsToken} from "optionsToken/src/interfaces/IOptionsToken.sol";
import {ReaperAccessControl} from "vault-v2/mixins/ReaperAccessControl.sol";
import {ISwapperSwaps, MinAmountOutData, MinAmountOutKind} from "vault-v2/ReaperSwapper.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {ERC20} from "oz/token/ERC20/ERC20.sol";
import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {IOracle} from "optionsToken/src/interfaces/IOracle.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

enum ExchangeType {
    UniV2,
    Bal,
    VeloSolid,
    UniV3
}

struct SwapProps {
    address exchangeAddress;
    ExchangeType exchangeType;
}

/**
 * @title Consumes options tokens, exercise them with flashloaned asset and converts gain to strategy want token
 * @author Eidolon, xRave110
 * @dev Abstract contract which shall be inherited by the strategy
 */
abstract contract OptionsCompounder is IFlashLoanReceiver, Initializable {
    using FixedPointMathLib for uint256;

    /* Enums */
    enum SwapIdx {
        UNDERLYING_TO_PAYMENT,
        PAYMENT_TO_WANT,
        MAX
    }

    /* Errors */
    error OptionsCompounder__NotExerciseContract();
    error OptionsCompounder__TooMuchAssetsLoaned();
    error OptionsCompounder__FlashloanNotProfitable();
    error OptionsCompounder__AssetNotEqualToPaymentToken();
    error OptionsCompounder__FlashloanNotFinished();
    error OptionsCompounder__OnlyKeeperAllowed();
    error OptionsCompounder__OnlyAdminsAllowed();
    error OptionsCompounder__FlashloanNotTriggered();
    error OptionsCompounder__InvalidExchangeType(uint256 exchangeType);
    error OptionsCompounder__WrongNumberOfParams();

    /* Constants */
    uint8 constant MIN_NR_OF_FLASHLOAN_ASSETS = 1;
    uint256 constant PERCENTAGE = 10000;

    /* Storages */
    ILendingPoolAddressesProvider private addressProvider;
    ILendingPool private lendingPool;
    bool private flashloanFinished;
    IOracle[] private oracles;

    IOptionsToken public optionToken;
    SwapProps[] public swapProps;
    uint256 public maxSwapSlippage;

    /* Events */
    event OTokenCompounded(
        uint256 indexed gainInWant,
        uint256 indexed returned
    );

    /* Modifiers */
    modifier onlyKeeper() {
        if (hasRoleForOptionsCompounder(getKeeperRole(), msg.sender) == false) {
            revert OptionsCompounder__OnlyKeeperAllowed();
        }
        _;
    }

    modifier onlyAdmins() {
        bool hasRole = false;
        bytes32[] memory admins = getAdminRoles();
        for (uint8 idx = 0; idx < admins.length; idx++) {
            if (hasRoleForOptionsCompounder(admins[idx], msg.sender) != false) {
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
     * @notice Initializes params
     * @dev Replaces constructor due to upgradeable nature of the contract. Can be executed only once at init.
     * @param _optionToken - option token address which allows to redeem underlying token via operation "exercise"
     * @param _addressProvider - address lending pool address provider - necessary for flashloan operations
     * */
    function __OptionsCompounder_init(
        address _optionToken,
        address _addressProvider,
        uint256 _maxSwapSlippage,
        SwapProps[] memory _swapProps,
        IOracle[] memory _oracles
    ) internal onlyInitializing {
        if (
            _swapProps.length != uint256(SwapIdx.MAX) ||
            _oracles.length != uint256(SwapIdx.MAX)
        ) {
            revert OptionsCompounder__WrongNumberOfParams();
        }
        optionToken = IOptionsToken(_optionToken);
        addressProvider = ILendingPoolAddressesProvider(_addressProvider);
        lendingPool = ILendingPool(addressProvider.getLendingPool());
        swapProps = _swapProps;
        oracles = _oracles;
        maxSwapSlippage = _maxSwapSlippage;
        flashloanFinished = true;
    }

    /***************************** Setters ***********************************/
    /**
     * @notice Sets option token address
     * @dev Can be executed only by admins
     * @param _optionToken - address of option token contract
     */
    function setOptionToken(address _optionToken) external onlyAdmins {
        optionToken = IOptionsToken(_optionToken);
    }

    function setMaxSwapSlippage(uint256 _maxSwapSlippage) external onlyAdmins {
        maxSwapSlippage = _maxSwapSlippage;
    }

    function configSwapProps(
        SwapProps[] memory _swapProps
    ) external onlyAdmins {
        if (_swapProps.length != uint256(SwapIdx.MAX)) {
            revert OptionsCompounder__WrongNumberOfParams();
        }
        swapProps = _swapProps;
    }

    function setOracles(IOracle[] memory _oracles) external onlyAdmins {
        if (_oracles.length != uint256(SwapIdx.MAX)) {
            revert OptionsCompounder__WrongNumberOfParams();
        }
        oracles = _oracles;
    }

    /**
     * @notice Function initiates flashloan to get assets for exercising options.
     * @dev Can be executed only by keeper role. Reentrance protected.
     * @param amount - amount of option tokens to exercise
     * @param exerciseContract - address of exercise contract (DiscountContract)
     * @param minWantAmount - minimal amount of want when the flashloan is considered as profitable
     */
    function harvestOTokens(
        uint256 amount,
        address exerciseContract,
        uint256 minWantAmount
    ) external onlyKeeper {
        /* Check exercise contract validity */
        if (optionToken.isExerciseContract(exerciseContract) == false) {
            revert OptionsCompounder__NotExerciseContract();
        }
        /* Reentrance protection */
        if (flashloanFinished == false) {
            revert OptionsCompounder__FlashloanNotFinished();
        }
        /* Locals */
        IERC20 paymentToken = DiscountExercise(exerciseContract).paymentToken();
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

        /* necesary params used during flashloan execution */
        bytes memory params = abi.encode(
            amount,
            exerciseContract,
            initialBalance,
            minWantAmount
        );
        flashloanFinished = false;

        lendingPool.flashLoan(
            address(this), // receiver
            assets,
            amounts,
            modes,
            address(this), // onBehalf
            params,
            0 // referal code
        );
    }

    /**
     *  @notice Exercise option tokens with flash loaned token and compound rewards
     *  in underlying tokens to stratefy want token
     *  @dev Function is called after this contract has received the flash loaned amount
     *  @param assets - list of assets flash loaned (only one asset allowed in this case)
     *  @param amounts - list of amounts flash loaned (only one amount allowed in this case)
     *  @param premiums - list of premiums for flash loaned assets (only one premium allowed in this case)
     *  @param params - encoded data about options amount, exercise contract address, initial balance and minimal want amount
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
        exerciseOptionAndReturnDebt(assets[0], amounts[0], premiums[0], params);
        flashloanFinished = true;
        return true;
    }

    /** @dev Private function that helps to execute flashloan and makes it more modular
     * Emits event with gain from the option exercise after repayment of all debt from flashloan
     * and amount of repaid assets
     */
    function exerciseOptionAndReturnDebt(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata params
    ) private {
        (
            uint256 optionsAmount,
            address exerciserContract,
            uint256 initialBalance,
            uint256 minWantAmount
        ) = abi.decode(params, (uint256, address, uint256, uint256));
        uint256 gainInPaymentToken = 0;
        uint256 totalAmountToPay = amount + premium;
        uint256 gainInWantToken = 0;
        uint256 balanceOfUnderlyingToken = 0;
        uint256 assetBalance = 0;
        MinAmountOutData[] memory minAmountOutData = new MinAmountOutData[](
            oracles.length
        );

        /* Get underlying and payment tokens again to make sure there is no change between 
        harvest and excersice */
        IERC20 underlyingToken = DiscountExercise(exerciserContract)
            .underlyingToken();
        IERC20 paymentToken = DiscountExercise(exerciserContract)
            .paymentToken();
        uint256 initialWantBalance = IERC20(wantToken()).balanceOf(
            address(this)
        );
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

        /* Approve spending option token */
        paymentToken.approve(exerciserContract, amount);
        /* Exercise in order to get underlying token */
        optionToken.exercise(
            optionsAmount,
            address(this),
            exerciserContract,
            exerciseParams
        );
        balanceOfUnderlyingToken = underlyingToken.balanceOf(address(this));
        minAmountOutData[
            uint256(SwapIdx.UNDERLYING_TO_PAYMENT)
        ] = _getMinAmountOfData(balanceOfUnderlyingToken, maxSwapSlippage, 0);
        console2.log("Amount0: ", minAmountOutData[0].absoluteOrBPSValue);

        /* Approve the underlying token to make swap */
        underlyingToken.approve(swapperSwaps(), balanceOfUnderlyingToken);

        /* Swap underlying token to payment token (asset) */
        _generalSwap(
            swapProps[uint256(SwapIdx.UNDERLYING_TO_PAYMENT)].exchangeType,
            address(underlyingToken),
            asset,
            balanceOfUnderlyingToken,
            minAmountOutData[uint256(SwapIdx.UNDERLYING_TO_PAYMENT)],
            swapProps[uint256(SwapIdx.UNDERLYING_TO_PAYMENT)].exchangeAddress
        );

        /* Calculate profit and revert if it is not profitable */
        assetBalance = paymentToken.balanceOf(address(this));
        console2.log("Retrieved balance: ", (assetBalance - initialBalance));
        if ((assetBalance - initialBalance) <= totalAmountToPay) {
            revert OptionsCompounder__FlashloanNotProfitable();
        }
        /* Protected by statement above */
        gainInPaymentToken = (assetBalance - initialBalance) - totalAmountToPay;

        /* Approve the underlying token to make swap */
        IERC20(asset).approve(swapperSwaps(), gainInPaymentToken);

        /* Get strategies want token */
        if (wantToken() != asset) {
            minAmountOutData[
                uint256(SwapIdx.PAYMENT_TO_WANT)
            ] = _getMinAmountOfData(
                gainInPaymentToken,
                maxSwapSlippage,
                uint256(SwapIdx.PAYMENT_TO_WANT)
            );
            console2.log("Amount1: ", minAmountOutData[1].absoluteOrBPSValue);
            // checking against expected token
            _generalSwap(
                swapProps[uint256(SwapIdx.PAYMENT_TO_WANT)].exchangeType,
                asset,
                wantToken(),
                gainInPaymentToken,
                minAmountOutData[uint256(SwapIdx.PAYMENT_TO_WANT)],
                swapProps[uint256(SwapIdx.PAYMENT_TO_WANT)].exchangeAddress
            );
        }

        gainInWantToken =
            IERC20(wantToken()).balanceOf(address(this)) -
            initialWantBalance; // - inital balance from the begining
        console2.log("Retrieved want: ", gainInWantToken);
        console2.log("Want address: ", wantToken());
        if (gainInWantToken < minWantAmount) {
            revert OptionsCompounder__FlashloanNotProfitable();
        }
        /* Approve lending pool to spend borrowed tokens + premium */
        IERC20(asset).approve(address(lendingPool), totalAmountToPay);

        emit OTokenCompounded(gainInWantToken, totalAmountToPay);
    }

    function _getMinAmountOfData(
        uint256 _amountIn,
        uint256 _maxSlippage,
        uint256 _idx
    ) private view returns (MinAmountOutData memory) {
        MinAmountOutData memory minAmountOutData;
        uint256 minAmountOut = 0;
        uint256 price = oracles[_idx].getPrice();
        console2.log("0 Price: ", price);
        console2.log("0 AmountIn: ", _amountIn);
        console2.log("1 Good Mul: ", ((_amountIn * price) / 10 ** 18));

        minAmountOut = ((_amountIn.mulWadUp(price)) -
            ((_amountIn.mulWadUp(price)) * _maxSlippage) /
            PERCENTAGE);
        console2.log("2 Good Mul: ", minAmountOut);
        minAmountOutData = MinAmountOutData(
            MinAmountOutKind.Absolute,
            minAmountOut // could use the oracle to set a min price from the options token
            // oracle from oToken
        );
        return minAmountOutData;
    }

    function _generalSwap(
        ExchangeType exType,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        MinAmountOutData memory minAmountOutData,
        address exchangeAddress
    ) private {
        ISwapperSwaps swapper = ISwapperSwaps(swapperSwaps());
        if (exType == ExchangeType.UniV2) {
            swapper.swapUniV2(
                tokenIn,
                tokenOut,
                amount,
                minAmountOutData,
                exchangeAddress
            );
        } else if (exType == ExchangeType.Bal) {
            swapper.swapBal(
                tokenIn,
                tokenOut,
                amount,
                minAmountOutData,
                exchangeAddress
            );
        } else if (exType == ExchangeType.VeloSolid) {
            swapper.swapVelo(
                tokenIn,
                tokenOut,
                amount,
                minAmountOutData,
                exchangeAddress
            );
        } else if (exType == ExchangeType.UniV3) {
            swapper.swapUniV3(
                tokenIn,
                tokenOut,
                amount,
                minAmountOutData,
                exchangeAddress
            );
        } else {
            revert OptionsCompounder__InvalidExchangeType(uint256(exType));
        }
    }

    /***************************** Getters ***********************************/
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

    function requiredParamsLength() external pure returns (uint256) {
        return uint256(SwapIdx.MAX);
    }

    /* Virtual functions */
    /**
     * @dev Shall be implemented in the parent contract
     * @return Want token of the strategy
     */
    function wantToken() internal view virtual returns (address);

    /**
     * @dev Shall be implemented in the parent contract
     * @return Swapper contract used in the strategy
     */
    function swapperSwaps() internal view virtual returns (address);

    /**
     * @dev Subclasses should override this to specify their unique role-checking criteria.
     * @return Returns bool value. {true} if {_account} has been granted {_role}.
     */
    function hasRoleForOptionsCompounder(
        bytes32 _role,
        address _account
    ) internal view virtual returns (bool);

    /**
     * @dev Shall be implemented in the parent contract
     * @return Keeper role of the strategy
     * */
    function getKeeperRole() internal pure virtual returns (bytes32);

    /**
     * @dev Shall be implemented in the parent contract
     * @return Admin roles of the strategy
     * */
    function getAdminRoles() internal pure virtual returns (bytes32[] memory);
}

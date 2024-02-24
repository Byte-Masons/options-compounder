// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

/* Imports */
import {IFlashLoanReceiver} from "aave-v2/interfaces/IFlashLoanReceiver.sol";
import {ILendingPoolAddressesProvider} from "aave-v2/interfaces/ILendingPoolAddressesProvider.sol";
import {ILendingPool} from "aave-v2/interfaces/ILendingPool.sol";
import {DiscountExerciseParams, DiscountExercise} from "optionsToken/src/exercise/DiscountExercise.sol";
import {ReaperAccessControl} from "vault-v2/mixins/ReaperAccessControl.sol";
import {ISwapperSwaps, MinAmountOutData, MinAmountOutKind} from "vault-v2/ReaperSwapper.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
// import {Initializable} from "oz-upgradeable/proxy/utils/Initializable.sol";
import {IOracle} from "optionsToken/src/interfaces/IOracle.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import "./interfaces/IOptionsCompounder.sol";
import {OwnableUpgradeable} from "oz-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Consumes options tokens, exercise them with flashloaned asset and converts gain to strategy want token
 * @author Eidolon, xRave110
 * @dev Abstract contract which shall be inherited by the strategy
 */
contract OptionsCompounder is
    IFlashLoanReceiver,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    using FixedPointMathLib for uint256;
    using SafeERC20 for IERC20;

    /* Internal struct */
    struct FlashloanParams {
        uint256 optionsAmount;
        address exerciserContract;
        address sender;
        uint256 initialBalance;
        uint256 minPaymentAmount;
    }

    /* Constants */
    uint8 constant MIN_NR_OF_FLASHLOAN_ASSETS = 1;
    uint256 constant PERCENTAGE = 10000;

    uint256 public constant UPGRADE_TIMELOCK = 48 hours;
    uint256 public constant FUTURE_NEXT_PROPOSAL_TIME = 365 days * 100;

    /* Storages */
    address public swapper;
    ILendingPoolAddressesProvider private addressProvider;
    ILendingPool private lendingPool;
    bool private flashloanFinished;
    IOracle private oracle;
    IOptionsToken public optionsToken;
    SwapProps public swapProps;

    uint256 public upgradeProposalTime;
    address public nextImplementation;

    /* Events */
    event OTokenCompounded(
        uint256 indexed gainInPayment,
        uint256 indexed returned
    );

    /* Modifiers */

    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes params
     * @dev Replaces constructor due to upgradeable nature of the contract. Can be executed only once at init.
     * @param _optionsToken - option token address which allows to redeem underlying token via operation "exercise"
     * @param _addressProvider - address lending pool address provider - necessary for flashloan operations
     * @param _swapProps - swap properites for all swaps in the contract
     * @param _oracle - oracles used in all swaps in the contract
     *
     */
    function initialize(
        address _optionsToken,
        address _addressProvider,
        address _swapper,
        SwapProps memory _swapProps,
        IOracle _oracle
    ) public initializer {
        __Ownable_init();
        setOptionToken(_optionsToken);
        configSwapProps(_swapProps);
        setOracle(_oracle);
        setSwapper(_swapper);
        flashloanFinished = true;
        setAddressProvider(_addressProvider);
        __UUPSUpgradeable_init();
        _clearUpgradeCooldown();
    }

    /***************************** Setters ***********************************/
    /**
     * @notice Sets option token address
     * @dev Can be executed only by admins
     * @param _optionToken - address of option token contract
     */
    function setOptionToken(address _optionToken) public onlyOwner {
        if (_optionToken == address(0)) {
            revert OptionsCompounder__ParamHasAddressZero();
        }
        optionsToken = IOptionsToken(_optionToken);
    }

    function configSwapProps(SwapProps memory _swapProps) public onlyOwner {
        if (_swapProps.maxSwapSlippage > PERCENTAGE) {
            revert OptionsCompounder__SlippageGreaterThanMax();
        }
        if (_swapProps.exchangeAddress == address(0)) {
            revert OptionsCompounder__ParamHasAddressZero();
        }
        swapProps = _swapProps;
    }

    function setOracle(IOracle _oracle) public onlyOwner {
        if (address(_oracle) == address(0)) {
            revert OptionsCompounder__ParamHasAddressZero();
        }
        oracle = _oracle;
    }

    function setSwapper(address _swapper) public onlyOwner {
        if (_swapper == address(0)) {
            revert OptionsCompounder__ParamHasAddressZero();
        }
        swapper = _swapper;
    }

    function setAddressProvider(address _addressProvider) public onlyOwner {
        if (_addressProvider == address(0)) {
            revert OptionsCompounder__ParamHasAddressZero();
        }
        addressProvider = ILendingPoolAddressesProvider(_addressProvider);
        lendingPool = ILendingPool(addressProvider.getLendingPool());
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
    ) external {
        _harvestOTokens(amount, exerciseContract, minWantAmount);
    }

    /**
     * @notice Function initiates flashloan to get assets for exercising options.
     * @dev Can be executed only by keeper role. Reentrance protected.
     * @param amount - amount of option tokens to exercise
     * @param exerciseContract - address of exercise contract (DiscountContract)
     * @param minPaymentAmount - minimal amount of want when the flashloan is considered as profitable
     */
    function _harvestOTokens(
        uint256 amount,
        address exerciseContract,
        uint256 minPaymentAmount
    ) private {
        /* Check exercise contract validity */
        if (optionsToken.isExerciseContract(exerciseContract) == false) {
            revert OptionsCompounder__NotExerciseContract();
        }
        /* Reentrance protection */
        if (flashloanFinished == false) {
            revert OptionsCompounder__FlashloanNotFinished();
        }
        if (minPaymentAmount == 0) {
            revert OptionsCompounder__WrongMinPaymentAmount();
        }
        /* Locals */
        IERC20 paymentToken = DiscountExercise(exerciseContract).paymentToken();

        address[] memory assets = new address[](1);
        assets[0] = address(paymentToken);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = DiscountExercise(exerciseContract).getPaymentAmount(
            amount
        );

        // 0 = no debt, 1 = stable, 2 = variable
        uint256[] memory modes = new uint256[](1);
        modes[0] = 0;

        /* necesary params used during flashloan execution */
        bytes memory params = abi.encode(
            FlashloanParams(
                amount,
                exerciseContract,
                msg.sender,
                paymentToken.balanceOf(address(this)),
                minPaymentAmount
            )
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
     *  @param asset - list of assets flash loaned (only one asset allowed in this case)
     *  @param amount - list of amounts flash loaned (only one amount allowed in this case)
     *  @param premium - list of premiums for flash loaned assets (only one premium allowed in this case)
     *  @param params - encoded data about options amount, exercise contract address, initial balance and minimal want amount
     */
    function exerciseOptionAndReturnDebt(
        address asset,
        uint256 amount,
        uint256 premium,
        bytes calldata params
    ) private {
        FlashloanParams memory flashloanParams = abi.decode(
            params,
            (FlashloanParams)
        );
        uint256 assetBalance = 0;
        MinAmountOutData memory minAmountOutData;

        /* Get underlying and payment tokens to make sure there is no change between 
        harvest and excersice */
        IERC20 underlyingToken = DiscountExercise(
            flashloanParams.exerciserContract
        ).underlyingToken();
        {
            IERC20 paymentToken = DiscountExercise(
                flashloanParams.exerciserContract
            ).paymentToken();

            /* Asset and paymentToken should be the same addresses */
            if (asset != address(paymentToken)) {
                revert OptionsCompounder__AssetNotEqualToPaymentToken();
            }
        }
        {
            IERC20(address(optionsToken)).safeTransferFrom(
                flashloanParams.sender,
                address(this),
                flashloanParams.optionsAmount
            );
            bytes memory exerciseParams = abi.encode(
                DiscountExerciseParams({
                    maxPaymentAmount: amount,
                    deadline: type(uint256).max
                })
            );
            if (
                underlyingToken.balanceOf(flashloanParams.exerciserContract) <
                flashloanParams.optionsAmount
            ) {
                revert OptionsCompounder__NotEnoughUnderlyingTokens();
            }
            /* Approve spending option token */
            IERC20(asset).approve(flashloanParams.exerciserContract, amount);
            /* Exercise in order to get underlying token */
            optionsToken.exercise(
                flashloanParams.optionsAmount,
                address(this),
                flashloanParams.exerciserContract,
                exerciseParams
            );
        }

        {
            uint256 balanceOfUnderlyingToken = 0;
            balanceOfUnderlyingToken = underlyingToken.balanceOf(address(this));
            minAmountOutData = _getMinAmountOutData(
                balanceOfUnderlyingToken,
                swapProps.maxSwapSlippage
            );

            /* Approve the underlying token to make swap */
            underlyingToken.approve(swapper, balanceOfUnderlyingToken);

            /* Swap underlying token to payment token (asset) */

            _generalSwap(
                swapProps.exchangeTypes,
                address(underlyingToken),
                asset,
                balanceOfUnderlyingToken,
                minAmountOutData,
                swapProps.exchangeAddress
            );
        }

        /* Calculate profit and revert if it is not profitable */
        {
            uint256 gainInPaymentToken = 0;

            uint256 totalAmountToPay = amount + premium;
            assetBalance = IERC20(asset).balanceOf(address(this));

            if (
                ((assetBalance < flashloanParams.initialBalance) ||
                    (assetBalance - flashloanParams.initialBalance) <=
                    (totalAmountToPay + flashloanParams.minPaymentAmount))
            ) {
                revert OptionsCompounder__FlashloanNotProfitableEnough();
            }

            /* Protected against underflows by statement above */
            gainInPaymentToken = assetBalance - totalAmountToPay;

            /* Approve lending pool to spend borrowed tokens + premium */
            IERC20(asset).approve(address(lendingPool), totalAmountToPay);
            IERC20(asset).safeTransfer(
                flashloanParams.sender,
                gainInPaymentToken
            );

            emit OTokenCompounded(gainInPaymentToken, totalAmountToPay);
        }
    }

    /** @dev Private function that calculates minimal amount token out of swap using oracles
     *  @param _amountIn - amount of token to be swapped
     *  @param _maxSlippage - max allowed slippage
     */
    function _getMinAmountOutData(
        uint256 _amountIn,
        uint256 _maxSlippage
    ) private view returns (MinAmountOutData memory) {
        MinAmountOutData memory minAmountOutData;
        uint256 minAmountOut = 0;
        /* Get price from oracle */
        uint256 price = oracle.getPrice();
        /* Deduct slippage amount from predicted amount */
        minAmountOut = ((_amountIn.mulWadUp(price)) -
            (((_amountIn.mulWadUp(price)) * _maxSlippage) / PERCENTAGE));
        minAmountOutData = MinAmountOutData(
            MinAmountOutKind.Absolute,
            minAmountOut
        );
        return minAmountOutData;
    }

    /** @dev Private function that allow to swap via multiple exchange types
     *  @param exType - type of exchange
     *  @param tokenIn - address of token in
     *  @param tokenOut - address of token out
     *  @param amount - amount of tokenIn to swap
     *  @param minAmountOutData - minimal acceptable amount of tokenOut
     *  @param exchangeAddress - address of the exchange
     */
    function _generalSwap(
        ExchangeType exType,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        MinAmountOutData memory minAmountOutData,
        address exchangeAddress
    ) private {
        ISwapperSwaps _swapper = ISwapperSwaps(swapper);
        if (exType == ExchangeType.UniV2) {
            _swapper.swapUniV2(
                tokenIn,
                tokenOut,
                amount,
                minAmountOutData,
                exchangeAddress
            );
        } else if (exType == ExchangeType.Bal) {
            _swapper.swapBal(
                tokenIn,
                tokenOut,
                amount,
                minAmountOutData,
                exchangeAddress
            );
        } else if (exType == ExchangeType.ThenaRam) {
            _swapper.swapThenaRam(
                tokenIn,
                tokenOut,
                amount,
                minAmountOutData,
                exchangeAddress
            );
        } else if (exType == ExchangeType.UniV3) {
            _swapper.swapUniV3(
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

    /**
     * @dev This function must be called prior to upgrading the implementation.
     *      It's required to wait UPGRADE_TIMELOCK seconds before executing the upgrade.
     */
    function initiateUpgradeCooldown(
        address _nextImplementation
    ) external onlyOwner {
        upgradeProposalTime = block.timestamp;
        nextImplementation = _nextImplementation;
    }

    /**
     * @dev This function is called:
     *      - in initialize()
     *      - as part of a successful upgrade
     *      - manually to clear the upgrade cooldown.
     */
    function _clearUpgradeCooldown() internal {
        upgradeProposalTime = block.timestamp + FUTURE_NEXT_PROPOSAL_TIME;
    }

    function clearUpgradeCooldown() external onlyOwner {
        _clearUpgradeCooldown();
    }

    /**
     * @dev This function must be overriden simply for access control purposes.
     *      Only the owner can upgrade the implementation once the timelock
     *      has passed.
     */
    function _authorizeUpgrade(
        address _nextImplementation
    ) internal override onlyOwner {
        require(
            upgradeProposalTime + UPGRADE_TIMELOCK < block.timestamp,
            "Upgrade cooldown not initiated or still ongoing"
        );
        require(
            _nextImplementation == nextImplementation,
            "Incorrect implementation"
        );
        _clearUpgradeCooldown();
    }

    /***************************** Getters ***********************************/
    function getOptionTokenAddress() external view returns (address) {
        return address(optionsToken);
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

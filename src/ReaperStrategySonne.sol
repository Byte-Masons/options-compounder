// SPDX-License-Identifier: BUSL1.1

pragma solidity ^0.8.0;

import {ReaperBaseStrategyv4} from "vault-v2/ReaperBaseStrategyv4.sol";
import {IVault} from "vault-v2/interfaces/IVault.sol";
import {CErc20I} from "./interfaces/CErc20I.sol";
import {CTokenI} from "./interfaces/CTokenI.sol";
import {IComptroller} from "./interfaces/IComptroller.sol";
import {ILeverageable} from "vault-v2/interfaces/ILeverageable.sol";
import {SafeERC20Upgradeable} from "oz-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IERC20Upgradeable} from "oz-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {MathUpgradeable} from "oz-upgradeable/utils/math/MathUpgradeable.sol";
import {ReaperMathUtils} from "vault-v2/libraries/ReaperMathUtils.sol";
import {OptionsCompounder} from "./OptionsCompounder.sol";

/**
 * @dev This strategy will deposit a token on Sonne to maximize yield
 */
contract ReaperStrategySonne is
    ReaperBaseStrategyv4,
    ILeverageable,
    OptionsCompounder
{
    using ReaperMathUtils for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // this strategy's configurable tokens
    CErc20I public cWant;
    IComptroller public comptroller;

    /**
     * @dev Sonne variables
     * {markets} - Contains the Sonne tokens to farm, used to enter markets and claim Sonne
     * {MANTISSA} - The unit used by the Compound protocol
     * {LTV_SAFETY_ZONE} - We will only go up to 98% of max allowed LTV for {targetLtv}
     */
    address[] public markets;
    uint256 public constant MANTISSA = 1e18;
    uint256 public constant LTV_SAFETY_ZONE = 0.98 ether;

    /**
     * @dev Strategy variables
     * {targetLtv} - The target loan to value for the strategy where 1 ether = 100%
     * {allowedLtvDrift} - How much the strategy can deviate from the target ltv where 0.01 ether = 1%
     * {recordedPoolBalance} - The total balance deposited into Sonne (supplied - borrowed)
     * {borrowDepth} - The maximum amount of loops used to leverage and deleverage
     * {minWantToLeverage} - The minimum amount of want to leverage in a loop
     * {withdrawSlippageTolerance} - Maximum slippage authorized when withdrawing
     */
    uint256 public targetLtv;
    uint256 public allowedLtvDrift;
    uint256 public recordedPoolBalance;
    uint256 public borrowDepth;
    uint256 public minWantToLeverage;
    uint256 public maxBorrowDepth;
    uint256 public withdrawSlippageTolerance;

    /**
     * @dev Initializes the strategy. Sets parameters, saves routes, and gives allowances.
     * @notice see documentation for each variable above its respective declaration.
     */
    function initialize(
        address _vault,
        address _swapper,
        address[] memory _strategists,
        address[] memory _multisigRoles,
        address[] memory _keepers,
        address _cWant,
        address _optionToken,
        address _addressProvider,
        uint256 _targetLTV
    ) public initializer {
        cWant = CErc20I(_cWant);
        __ReaperBaseStrategy_init(
            _vault,
            _swapper,
            cWant.underlying(),
            _strategists,
            _multisigRoles,
            _keepers
        );
        // Question: Should be nested deeper ?
        __OptionsCompounder_init(
            _optionToken,
            _addressProvider,
            _swapper,
            cWant.underlying(),
            _multisigRoles
        );
        markets = [_cWant];
        comptroller = IComptroller(cWant.comptroller());

        allowedLtvDrift = 0.01 ether;
        recordedPoolBalance = 0;
        borrowDepth = 12;
        minWantToLeverage = 1;
        maxBorrowDepth = 15;
        withdrawSlippageTolerance = 50;

        comptroller.enterMarkets(markets);
        setTargetLtv(_targetLTV);
    }

    function _liquidateAllPositions()
        internal
        override
        returns (uint256 amountFreed)
    {
        _deleverage(type(uint256).max);
        _withdrawUnderlying(type(uint256).max);
        return balanceOfWant();
    }

    /**
     * @dev Core function of the strat, in charge of collecting rewards
     * @notice Assumes the deposit will take care of resupplying excess want.
     */
    function _beforeHarvestSwapSteps() internal override {
        CTokenI[] memory tokens = new CTokenI[](1);
        tokens[0] = cWant;
        comptroller.claimComp(address(this), tokens);
    }

    function _estimatedTotalAssets() internal override returns (uint256) {
        // update internal accounting first
        updateBalance();
        return balanceOf();
    }

    /**
     * @dev Function that puts the funds to work.
     * It supplies {want} to Scream to farm {SCREAM} tokens
     */
    function _deposit(uint256 _amount) internal override doUpdateBalance {
        if (_amount != 0) {
            IERC20Upgradeable(want).safeIncreaseAllowance(
                address(cWant),
                _amount
            );
            cWant.mint(_amount);
        }

        uint256 _ltv = _calculateLTV();
        if (_shouldLeverage(_ltv)) {
            _leverMax();
        } else if (_shouldDeleverage(_ltv)) {
            _deleverage(0);
        }
    }

    /**
     * @dev Withdraws funds and sents them back to the vault.
     * It withdraws {want} from Scream
     * The available {want} minus fees is returned to the vault.
     */
    function _withdraw(
        uint256 _withdrawAmount
    ) internal override doUpdateBalance {
        uint256 _ltv = _calculateLTVAfterWithdraw(_withdrawAmount);

        if (_shouldLeverage(_ltv)) {
            // Strategy is underleveraged so can withdraw underlying directly
            _withdrawUnderlying(_withdrawAmount);
            _leverMax();
        } else if (_shouldDeleverage(_ltv)) {
            _deleverage(_withdrawAmount);
            // Strategy has deleveraged to the point where it can withdraw underlying
            _withdrawUnderlying(_withdrawAmount);
        } else {
            // LTV is in the acceptable range so the underlying can be withdrawn directly
            _withdrawUnderlying(_withdrawAmount);
        }
    }

    /**
     * @dev Levers the strategy up to the targetLtv
     */
    function _leverMax() internal {
        uint256 supplied = cWant.balanceOfUnderlying(address(this));
        uint256 borrowed = cWant.borrowBalanceStored(address(this));

        uint256 realSupply = supplied - borrowed;
        uint256 newBorrow = _getMaxBorrowFromSupplied(realSupply, targetLtv);
        uint256 totalAmountToBorrow = newBorrow - borrowed;

        for (
            uint256 i = 0;
            i < borrowDepth && totalAmountToBorrow > minWantToLeverage;
            i = i.uncheckedInc()
        ) {
            totalAmountToBorrow =
                totalAmountToBorrow -
                _leverUpStep(totalAmountToBorrow);
        }
    }

    /**
     * @dev Does one step of leveraging
     */
    function _leverUpStep(
        uint256 _withdrawAmount
    ) internal virtual returns (uint256) {
        if (_withdrawAmount == 0) {
            return 0;
        }

        uint256 supplied = cWant.balanceOfUnderlying(address(this));
        uint256 borrowed = cWant.borrowBalanceStored(address(this));
        (, uint256 collateralFactorMantissa, ) = comptroller.markets(
            address(cWant)
        );
        uint256 canBorrow = (supplied * collateralFactorMantissa) / MANTISSA;

        canBorrow -= borrowed;

        if (canBorrow < _withdrawAmount) {
            _withdrawAmount = canBorrow;
        }

        if (_withdrawAmount > 10) {
            // borrow available amount
            cWant.borrow(_withdrawAmount);

            // deposit available want as collateral
            uint256 wantBalance = balanceOfWant();
            IERC20Upgradeable(want).safeIncreaseAllowance(
                address(cWant),
                wantBalance
            );
            cWant.mint(wantBalance);
        }

        return _withdrawAmount;
    }

    /**
     * @dev Gets the maximum amount allowed to be borrowed for a given collateral factor and amount supplied
     */
    function _getMaxBorrowFromSupplied(
        uint256 wantSupplied,
        uint256 collateralFactor
    ) internal pure returns (uint256) {
        return ((wantSupplied * collateralFactor) /
            (MANTISSA - collateralFactor));
    }

    /**
     * @dev Returns if the strategy should leverage with the given ltv level
     */
    function _shouldLeverage(uint256 _ltv) internal view returns (bool) {
        if (
            targetLtv >= allowedLtvDrift && _ltv < targetLtv - allowedLtvDrift
        ) {
            return true;
        }
        return false;
    }

    /**
     * @dev Returns if the strategy should deleverage with the given ltv level
     */
    function _shouldDeleverage(uint256 _ltv) internal view returns (bool) {
        if (_ltv > targetLtv + allowedLtvDrift) {
            return true;
        }
        return false;
    }

    /**
     * @dev This is the state changing calculation of LTV that is more accurate
     * to be used internally.
     */
    function _calculateLTV() internal returns (uint256 ltv) {
        uint256 supplied = cWant.balanceOfUnderlying(address(this));
        uint256 borrowed = cWant.borrowBalanceStored(address(this));

        if (supplied == 0 || borrowed == 0) {
            return 0;
        }
        ltv = (MANTISSA * borrowed) / supplied;
    }

    /**
     * @dev Calculates what the LTV will be after withdrawing
     */
    function _calculateLTVAfterWithdraw(
        uint256 _withdrawAmount
    ) internal returns (uint256 ltv) {
        uint256 supplied = cWant.balanceOfUnderlying(address(this));
        uint256 borrowed = cWant.borrowBalanceStored(address(this));
        if (_withdrawAmount > supplied) {
            return 0;
        }
        supplied = supplied - _withdrawAmount;

        if (supplied == 0 || borrowed == 0) {
            return 0;
        }
        ltv = (uint256(1e18) * borrowed) / supplied;
    }

    /**
     * @dev Attempts to Withdraw {_withdrawAmount} from pool. Withdraws max amount that can be
     *      safely withdrawn if {_withdrawAmount} is too high.
     */
    function _withdrawUnderlying(
        uint256 _withdrawAmount
    ) internal doUpdateBalance {
        uint256 withdrawable = cWant.balanceOfUnderlying(address(this));
        _withdrawAmount = MathUpgradeable.min(_withdrawAmount, withdrawable);

        uint256 supplied = cWant.balanceOfUnderlying(address(this));
        uint256 borrowed = cWant.borrowBalanceStored(address(this));
        uint256 tempColla = targetLtv + allowedLtvDrift;

        if (tempColla == 0) {
            tempColla = 1e15; // 0.001 * 1e18. lower we have issues
        }
        uint256 minAllowedSupply = (borrowed * MANTISSA) / tempColla;
        withdrawable = supplied - minAllowedSupply;
        _withdrawAmount = MathUpgradeable.min(_withdrawAmount, withdrawable);

        if (_withdrawAmount != 0) {
            cWant.redeemUnderlying(_withdrawAmount);
        }
    }

    /**
     * @dev For a given withdraw amount, figures out the new borrow with the current supply
     * that will maintain the target LTV
     */
    function _getDesiredBorrow(
        uint256 _withdrawAmount
    ) internal returns (uint256 position) {
        //we want to use statechanging for safety
        uint256 supplied = cWant.balanceOfUnderlying(address(this));
        uint256 borrowed = cWant.borrowBalanceStored(address(this));

        //When we unwind we end up with the difference between borrow and supply
        uint256 unwoundSupplied = supplied - borrowed;

        //we want to see how close to collateral target we are.
        //So we take our unwound supplied and add or remove the _withdrawAmount we are are adding/removing.
        //This gives us our desired future undwoundDeposit (desired supply)

        uint256 desiredSupply = 0;
        if (_withdrawAmount > unwoundSupplied) {
            _withdrawAmount = unwoundSupplied;
        }
        desiredSupply = unwoundSupplied - _withdrawAmount;

        //(ds *c)/(1-c)
        uint256 num = desiredSupply * targetLtv;
        uint256 den = MANTISSA - targetLtv;

        uint256 desiredBorrow = num / den;
        if (desiredBorrow > 1e5) {
            //stop us going right up to the wire
            desiredBorrow = desiredBorrow - 1e5;
        }

        position = borrowed - desiredBorrow;
    }

    /**
     * @dev For a given withdraw amount, deleverages to a borrow level
     * that will maintain the target LTV
     */
    function _deleverage(uint256 _withdrawAmount) internal {
        uint256 newBorrow = _getDesiredBorrow(_withdrawAmount);
        // If there is no deficit we dont need to adjust position
        // if the position change is tiny do nothing
        for (
            uint256 i = 0;
            newBorrow > minWantToLeverage && i < borrowDepth;
            i = i.uncheckedInc()
        ) {
            newBorrow -= _leverDownStep(newBorrow);
        }
    }

    /**
     * @dev Deleverages one step
     */
    function _leverDownStep(
        uint256 maxDeleverage
    ) internal returns (uint256 deleveragedAmount) {
        uint256 minAllowedSupply = 0;
        uint256 supplied = cWant.balanceOfUnderlying(address(this));
        uint256 borrowed = cWant.borrowBalanceStored(address(this));
        (, uint256 collateralFactorMantissa, ) = comptroller.markets(
            address(cWant)
        );

        //collat ration should never be 0. if it is something is very wrong... but just incase
        if (collateralFactorMantissa != 0) {
            minAllowedSupply = (borrowed * MANTISSA) / collateralFactorMantissa;
        }
        uint256 maxAllowedDeleverageAmount = supplied - minAllowedSupply;
        maxAllowedDeleverageAmount =
            (maxAllowedDeleverageAmount * 0.999 ether) /
            MANTISSA;

        deleveragedAmount = maxAllowedDeleverageAmount;

        if (deleveragedAmount >= borrowed) {
            deleveragedAmount = borrowed;
        }
        if (deleveragedAmount >= maxDeleverage) {
            deleveragedAmount = maxDeleverage;
        }

        cWant.redeemUnderlying(deleveragedAmount);
        IERC20Upgradeable(want).safeIncreaseAllowance(
            address(cWant),
            deleveragedAmount
        );
        cWant.repayBorrow(deleveragedAmount);
    }

    /**
     * @dev Attempts to safely withdraw {_amount} from the pool.
     */
    function authorizedWithdrawUnderlying(uint256 _amount) external {
        _atLeastRole(STRATEGIST);
        _withdrawUnderlying(_amount);
    }

    /**
     * @dev Function to calculate the total {want} in external contracts.
     */
    function balanceOfPool() public view override returns (uint256) {
        return recordedPoolBalance;
    }

    /**
     * @dev Updates the balance. This is the state changing version so it sets
     * recordedPoolBalance to the latest value.
     */
    function updateBalance() public {
        uint256 supplyBalance = cWant.balanceOfUnderlying(address(this));
        uint256 borrowBalance = cWant.borrowBalanceCurrent(address(this));
        recordedPoolBalance = supplyBalance - borrowBalance;
    }

    /**
     * @dev Calculates the LTV using existing exchange rate,
     * depends on the cWant being updated to be accurate.
     * Does not update in order provide a view function for LTV.
     */
    function calculateLTV() public view returns (uint256 ltv) {
        (, uint256 cWantBalance, uint256 borrowed, uint256 exchangeRate) = cWant
            .getAccountSnapshot(address(this));

        uint256 supplied = (cWantBalance * exchangeRate) / MANTISSA;

        if (supplied == 0 || borrowed == 0) {
            return 0;
        }

        ltv = (MANTISSA * borrowed) / supplied;
    }

    /**
     * @dev Emergency function to deleverage in case regular deleveraging breaks
     */
    function manualDeleverage(uint256 amount) external doUpdateBalance {
        _atLeastRole(STRATEGIST);
        require(
            cWant.redeemUnderlying(amount) == 0,
            "Cannot redeem underlying"
        );
        require(cWant.repayBorrow(amount) == 0, "Cannot repay borrow");
    }

    /**
     * @dev Emergency function to deleverage in case regular deleveraging breaks
     */
    function manualReleaseWant(uint256 amount) external doUpdateBalance {
        _atLeastRole(STRATEGIST);
        require(
            cWant.redeemUnderlying(amount) == 0,
            "Cannot redeem underlying"
        );
    }

    /**
     * @dev Sets a new LTV for leveraging.
     * Should be in units of 1e18
     */
    function setTargetLtv(uint256 _ltv) public {
        if (!hasRole(KEEPER, msg.sender)) {
            _atLeastRole(STRATEGIST);
        }

        if (_ltv != 0) {
            require(_ltv >= 0.0001 ether, "LTV must be in ether precision");
        }

        (, uint256 collateralFactorMantissa, ) = comptroller.markets(
            address(cWant)
        );
        require(
            collateralFactorMantissa > _ltv + allowedLtvDrift,
            "LTV too high to be safe"
        );
        require(
            _ltv + allowedLtvDrift <=
                (collateralFactorMantissa * LTV_SAFETY_ZONE) / MANTISSA,
            "LTV+drift too high to be safe"
        );
        targetLtv = _ltv;
    }

    /**
     * @dev This function is designed to be called by a keeper to set the desired
     *      leverage params within the strategy. The units of the parameters may vary
     *      from strategy to strategy: some strategies may use basis points, others may
     *      use ether precision. Moreover, not all parameters will apply to all strategies.
     *      Strategies are free to ignore parameters they don't care about.
     * @param targetLeverage the leverage/ltv to target
     * @param triggerHarvest whether to call the harvest function at the end
     */
    function setLeverage(
        uint256 targetLeverage,
        uint256,
        bool triggerHarvest
    ) external {
        setTargetLtv(targetLeverage);
        if (triggerHarvest) {
            harvest();
        }
    }

    /**
     * @dev Returns the current state of the strategy in terms of leverage params.
     *      If all is working as intended, targetLeverage <= realLeverage <= maxLeverage.
     *      Ideally realLeverage is very close to targetLeverage. The units of the return
     *      values will vary from strategy to strategy: some strategies may use basis points,
     *      others may use ether precision.
     * @return realLeverage the current leverage calculated using real loan values
     * @return targetLeverage the current value of targetLeverage set within the strategy
     * @return maxLeverage the current value of maxLeverage set within the strategy
     */
    function getCurrentLeverageSnapshot()
        external
        view
        returns (
            uint256 realLeverage,
            uint256 targetLeverage,
            uint256 maxLeverage
        )
    {
        realLeverage = calculateLTV();
        targetLeverage = targetLtv;
        maxLeverage = targetLtv + allowedLtvDrift;
    }

    /**
     * @dev Sets a new allowed LTV drift
     * Should be in units of 1e18
     */
    function setAllowedLtvDrift(uint256 _drift) external {
        _atLeastRole(STRATEGIST);
        (, uint256 collateralFactorMantissa, ) = comptroller.markets(
            address(cWant)
        );
        require(
            targetLtv + _drift <=
                (collateralFactorMantissa * LTV_SAFETY_ZONE) / MANTISSA,
            "LTV+drift too high to be safe"
        );
        allowedLtvDrift = _drift;
    }

    /**
     * @dev Sets a new borrow depth (how many loops for leveraging+deleveraging)
     */
    function setBorrowDepth(uint8 _borrowDepth) external {
        _atLeastRole(STRATEGIST);
        require(_borrowDepth <= maxBorrowDepth, "Borrow depth too high");
        borrowDepth = _borrowDepth;
    }

    /**
     * @dev Sets the minimum want to leverage/deleverage (loop) for
     */
    function setMinWantToLeverage(uint256 _minWantToLeverage) external {
        _atLeastRole(STRATEGIST);
        minWantToLeverage = _minWantToLeverage;
    }

    /**
     * @dev Sets the maximum slippage authorized when withdrawing
     */
    function setWithdrawSlippageTolerance(
        uint256 _withdrawSlippageTolerance
    ) external {
        _atLeastRole(STRATEGIST);
        withdrawSlippageTolerance = _withdrawSlippageTolerance;
    }

    /**
     * @dev Helper modifier for functions that need to update the internal balance at the end of their execution.
     */
    modifier doUpdateBalance() {
        _;
        updateBalance();
    }
}

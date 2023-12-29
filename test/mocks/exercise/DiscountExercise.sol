// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {Owned} from "solmate/auth/Owned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeERC20, IERC20} from "oz/token/ERC20/utils/SafeERC20.sol";

import {BaseExercise} from "../exercise/BaseExercise.sol";
import {IOracle} from "../../../src/interfaces/IOracle.sol";
import {OptionsToken} from "../OptionsToken.sol";

struct DiscountExerciseParams {
    uint256 maxPaymentAmount;
    uint256 deadline;
}

/// @title Options Token Exercise Contract
/// @author @bigbadbeard, @lookee, @eidolon
/// @notice Contract that allows the holder of options tokens to exercise them,
/// in this case, by purchasing the underlying token at a discount to the market price.
/// @dev Assumes the underlying token and the payment token both use 18 decimals.
contract DiscountExercise is BaseExercise, Owned {
    /// Library usage
    using SafeTransferLib for ERC20;
    using SafeTransferLib for IERC20;
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// Errors
    error Exercise__SlippageTooHigh();
    error Exercise__PastDeadline();

    /// Events
    event Exercised(
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        uint256 paymentAmount
    );
    event SetOracle(IOracle indexed newOracle);
    event SetTreasury(address indexed newTreasury);
    event SetMultiplier(uint256 indexed newMultiplier);

    /// Constants

    /// @notice The denominator for converting the multiplier into a decimal number.
    /// i.e. multiplier uses 4 decimals.
    uint256 internal constant MULTIPLIER_DENOM = 10000;

    /// Immutable parameters

    /// @notice The token paid by the options token holder during redemption
    IERC20 public immutable paymentToken;

    /// @notice The underlying token purchased during redemption
    ERC20 public immutable underlyingToken;

    /// Storage variables

    /// @notice The oracle contract that provides the current price to purchase
    /// the underlying token while exercising options (the strike price)
    IOracle public oracle;

    /// @notice The multiplier applied to the TWAP value. Encodes the discount of
    /// the options token. Uses 4 decimals.
    uint256 public multiplier;

    /// @notice The treasury address which receives tokens paid during redemption
    address public treasury;

    constructor(
        OptionsToken oToken_,
        address owner_,
        IERC20 paymentToken_,
        ERC20 underlyingToken_,
        IOracle oracle_,
        uint256 multiplier_,
        address treasury_
    ) BaseExercise(oToken_) Owned(owner_) {
        paymentToken = paymentToken_;
        underlyingToken = underlyingToken_;
        oracle = oracle_;
        multiplier = multiplier_;
        treasury = treasury_;

        emit SetOracle(oracle_);
        emit SetTreasury(treasury_);
        emit SetMultiplier(multiplier_);
    }

    /// External functions

    /// @notice Exercises options tokens to purchase the underlying tokens.
    /// @dev The oracle may revert if it cannot give a secure result.
    /// @param from The user that is exercising their options tokens
    /// @param amount The amount of options tokens to exercise
    /// @param recipient The recipient of the purchased underlying tokens
    /// @param params Extra parameters to be used by the exercise function
    function exercise(
        address from,
        uint256 amount,
        address recipient,
        bytes memory params
    )
        external
        virtual
        override
        onlyOToken
        returns (uint paymentAmount, address, uint256, uint256)
    {
        return _exercise(from, amount, recipient, params);
    }

    function getPaymentAmount(
        uint256 amount
    ) external view override returns (uint256 paymentAmount) {
        paymentAmount = amount.mulWadUp(oracle.getPrice());
        return paymentAmount;
    }

    /// Owner functions

    /// @notice Sets the oracle contract. Only callable by the owner.
    /// @param oracle_ The new oracle contract
    function setOracle(IOracle oracle_) external onlyOwner {
        oracle = oracle_;
        emit SetOracle(oracle_);
    }

    /// @notice Sets the discount multiplier.
    /// @param multiplier_ The new multiplier
    function setMultiplier(uint256 multiplier_) external onlyOwner {
        multiplier = multiplier_;
        emit SetMultiplier(multiplier_);
    }

    /// @notice Sets the treasury address. Only callable by the owner.
    /// @param treasury_ The new treasury address
    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
        emit SetTreasury(treasury_);
    }

    /// Internal functions

    function _exercise(
        address from,
        uint256 amount,
        address recipient,
        bytes memory params
    )
        internal
        virtual
        returns (uint256 paymentAmount, address, uint256, uint256)
    {
        // decode params
        DiscountExerciseParams memory _params = abi.decode(
            params,
            (DiscountExerciseParams)
        );

        if (block.timestamp > _params.deadline) revert Exercise__PastDeadline();

        // apply multiplier to price
        uint256 price = oracle.getPrice().mulDivUp(
            multiplier,
            MULTIPLIER_DENOM
        );
        // transfer payment tokens from user to the treasury
        // this price includes the discount
        paymentAmount = amount.mulWadUp(price);
        if (paymentAmount > _params.maxPaymentAmount)
            revert Exercise__SlippageTooHigh();
        paymentToken.safeTransferFrom(from, treasury, paymentAmount);

        // transfer underlying tokens to recipient
        underlyingToken.safeTransfer(recipient, amount);

        emit Exercised(from, recipient, amount, paymentAmount);
    }
}

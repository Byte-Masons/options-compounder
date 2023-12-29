// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {Owned} from "solmate/auth/Owned.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {IOracle} from "../interfaces/IOracle.sol";
import {IVault} from "../interfaces/IBalancerVault.sol";
import {IBalancerTwapOracle} from "../interfaces/IBalancerTwapOracle.sol";

/// @title Oracle using Balancer TWAP oracle as data source
/// @author zefram.eth
/// @notice The oracle contract that provides the current price to purchase
/// the underlying token while exercising options. Uses Balancer TWAP oracle
/// as data source, and then applies a multiplier & lower bound.
/// @dev IMPORTANT: The payment token and the underlying token must use 18 decimals.
/// This is because the Balancer oracle returns the TWAP value in 18 decimals
/// and the OptionsToken contract also expects 18 decimals.
contract BalancerOracle is IOracle, Owned {
    /// -----------------------------------------------------------------------
    /// Library usage
    /// -----------------------------------------------------------------------

    using FixedPointMathLib for uint256;

    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error BalancerOracle__TWAPOracleNotReady();
    error BalancerOracle__BelowMinPrice();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event SetParams(uint56 secs, uint56 ago, uint128 minPrice);

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    /// @notice The Balancer TWAP oracle contract (usually a pool with oracle support)
    IBalancerTwapOracle public immutable balancerTwapOracle;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// @notice The size of the window to take the TWAP value over in seconds.
    uint56 public secs;

    /// @notice The number of seconds in the past to take the TWAP from. The window
    /// would be (block.timestamp - secs - ago, block.timestamp - ago].
    uint56 public ago;

    /// @notice The minimum value returned by getPrice(). Maintains a floor for the
    /// price to mitigate potential attacks on the TWAP oracle.
    uint128 public minPrice;

    /// @notice Whether the price should be returned in terms of token0.
    /// If false, the price is returned in terms of token1.
    bool public isToken0;

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(
        IBalancerTwapOracle balancerTwapOracle_,
        address token,
        address owner_,
        uint56 secs_,
        uint56 ago_,
        uint128 minPrice_
    ) Owned(owner_) {
        balancerTwapOracle = balancerTwapOracle_;

        IVault vault = balancerTwapOracle.getVault();
        (address[] memory poolTokens,,) = vault.getPoolTokens(balancerTwapOracle_.getPoolId());
        isToken0 = poolTokens[0] == token;

        secs = secs_;
        ago = ago_;
        minPrice = minPrice_;

        emit SetParams(secs_, ago_, minPrice_);
    }

    /// -----------------------------------------------------------------------
    /// IOracle
    /// -----------------------------------------------------------------------

    /// @inheritdoc IOracle
    function getPrice() external view override returns (uint256 price) {
        /// -----------------------------------------------------------------------
        /// Storage loads
        /// -----------------------------------------------------------------------

        uint256 secs_ = secs;
        uint256 ago_ = ago;
        uint256 minPrice_ = minPrice;

        /// -----------------------------------------------------------------------
        /// Validation
        /// -----------------------------------------------------------------------

        // ensure the Balancer oracle can return a TWAP value for the specified window
        {
            uint256 largestSafeQueryWindow = balancerTwapOracle.getLargestSafeQueryWindow();
            if (secs_ + ago_ > largestSafeQueryWindow) revert BalancerOracle__TWAPOracleNotReady();
        }

        /// -----------------------------------------------------------------------
        /// Computation
        /// -----------------------------------------------------------------------

        // query Balancer oracle to get TWAP value
        {
            IBalancerTwapOracle.OracleAverageQuery[]
                memory queries = new IBalancerTwapOracle.OracleAverageQuery[](
                    1
                );
            queries[0] = IBalancerTwapOracle.OracleAverageQuery({
                variable: IBalancerTwapOracle.Variable.PAIR_PRICE,
                secs: secs_,
                ago: ago_
            });
            price = balancerTwapOracle.getTimeWeightedAverage(queries)[0];
        }

        if (isToken0) {
            // convert price to token0
            price = uint256(1e18).divWadDown(price);
        }

        // apply min price
        if (price < minPrice_) revert BalancerOracle__BelowMinPrice();
    }

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    /// @notice Updates the oracle parameters. Only callable by the owner.
    /// @param multiplier_ The multiplier applied to the TWAP value. Encodes the discount of
    /// the options token. Uses 4 decimals.
    /// @param secs_ The size of the window to take the TWAP value over in seconds.
    /// @param ago_ The number of seconds in the past to take the TWAP from. The window
    /// would be (block.timestamp - secs - ago, block.timestamp - ago].
    /// @param minPrice_ The minimum value returned by getPrice(). Maintains a floor for the
    /// price to mitigate potential attacks on the TWAP oracle.
    function setParams(address token, uint16 multiplier_, uint56 secs_, uint56 ago_, uint128 minPrice_) external onlyOwner {
        IVault vault = balancerTwapOracle.getVault();
        (address[] memory poolTokens,,) = vault.getPoolTokens(balancerTwapOracle.getPoolId());
        isToken0 = poolTokens[0] == token;

        secs = secs_;
        ago = ago_;
        minPrice = minPrice_;
        emit SetParams(secs_, ago_, minPrice_);
    }
}

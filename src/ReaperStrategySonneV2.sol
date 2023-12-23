// SPDX-License-Identifier: BUSL1.1

pragma solidity ^0.8.0;

import {ReaperStrategySonne} from "./ReaperStrategySonne.sol";
import {SafeERC20Upgradeable} from "./helpers/SafeERC20Upgradeable.sol";
import {IERC20Upgradeable} from "./interfaces/IERC20Upgradeable.sol";

contract ReaperStrategySonneV2 is ReaperStrategySonne {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    /**
     * @dev Does one step of leveraging
     */
    function _leverUpStep(
        uint256 _borrowIncreaseAmount
    ) internal override returns (uint256) {
        if (_borrowIncreaseAmount == 0) {
            return 0;
        }

        uint256 supplied = cWant.balanceOfUnderlying(address(this));
        uint256 borrowed = cWant.borrowBalanceStored(address(this));
        (, uint256 collateralFactorMantissa, ) = comptroller.markets(
            address(cWant)
        );
        uint256 canBorrow = (supplied * collateralFactorMantissa) / MANTISSA;

        canBorrow -= borrowed;

        if (canBorrow < _borrowIncreaseAmount) {
            _borrowIncreaseAmount = canBorrow;
        }

        if (_borrowIncreaseAmount > 10) {
            // borrow available amount (return value of 0 means success)
            require(cWant.borrow(_borrowIncreaseAmount) == 0);

            // deposit borrowed want as collateral
            IERC20Upgradeable(want).safeIncreaseAllowance(
                address(cWant),
                _borrowIncreaseAmount
            );
            cWant.mint(_borrowIncreaseAmount);
        }

        return _borrowIncreaseAmount;
    }
}

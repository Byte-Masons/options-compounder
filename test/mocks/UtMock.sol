// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.0;

import {MintableERC20} from "./MintableERC20.sol";
import {MinAmountOutData} from "../../src/interfaces/ISwapper.sol";
import {ReaperStrategySonne} from "../strategies/ReaperStrategySonne.sol";

contract UtMock {
    MintableERC20 public mockedPaymentToken;
    MintableERC20 public mockedUnderlyingToken;
    MintableERC20 public mockedUnderlyingWant;
    ReaperStrategySonne strategy;

    uint256 paymentBalanceAfterSwap;
    uint256 public nrOfCallsSwapBal;
    uint256 public nrOfCallsExercise;
    uint256 public nrOfCallsFlashloan;
    uint256 public premium;
    uint256 public oTokensAmount;
    uint256 factor; // 0 - 10_000

    constructor(
        uint256 _paymentAmount,
        uint256 _initialPaymentBalance,
        uint256 _paymentBalanceAfterSwap,
        uint256 _wantAmount,
        uint256 _oTokensAmount,
        uint256 _premium,
        address _strategyAddress,
        uint256 _factor
    ) {
        require(
            _paymentAmount >= _initialPaymentBalance,
            "Initial balance greater"
        );
        mockedPaymentToken = new MintableERC20("Payment Token", "PT");
        mockedUnderlyingToken = new MintableERC20("Underlying Token", "UT");
        mockedUnderlyingWant = new MintableERC20("Underlying Want", "UW");
        mockedPaymentToken.mint(_paymentAmount);
        mockedPaymentToken.transfer(_strategyAddress, _initialPaymentBalance);
        mockedUnderlyingWant.mint(_wantAmount);
        mockedUnderlyingToken.mint(_oTokensAmount);
        oTokensAmount = _oTokensAmount;
        strategy = ReaperStrategySonne(_strategyAddress);
        premium = _premium;
        paymentBalanceAfterSwap = _paymentBalanceAfterSwap;
        factor = _factor;
    }

    function underlyingToken() external view returns (address) {
        return address(mockedUnderlyingToken);
    }

    function paymentToken() external view returns (address) {
        return address(mockedPaymentToken);
    }

    function getPaymentAmount(uint256 _amount) external view returns (uint256) {
        return (_amount * factor) / 10_000;
    }

    function swapBal(
        address _from,
        address _to,
        uint256 _amount,
        MinAmountOutData memory _minAmountOutData,
        address _vault
    ) external returns (uint256) {
        nrOfCallsSwapBal++;
        if (_to == address(mockedPaymentToken)) {
            mockedPaymentToken.transfer(
                address(strategy),
                paymentBalanceAfterSwap
            );
        } else if (_to == address(mockedUnderlyingWant)) {
            mockedUnderlyingWant.transfer(
                address(strategy),
                mockedUnderlyingWant.balanceOf(address(this))
            );
        }
        return 0;
    }

    function exercise(
        uint256 amount,
        address recipient,
        address option,
        bytes calldata params
    ) external returns (uint256 paymentAmount, address, uint256, uint256) {
        nrOfCallsExercise++;
    }

    function underlying() external view returns (address) {
        return address(mockedUnderlyingWant);
    }

    function getLendingPool() external view returns (address) {
        return address(this);
    }

    function isExerciseContract(address) external returns (bool) {
        return true;
    }

    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external {
        require(
            amounts[0] <= mockedPaymentToken.balanceOf(address(this)),
            "Amount greater than balance"
        );
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = premium;
        nrOfCallsFlashloan++;
        strategy.executeOperation(
            assets,
            amounts,
            premiums,
            msg.sender,
            params
        );
    }

    function comptroller() external view returns (address) {
        return address(this);
    }

    function enterMarkets(address[] memory) external {}

    function markets(address) external pure returns (bool, uint256, bool) {
        return (false, (0.011 ether), false);
    }

    function balanceOf(address account) external view returns (uint256) {
        return oTokensAmount;
    }

    function getPrice() external view returns (uint256) {
        return 110;
    }
}

//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {MintableERC20} from "./MintableERC20.sol";
import {MinAmountOutData} from "../../src/interfaces/ISwapper.sol";
import {ReaperStrategySonne} from "../strategies/ReaperStrategySonne.sol";

contract UtMock {
    MintableERC20 mockedPaymentToken;
    MintableERC20 mockedUnderlyingToken;
    MintableERC20 mockedUnderlyingWant;
    ReaperStrategySonne strategy;

    uint256 paymentBalanceAfterSwap;
    uint256 public nrOfCallsSwapBal;
    uint256 public nrOfCallsExercise;
    uint256 public nrOfCallsFlashloan;
    uint256 public premium;
    uint256 factor = 5000; // 0 - 10_000

    constructor(
        uint256 _paymentAmount,
        uint256 _initialPaymentBalance,
        uint256 _paymentBalanceAfterSwap,
        uint256 _underlyingAmount,
        uint256 _wantAmount,
        uint256 _premium,
        address _strategyAddress
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
        mockedUnderlyingToken.mint(_underlyingAmount);
        mockedUnderlyingWant.mint(_wantAmount);
        strategy = ReaperStrategySonne(_strategyAddress);
        premium = _premium;
        paymentBalanceAfterSwap = _paymentBalanceAfterSwap;
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
        //console2.log("Transfering payment tokens ", amounts[0]);
        //mockedPaymentToken.transfer(address(strategy), amounts[0]);
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
        return 123;
    }
}

// SPDX-License-Identifier: BUSL1.1

pragma solidity ^0.8.0;

import {IOptionsToken} from "optionsToken/src/interfaces/IOptionsToken.sol";

enum ExchangeType {
    UniV2,
    Bal,
    ThenaRam,
    UniV3
}

struct SwapProps {
    address exchangeAddress;
    ExchangeType exchangeTypes;
    uint256 maxSwapSlippage;
}

/* Errors */
error OptionsCompounder__NotExerciseContract();
error OptionsCompounder__TooMuchAssetsLoaned();
error OptionsCompounder__FlashloanNotProfitableEnough();
error OptionsCompounder__AssetNotEqualToPaymentToken();
error OptionsCompounder__FlashloanNotFinished();
error OptionsCompounder__OnlyStratAllowed();
error OptionsCompounder__FlashloanNotTriggered();
error OptionsCompounder__InvalidExchangeType(uint256 exchangeTypes);
error OptionsCompounder__SlippageGreaterThanMax();
error OptionsCompounder__ParamHasAddressZero();
error OptionsCompounder__NotEnoughUnderlyingTokens();
error OptionsCompounder__WrongMinPaymentAmount();

interface IOptionsCompounder {
    function harvestOTokens(
        uint256 amount,
        address exerciseContract,
        uint256 minWantAmount
    ) external;

    function getOptionTokenAddress() external returns (address);
}

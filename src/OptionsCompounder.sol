//SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "./OptionsToken.sol";

//import "@aave/core-v3/contracts/flashloan/base/FlashLoanSimpleReceiverBase.sol";
//import "Swapper.sol";

contract OptionsCompounder is FlashLoanSimpleReceiverBase {
    constructor()
        FlashLoanSimpleReceiverBase(IPoolAddressesProvider(_addressProvider))
    {}

    function execute(
        address tokenFrom,
        address tokenTo,
        address dex1,
        address dex2,
        uint256 amount
    ) external {
        require(flashloanFinished, "Flashloan not finished");
        flashloanFinished = false;
        lastExecutor = msg.sender;
        address receiverAddress = address(this);
        uint16 referralCode = 0;

        bytes memory params = abi.encode(
            tokenFrom,
            tokenTo,
            dex1,
            dex2,
            amount
        );

        console.log(tokenFrom);
        console.log(tokenTo);

        POOL.flashLoanSimple(
            receiverAddress,
            tokenFrom,
            amount,
            params,
            referralCode
        );
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external override returns (bool) {
        (
            address tokenFrom,
            address tokenTo,
            address dex1,
            address dex2,
            uint256 _amount
        ) = abi.decode(params, (address, address, address, address, uint256));

        flashloanFinished = true;

        IERC20(tokenFrom).approve(address(tradeExecutor), _amount);

        uint256 amountPurchased = tradeExecutor.executeTrade(
            dex1,
            tokenFrom,
            tokenTo,
            _amount
        );

        IERC20(tokenTo).approve(address(tradeExecutor), amountPurchased);

        tradeExecutor.executeTrade(dex2, tokenTo, tokenFrom, amountPurchased);

        uint256 totalAmount = amount + premium;
        IERC20(asset).approve(address(POOL), totalAmount);

        return true;
    }

    function compoundOptions() external {}
}

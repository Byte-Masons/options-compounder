// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.13;

import "./Common.sol";

import {ReaperStrategySonne} from "./strategies/ReaperStrategySonne.sol";
import {ReaperStrategyGranary} from "./strategies/ReaperStrategyGranary.sol";
import {BalancerOracle} from "optionsToken/src/oracles/BalancerOracle.sol";
import {SwapProps, ExchangeType} from "../src/OptionsCompounder.sol";
import {CErc20I} from "./strategies/interfaces/CErc20I.sol";
import {OptionsToken} from "optionsToken/src/OptionsToken.sol";
import {MockBalancerTwapOracle} from "optionsToken/test/mocks/MockBalancerTwapOracle.sol";
import {Helper} from "./mocks/HelperFunctions.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {IAToken} from "./strategies/interfaces/IAToken.sol";
import {IOracle} from "optionsToken/src/interfaces/IOracle.sol";

contract OptionsTokenTest is Common {
    using FixedPointMathLib for uint256;

    /* Variable assignment (depends on chain) */
    uint256 FORK_BLOCK = 115072010;
    string MAINNET_URL = vm.envString("OP_RPC_URL_MAINNET");

    /* Contract variables */
    CErc20I cusdc;
    MockBalancerTwapOracle underlyingPaymentMock;
    BalancerOracle underlyingPaymentOracle;
    BalancerOracle paymentWantOracle;
    ReaperStrategySonne strategySonne;
    ReaperStrategySonne strategySonneProxy;
    ReaperStrategyGranary strategyGranary;
    ReaperStrategyGranary strategyGranaryProxy;
    Helper helper;
    uint256 initTwap;

    /* Functions */
    function setUp() public {
        /* Common assignments */
        ExchangeType[] memory exchangeTypes = new ExchangeType[](2);
        exchangeTypes[0] = ExchangeType.Bal;
        exchangeTypes[1] = ExchangeType.Bal;
        cusdc = CErc20I(OP_CUSDC);
        nativeToken = IERC20(OP_WETH);
        paymentToken = nativeToken;
        underlyingToken = IERC20(OP_OATHV1);
        wantToken = IERC20(OP_USDC);
        paymentUnderlyingBpt = OP_OATHV1_ETH_BPT;
        paymentWantBpt = OP_BTC_WETH_USDC_BPT;
        balancerVault = OP_BEETX_VAULT;

        /* Setup accounts */
        fixture_setupAccountsAndFees(1500, 200);
        vm.deal(address(this), AMOUNT * 3);
        vm.deal(owner, AMOUNT * 3);

        /* Setup network */
        uint256 optimismFork = vm.createFork(MAINNET_URL, FORK_BLOCK);
        vm.selectFork(optimismFork);

        /* Setup roles */
        address[] memory strategists = new address[](1);
        address[] memory multisigRoles = new address[](3);
        address[] memory keepers = new address[](1);
        strategists[0] = strategist;
        multisigRoles[0] = management1;
        multisigRoles[1] = management2;
        multisigRoles[2] = management3;
        keepers[0] = keeper;

        /* Variables */
        SwapProps[] memory swapProps = new SwapProps[](2);
        swapProps[0] = SwapProps(OP_BEETX_VAULT, ExchangeType.Bal);
        swapProps[1] = SwapProps(OP_BEETX_VAULT, ExchangeType.Bal);
        uint256 targetLTV = 0.0001 ether;

        /**** Contract deployments and configurations ****/
        helper = new Helper();

        /* Reaper deployment and configuration */
        reaperSwapper = new ReaperSwapper();
        tmpProxy = new ERC1967Proxy(address(reaperSwapper), "");
        reaperSwapper = ReaperSwapper(address(tmpProxy));
        reaperSwapper.initialize(strategists, address(this), address(this));

        /* Configure swapper */
        fixture_configureSwapper(exchangeTypes);

        /* Oracle mocks deployment */
        address[] memory tokens = new address[](2);
        tokens[0] = address(underlyingToken);
        tokens[1] = address(paymentToken);
        underlyingPaymentMock = new MockBalancerTwapOracle(tokens);
        underlyingPaymentOracle = new BalancerOracle(
            underlyingPaymentMock,
            address(underlyingToken),
            owner,
            ORACLE_SECS,
            ORACLE_AGO,
            ORACLE_MIN_PRICE
        );

        tokens[0] = address(paymentToken);
        tokens[1] = address(wantToken);
        MockBalancerTwapOracle paymentWantMock = new MockBalancerTwapOracle(
            tokens
        );
        paymentWantOracle = new BalancerOracle(
            paymentWantMock,
            address(paymentToken),
            owner,
            ORACLE_SECS,
            ORACLE_AGO,
            ORACLE_MIN_PRICE
        );

        IOracle[] memory oracles = new IOracle[](2);
        oracles[0] = IOracle(address(underlyingPaymentOracle));
        oracles[1] = IOracle(address(paymentWantOracle));

        /* Option token deployment */
        vm.startPrank(owner);
        optionsToken = new OptionsToken();
        tmpProxy = new ERC1967Proxy(address(optionsToken), "");
        optionsTokenProxy = OptionsToken(address(tmpProxy));
        optionsTokenProxy.initialize(
            "TIT Call Option Token",
            "oTIT",
            tokenAdmin
        );
        /* Exercise contract deployment */
        exerciser = new DiscountExercise(
            optionsTokenProxy,
            owner,
            paymentToken,
            underlyingToken,
            underlyingPaymentOracle,
            PRICE_MULTIPLIER,
            treasuries,
            feeBPS
        );
        /* Add exerciser to the list of options */

        optionsTokenProxy.setExerciseContract(address(exerciser), true);

        uint256[] memory slippages = new uint256[](2);
        slippages[0] = 200; // 2%
        slippages[1] = 1000; // 10%

        /* Sonne strategy deployment */
        strategySonne = new ReaperStrategySonne();
        tmpProxy = new ERC1967Proxy(address(strategySonne), "");
        strategySonneProxy = ReaperStrategySonne(address(tmpProxy));
        strategySonneProxy.initialize(
            vault,
            address(reaperSwapper),
            strategists,
            multisigRoles,
            keepers,
            address(cusdc),
            address(optionsTokenProxy),
            OP_POOL_ADDRESSES_PROVIDER_V2,
            targetLTV,
            slippages,
            swapProps,
            oracles
        );

        /* Granary strategy deployment */
        strategyGranary = new ReaperStrategyGranary();
        tmpProxy = new ERC1967Proxy(address(strategyGranary), "");
        strategyGranaryProxy = ReaperStrategyGranary(address(tmpProxy));
        strategyGranaryProxy.initialize(
            vault,
            address(reaperSwapper),
            strategists,
            multisigRoles,
            keepers,
            IAToken(OP_GUSDC),
            targetLTV,
            2 * targetLTV,
            OP_POOL_ADDRESSES_PROVIDER_V2,
            OP_DATA_PROVIDER,
            REWARDER,
            address(optionsTokenProxy),
            slippages,
            swapProps,
            oracles
        );
        vm.stopPrank();

        /* Prepare EOA and contracts for tests */
        helper.wrapEth{value: AMOUNT * 2}(address(nativeToken));

        MinAmountOutData memory minAmountOutData = MinAmountOutData(
            MinAmountOutKind.Absolute,
            0
        );
        paymentToken.approve(address(reaperSwapper), AMOUNT);
        reaperSwapper.swapBal(
            address(paymentToken),
            address(underlyingToken),
            AMOUNT,
            minAmountOutData,
            OP_BEETX_VAULT
        );
        uint256 underlyingBalance = underlyingToken.balanceOf(address(this));
        initTwap = AMOUNT.mulDivUp(1e18, underlyingBalance); // Inaccurate solution but it is not crucial to have real accurate oracle price
        underlyingToken.transfer(address(exerciser), underlyingBalance);

        /* Set up contracts - added here to calculate initTwap after swap */
        underlyingPaymentMock.setTwapValue(initTwap);
        // 1e18 = 25e20 => 25e8 USDC with 6 decimals (4e14)
        paymentWantMock.setTwapValue(22e8); // 1 ETH = 2200 USDC
        paymentToken.approve(address(exerciser), type(uint256).max);
    }

    function test_flashloanPositiveScenarioSonne(uint256 amount) public {
        /* Test vectors definition */
        amount = bound(
            amount,
            MIN_OATH_FOR_FUZZING,
            underlyingToken.balanceOf(address(exerciser))
        );

        /* Prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        fixture_prepareOptionToken(
            amount,
            address(strategySonneProxy),
            optionsTokenProxy,
            tokenAdmin
        );

        /* Check balances before compounding */
        uint256 paymentTokenBalance = paymentToken.balanceOf(
            address(strategySonneProxy)
        );
        uint256 wantBalance = wantToken.balanceOf(address(strategySonneProxy));

        vm.startPrank(keeper);
        /* already approved in fixture_prepareOptionToken */
        strategySonneProxy.harvestOTokens(
            amount,
            address(exerciser),
            NON_ZERO_PROFIT
        );
        vm.stopPrank();

        /* Assertions */
        assertEq(
            wantToken.balanceOf(address(strategySonneProxy)) > wantBalance,
            true,
            "Gain not greater than 0"
        );
        assertEq(
            paymentTokenBalance <=
                paymentToken.balanceOf(address(strategySonneProxy)),
            true,
            "Lower paymentToken balance than before"
        );
        assertEq(
            wantBalance <= wantToken.balanceOf(address(strategySonneProxy)),
            true,
            "Lower want balance than before"
        );
        assertEq(
            0 == optionsTokenProxy.balanceOf(address(strategySonneProxy)),
            true,
            "Options token balance is not 0"
        );
    }

    function test_flashloanPositiveScenarioGranary(uint256 amount) public {
        /* Test vectors definition */
        amount = bound(
            amount,
            MIN_OATH_FOR_FUZZING,
            underlyingToken.balanceOf(address(exerciser))
        );

        /* Prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        fixture_prepareOptionToken(
            amount,
            address(strategyGranaryProxy),
            optionsTokenProxy,
            tokenAdmin
        );

        /* Check balances before compounding */
        uint256 paymentTokenBalance = paymentToken.balanceOf(
            address(strategyGranaryProxy)
        );
        uint256 wantBalance = wantToken.balanceOf(
            address(strategyGranaryProxy)
        );

        vm.startPrank(keeper);

        /* Already approved in fixture_prepareOptionToken */
        strategyGranaryProxy.harvestOTokens(
            amount,
            address(exerciser),
            NON_ZERO_PROFIT
        );
        vm.stopPrank();

        /* Assertions */
        assertEq(
            wantToken.balanceOf(address(strategyGranaryProxy)) > wantBalance,
            true,
            "Gain not greater than 0"
        );
        assertEq(
            paymentTokenBalance <=
                paymentToken.balanceOf(address(strategyGranaryProxy)),
            true,
            "Lower paymentToken balance than before"
        );
        assertEq(
            wantBalance <= wantToken.balanceOf(address(strategyGranaryProxy)),
            true,
            "Lower want balance than before"
        );
        assertEq(
            0 == optionsTokenProxy.balanceOf(address(strategyGranaryProxy)),
            true,
            "Options token balance is not 0"
        );
    }

    function test_accessControlFunctionsChecks(
        address hacker,
        address randomOption,
        uint256 amount
    ) public {
        /* Test vectors definition */
        amount = bound(
            amount,
            MIN_OATH_FOR_FUZZING,
            underlyingToken.balanceOf(address(exerciser))
        );
        vm.assume(
            hacker != owner &&
                hacker != keeper &&
                hacker != management1 &&
                hacker != management2 &&
                hacker != management3
        );
        SwapProps[] memory swapProps = new SwapProps[](2);
        IOracle[] memory oracles = new IOracle[](2);
        /* Hacker tries to perform harvest */
        vm.startPrank(hacker);
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__OnlyKeeperAllowed()"))
        );
        strategySonneProxy.harvestOTokens(
            amount,
            address(exerciser),
            NON_ZERO_PROFIT
        );

        /* Hacker tries to manipulate contract configuration */
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__OnlyAdminsAllowed()"))
        );
        strategySonneProxy.setOptionToken(randomOption);

        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__OnlyAdminsAllowed()"))
        );
        strategySonneProxy.configSwapProps(swapProps);

        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__OnlyAdminsAllowed()"))
        );
        strategySonneProxy.setOracles(oracles);

        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__OnlyAdminsAllowed()"))
        );
        uint256[] memory slippages = new uint256[](2);
        slippages[0] = 1000;
        slippages[0] = 2000;
        strategySonneProxy.setMaxSwapSlippage(slippages);
        vm.stopPrank();

        /* Admin tries to set different option token */
        vm.startPrank(owner);
        strategySonneProxy.setOptionToken(randomOption);
        vm.stopPrank();
        assertEq(address(strategySonneProxy.optionToken()), randomOption);
    }

    function test_wrongLengthOfParams(uint256 paramsLength) public {
        /* Test vectors definition */
        paramsLength = bound(paramsLength, 0, 10);
        vm.assume(paramsLength != strategySonneProxy.requiredParamsLength());

        SwapProps[] memory swapProps = new SwapProps[](paramsLength);
        IOracle[] memory oracles = new IOracle[](paramsLength);
        uint256[] memory maxSwapSlippages = new uint256[](2);
        maxSwapSlippages[0] = 10000;
        maxSwapSlippages[1] = 10001;

        /* Passing wrong number of elements into configSwapProps */
        vm.startPrank(management1);
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__WrongNumberOfParams()"))
        );
        strategySonneProxy.configSwapProps(swapProps);

        /* Passing wrong number of elements into setOracles */
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__WrongNumberOfParams()"))
        );
        strategySonneProxy.setOracles(oracles);
        /* Passing wrong number setMaxSwapSlippage */
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__SlippageGreaterThanMax()"))
        );
        strategySonneProxy.setMaxSwapSlippage(maxSwapSlippages);

        vm.stopPrank();
    }

    function test_flashloanNegativeScenario_highTwapValueAndMultiplier(
        uint256 amount
    ) public {
        /* Test vectors definition */
        amount = bound(
            amount,
            MIN_OATH_FOR_FUZZING,
            1000 * MIN_OATH_FOR_FUZZING
        );

        /* Prepare option tokens - distribute them to the specified strategy
        and approve for spending */
        fixture_prepareOptionToken(
            amount,
            address(strategySonneProxy),
            optionsTokenProxy,
            tokenAdmin
        );

        /* Set high slippage to allow unefficient swap - consider test it later and try to make flasloan unprofitable instead of swap revert*/
        // vm.startPrank(management1);
        // uint256[] memory maxSwapSlippages = new uint256[](2);
        // maxSwapSlippages[0] = 200; // 2%
        // maxSwapSlippages[1] = 4000; // 40%
        // strategySonneProxy.setMaxSwapSlippage(maxSwapSlippages);
        // vm.stopPrank();

        /* Decrease option discount in order to make redemption not profitable */
        /* Notice: Multiplier must be higher than denom because of oracle inaccuracy (initTwap) or just change initTwap */
        vm.startPrank(owner);
        exerciser.setMultiplier(9999);
        vm.stopPrank();
        /* Increase TWAP price to make flashloan not profitable */
        underlyingPaymentMock.setTwapValue(initTwap + ((initTwap * 10) / 100));

        /* Notice: additional protection is in exerciser: Exercise__SlippageTooHigh */
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__FlashloanNotProfitable()"))
        );

        vm.startPrank(keeper);
        /* Already approved in fixture_prepareOptionToken */
        strategySonneProxy.harvestOTokens(
            amount,
            address(exerciser),
            NON_ZERO_PROFIT
        );
        vm.stopPrank();
    }

    function test_flashloanNegativeScenario_highTwapValueAndMultiplier_BAL507(
        uint256 amount
    ) public {
        /* Test vectors definition */
        amount = bound(
            amount,
            5000 * MIN_OATH_FOR_FUZZING,
            underlyingToken.balanceOf(address(exerciser))
        );

        /* Prepare option tokens - distribute them to the specified strategy
        and approve for spending */
        fixture_prepareOptionToken(
            amount,
            address(strategySonneProxy),
            optionsTokenProxy,
            tokenAdmin
        );

        /* Set high slippage to allow unefficient swap - consider test it later and try to make flasloan unprofitable instead of swap revert*/
        // vm.startPrank(management1);
        // uint256[] memory maxSwapSlippages = new uint256[](2);
        // maxSwapSlippages[0] = 200; // 2%
        // maxSwapSlippages[1] = 4000; // 40%
        // strategySonneProxy.setMaxSwapSlippage(maxSwapSlippages);
        // vm.stopPrank();

        /* Decrease option discount in order to make redemption not profitable */
        /* Notice: Multiplier must be higher than denom because of oracle inaccuracy (initTwap) or just change initTwap */
        vm.startPrank(owner);
        exerciser.setMultiplier(9999);
        vm.stopPrank();
        /* Increase TWAP price to make flashloan not profitable */
        underlyingPaymentMock.setTwapValue(initTwap + ((initTwap * 10) / 100));

        /* Notice: additional protection is in exerciser: Exercise__SlippageTooHigh */
        // vm.expectRevert(
        //     bytes4(keccak256("OptionsCompounder__FlashloanNotProfitable()"))
        // );
        vm.expectRevert("BAL#507");

        vm.startPrank(keeper);
        /* Already approved in fixture_prepareOptionToken */
        strategySonneProxy.harvestOTokens(
            amount,
            address(exerciser),
            NON_ZERO_PROFIT
        );
        vm.stopPrank();
    }

    function test_flashloanNegativeScenario_tooHighMinAmounOfWantExpected(
        uint256 amount,
        uint256 minAmountOfWant
    ) public {
        /* Test vectors definition */
        amount = bound(
            amount,
            MIN_OATH_FOR_FUZZING,
            underlyingToken.balanceOf(address(exerciser))
        );
        /* Too high expectation of profit - together with high exerciser multiplier makes flashloan not profitable */
        minAmountOfWant = bound(minAmountOfWant, 1e19, UINT256_MAX);

        /* Prepare option tokens - distribute them to the specified strategy
        and approve for spending */
        fixture_prepareOptionToken(
            amount,
            address(strategySonneProxy),
            optionsTokenProxy,
            tokenAdmin
        );

        /* Decrease option discount in order to make redemption not profitable */
        /* Notice: Multiplier must be higher than denom because of oracle inaccuracy (initTwap) or just change initTwap */
        vm.startPrank(owner);
        exerciser.setMultiplier(9000);
        vm.stopPrank();

        /* Notice: additional protection is in exerciser: Exercise__SlippageTooHigh */
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__FlashloanNotProfitable()"))
        );
        /* Already approved in fixture_prepareOptionToken */
        vm.startPrank(keeper);
        strategySonneProxy.harvestOTokens(
            amount,
            address(exerciser),
            minAmountOfWant
        );
        vm.stopPrank();
    }

    function test_callExecuteOperationWithoutFlashloanTrigger(
        uint256 amount,
        address executor
    ) public {
        /* Test vectors definition */
        amount = bound(
            amount,
            MIN_OATH_FOR_FUZZING,
            underlyingToken.balanceOf(address(exerciser))
        );

        /* Argument creation */
        address[] memory assets = new address[](1);
        assets[0] = address(paymentToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = DiscountExercise(exerciser).getPaymentAmount(amount);
        uint256[] memory premiums = new uint256[](1);
        bytes memory params;

        vm.startPrank(executor);
        /* Assertion */
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__FlashloanNotTriggered()"))
        );
        strategySonneProxy.executeOperation(
            assets,
            amounts,
            premiums,
            msg.sender,
            params
        );
        vm.stopPrank();
    }

    function test_harvestCallWithWrongExerciseContract(
        uint256 amount,
        address fuzzedExerciser
    ) public {
        /* Test vectors definition */
        amount = bound(
            amount,
            MIN_OATH_FOR_FUZZING,
            underlyingToken.balanceOf(address(exerciser))
        );

        vm.assume(fuzzedExerciser != address(exerciser));

        /* Prepare option tokens - distribute them to the specified strategy
        and approve for spending */
        fixture_prepareOptionToken(
            amount,
            address(strategySonneProxy),
            optionsTokenProxy,
            tokenAdmin
        );

        vm.startPrank(keeper);
        /* Assertion */
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__NotExerciseContract()"))
        );
        strategySonneProxy.harvestOTokens(
            amount,
            fuzzedExerciser,
            NON_ZERO_PROFIT
        );
        vm.stopPrank();
    }

    // function test_harvestCallWithNotFundedDiscountExercise(
    //     uint256 amount
    // ) public {
    //     /* Test vectors definition */
    //     amount = bound(
    //         amount,
    //         MIN_OATH_FOR_FUZZING,
    //         underlyingToken.balanceOf(address(exerciser))
    //     );

    //     bytes memory exerciseParams = abi.encode(
    //         DiscountExerciseParams({
    //             maxPaymentAmount: amount,
    //             deadline: type(uint256).max
    //         })
    //     );
    //     uint256 amountOptions = (underlyingToken.balanceOf(address(exerciser)) *
    //         10000) / exerciser.multiplier();
    //     console2.log(address(exerciser));
    //     /* Prepare option tokens - distribute them to the specified strategy
    //     and approve for spending */
    //     console2.log(
    //         "1. Balance: ",
    //         optionsTokenProxy.balanceOf(address(this))
    //     );

    //     fixture_prepareOptionToken(
    //         amount,
    //         address(strategySonneProxy),
    //         optionsTokenProxy,
    //         tokenAdmin
    //     );
    //     vm.startPrank(tokenAdmin);
    //     optionsTokenProxy.mint(address(this), amountOptions);
    //     vm.stopPrank();
    //     console2.log(
    //         "2. Balance: ",
    //         optionsTokenProxy.balanceOf(address(this))
    //     );
    //     console2.log(
    //         "1. UBalance: ",
    //         underlyingToken.balanceOf(address(exerciser))
    //     );
    //     paymentToken.approve(
    //         address(exerciser),
    //         paymentToken.balanceOf(address(this))
    //     );
    //     optionsTokenProxy.exercise(
    //         amountOptions,
    //         address(this),
    //         address(exerciser),
    //         exerciseParams
    //     );
    //     console2.log(
    //         "2. UBalance: ",
    //         underlyingToken.balanceOf(address(exerciser))
    //     );
    //     vm.startPrank(keeper);
    //     /* Assertion */
    //     vm.expectRevert(
    //         bytes4(keccak256("OptionsCompounder__NotEnoughUnderlyingTokens()"))
    //     );
    //     strategySonneProxy.harvestOTokens(
    //         amount,
    //         address(exerciser),
    //         NON_ZERO_PROFIT
    //     );
    //     vm.stopPrank();
    // }
}

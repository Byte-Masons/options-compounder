// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.13;

import "./Common.sol";

import {ReaperStrategySonne} from "./strategies/ReaperStrategySonne.sol";
import {ReaperStrategyGranary} from "./strategies/ReaperStrategyGranary.sol";
import {BalancerOracle} from "optionsToken/src/oracles/BalancerOracle.sol";
import {SwapProps, ExchangeType} from "../src/OptionsCompounder.sol";
import {CErc20I} from "./strategies/interfaces/CErc20I.sol";
import {OptionsToken} from "optionsToken/src/OptionsToken.sol";
import {DiscountExerciseParams, DiscountExercise} from "optionsToken/src/exercise/DiscountExercise.sol";
import {MockBalancerTwapOracle} from "optionsToken/test/mocks/MockBalancerTwapOracle.sol";
import {Helper} from "./mocks/HelperFunctions.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {IAToken} from "./strategies/interfaces/IAToken.sol";
import {IOracle} from "optionsToken/src/interfaces/IOracle.sol";

// import {ReaperSwapper, MinAmountOutData, MinAmountOutKind} from "vault-v2/ReaperSwapper.sol";
import {ReaperSwapper, MinAmountOutData, MinAmountOutKind, IVeloRouter, RouterV2} from "./mocks/ReaperSwapper.sol";

contract OptionsTokenTest is Common {
    enum TestChain {
        OPTIMISM,
        BSC
    }

    TestChain testChain = TestChain.BSC;

    using FixedPointMathLib for uint256;
    /* Constants */

    /* Variable assignment (depends on chain) */
    string MAINNET_URL = vm.envString("OP_RPC_URL_MAINNET");
    CErc20I cusdc = CErc20I(OP_CUSDC);

    IERC20 nativeToken = IERC20(BSC_WBNB);
    IERC20 paymentToken = nativeToken;
    IERC20 underlyingToken = IERC20(OP_OATHV1);
    IERC20 wantToken;
    bytes32 paymentUnderlyingBpt = OP_OATHV1_ETH_BPT;
    bytes32 paymentWantBpt = OP_BTC_WETH_USDC_BPT;
    address balancerVault = OP_BEETX_VAULT;
    ExchangeType exchangeType = ExchangeType.Bal;

    address owner;
    address tokenAdmin;
    address[] treasuries;
    uint256[] feeBPS;
    address strategist = address(4);
    address vault;
    address management1;
    address management2;
    address management3;
    address keeper;

    /* Contract variables */
    OptionsToken optionsToken;
    ERC1967Proxy tmpProxy;
    OptionsToken optionsTokenProxy;
    DiscountExercise exerciser;
    BalancerOracle oracle;
    MockBalancerTwapOracle balancerTwapOracle;
    ReaperStrategySonne strategySonne;
    ReaperStrategySonne strategySonneProxy;
    ReaperStrategyGranary strategyGranary;
    ReaperStrategyGranary strategyGranaryProxy;
    ReaperSwapper reaperSwapper;
    Helper helper;
    uint256 initTwap = 0;

    /* Functions */
    function setUp() public {
        wantToken = IERC20(cusdc.underlying());
        /* Setup accounts */
        owner = makeAddr("owner");
        tokenAdmin = makeAddr("tokenAdmin");
        treasuries = new address[](2);
        treasuries[0] = makeAddr("treasury1");
        treasuries[1] = makeAddr("treasury2");
        vault = makeAddr("vault");
        management1 = makeAddr("management1");
        management2 = makeAddr("management2");
        management3 = makeAddr("management3");
        keeper = makeAddr("keeper");
        feeBPS = new uint256[](2);
        feeBPS[0] = 10;
        feeBPS[1] = 2000;
        vm.deal(address(this), AMOUNT * 3);
        vm.deal(owner, AMOUNT * 3);

        /* Setup network */
        uint256 optimismFork = vm.createFork(MAINNET_URL); //, FORK_BLOCK);
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
        SwapProps memory swapProps = SwapProps(
            OP_BEETX_VAULT,
            ExchangeType.Bal
        );
        uint256 targetLTV = 0.0001 ether;

        /**** Contract deployments and configurations ****/
        helper = new Helper();

        /* Reaper deployment and configuration */
        reaperSwapper = new ReaperSwapper(
            strategists,
            address(this),
            address(this)
        );

        /* Configure swapper */
        fixture_configureSwapper(exchangeType);

        /* Oracle mocks deployment */
        address[] memory tokens = new address[](2);
        tokens[0] = address(underlyingToken);
        tokens[1] = address(paymentToken);
        balancerTwapOracle = new MockBalancerTwapOracle(tokens);
        oracle = new BalancerOracle(
            balancerTwapOracle,
            address(underlyingToken),
            owner,
            ORACLE_SECS,
            ORACLE_AGO,
            ORACLE_MIN_PRICE
        );

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
            oracle,
            PRICE_MULTIPLIER,
            treasuries,
            feeBPS
        );
        /* Add exerciser to the list of options */
        optionsTokenProxy.setExerciseContract(address(exerciser), true);

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
        console2.log(
            "Balance of underlying: ",
            underlyingToken.balanceOf(address(this))
        );
        reaperSwapper.swapVelo(
            address(paymentToken),
            address(underlyingToken),
            AMOUNT,
            minAmountOutData,
            veloRouter,
            type(uint256).max
        );
        console2.log(
            "Balance of underlying: ",
            underlyingToken.balanceOf(address(this))
        );
        uint256 underlyingBalance = underlyingToken.balanceOf(address(this));
        initTwap = AMOUNT.mulDivUp(1e18, underlyingBalance); // Inaccurate solution but it is not crucial to have real accurate oracle price
        underlyingToken.transfer(address(exerciser), underlyingBalance);

        /* Set up contracts */
        balancerTwapOracle.setTwapValue(initTwap);
        paymentToken.approve(address(exerciser), type(uint256).max);
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
            hacker != tokenAdmin &&
                hacker != keeper &&
                hacker != management1 &&
                hacker != management2 &&
                hacker != management3
        );

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
        vm.stopPrank();

        /* Admin tries to set different option token */
        vm.startPrank(owner);
        strategySonneProxy.setOptionToken(randomOption);
        vm.stopPrank();
        assertEq(address(strategySonneProxy.optionToken()), randomOption);
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
        fixture_prepareOptionToken(amount, address(strategySonneProxy));

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
        fixture_prepareOptionToken(amount, address(strategyGranaryProxy));

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

    function test_flashloanNegativeScenario_highTwapValueAndMultiplier(
        uint256 amount
    ) public {
        /* Test vectors definition */
        amount = bound(
            amount,
            MIN_OATH_FOR_FUZZING,
            underlyingToken.balanceOf(address(exerciser))
        );

        /* Prepare option tokens - distribute them to the specified strategy
        and approve for spending */
        fixture_prepareOptionToken(amount, address(strategySonneProxy));

        /* Decrease option discount in order to make redemption not profitable */
        /* Notice: Multiplier must be higher than denom because of oracle inaccuracy (initTwap) or just change initTwap */
        vm.startPrank(owner);
        exerciser.setMultiplier(9999);
        vm.stopPrank();
        /* Increase TWAP price to make flashloan not profitable */
        balancerTwapOracle.setTwapValue(initTwap + ((initTwap * 10) / 100));

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
        fixture_prepareOptionToken(amount, address(strategySonneProxy));

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
        fixture_prepareOptionToken(amount, address(strategySonneProxy));

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
}

// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {ReaperStrategySonne} from "./strategies/ReaperStrategySonne.sol";
import {ReaperStrategyGranary} from "./strategies/ReaperStrategyGranary.sol";
import {BalancerOracle} from "optionsToken/src/oracles/BalancerOracle.sol";
import {BEETX_VAULT_OP, SwapProps, ExchangeType} from "../src/OptionsCompounder.sol";
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

// import {ReaperSwapper, MinAmountOutData, MinAmountOutKind} from "vault-v2/ReaperSwapper.sol";
import {ReaperSwapper, MinAmountOutData, MinAmountOutKind} from "./mocks/ReaperSwapper.sol";

contract OptionsTokenTest is Test {
    using FixedPointMathLib for uint256;
    /* Constants */
    uint256 constant FORK_BLOCK = 114768697;
    uint256 constant NON_ZERO_PROFIT = 1;
    uint16 constant PRICE_MULTIPLIER = 5000; // 0.5
    uint56 constant ORACLE_SECS = 30 minutes;
    uint56 constant ORACLE_AGO = 2 minutes;
    uint128 constant ORACLE_MIN_PRICE = 1e10;
    uint56 constant ORACLE_LARGEST_SAFETY_WINDOW = 24 hours;
    uint256 constant ORACLE_MIN_PRICE_DENOM = 10000;
    uint256 constant MAX_SUPPLY = 1e27; // the max supply of the options token & the underlying token
    address constant POOL_ADDRESSES_PROVIDER_V2 =
        0xdDE5dC81e40799750B92079723Da2acAF9e1C6D6; // Granary (aavev2)
    // AAVEv3 - 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant OATHV2 = 0x00e1724885473B63bCE08a9f0a52F35b0979e35A; // V1: 0x39FdE572a18448F8139b7788099F0a0740f51205;1
    address constant CUSDC = 0xEC8FEa79026FfEd168cCf5C627c7f486D77b765F;
    address constant GUSDC = 0x7A0FDDBA78FF45D353B1630B77f4D175A00df0c0;
    address constant DATA_PROVIDER = 0x9546F673eF71Ff666ae66d01Fd6E7C6Dae5a9995;
    bytes32 constant OATHV1_ETH_BPT =
        0xd20f6f1d8a675cdca155cb07b5dc9042c467153f0002000000000000000000bc; // OATHv1/ETH BPT
    bytes32 constant OATHV2_ETH_BPT =
        0xd13d81af624956327a24d0275cbe54b0ee0e9070000200000000000000000109; // OATHv2/ETH BPT
    bytes32 constant BTC_WETH_USDC_BPT =
        0x5028497af0c9a54ea8c6d42a054c0341b9fc6168000100000000000000000004;
    uint256 constant AMOUNT = 2e18; // 2 ETH
    address constant REWARDER = 0x6A0406B8103Ec68EE9A713A073C7bD587c5e04aD;
    uint256 constant MIN_OATH_FOR_FUZZING = 1e19;

    /* Variables */
    ERC20 weth = ERC20(WETH);
    IERC20 oath = IERC20(OATHV2);
    CErc20I cusdc = CErc20I(CUSDC);
    IERC20 paymentToken;
    IERC20 underlyingToken;
    string OPTIMISM_MAINNET_URL = vm.envString("RPC_URL_MAINNET");

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
    function fixture_prepareOptionToken(
        uint256 _amount,
        address _strategy
    ) public {
        /* Mint options tokens and transfer them to the strategy (rewards simulation) */
        vm.startPrank(tokenAdmin);
        optionsTokenProxy.mint(tokenAdmin, _amount);
        optionsTokenProxy.transfer(_strategy, _amount);
        vm.stopPrank();
    }

    function setUp() public {
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
        uint256 optimismFork = vm.createFork(OPTIMISM_MAINNET_URL, FORK_BLOCK);
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
        SwapProps[] memory swapProps = new SwapProps[](1);
        swapProps[0] = SwapProps(0, BEETX_VAULT_OP, ExchangeType.Bal);
        // swapProps[1] = SwapProps(0, BEETX_VAULT_OP, ExchangeType.Bal);
        uint256 targetLTV = 0.0001 ether;

        paymentToken = IERC20(WETH);
        underlyingToken = IERC20(OATHV2);

        /**** Contract deployments and configurations ****/
        helper = new Helper();

        /* Reaper deployment and configuration */
        reaperSwapper = new ReaperSwapper(
            strategists,
            address(this),
            address(this)
        );

        /* Configure swapper */
        reaperSwapper.updateBalSwapPoolID(
            WETH,
            OATHV2,
            BEETX_VAULT_OP,
            OATHV2_ETH_BPT
        );
        reaperSwapper.updateBalSwapPoolID(
            OATHV2,
            WETH,
            BEETX_VAULT_OP,
            OATHV2_ETH_BPT
        );
        reaperSwapper.updateBalSwapPoolID(
            WETH,
            cusdc.underlying(),
            BEETX_VAULT_OP,
            BTC_WETH_USDC_BPT
        );

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
            CUSDC,
            address(optionsTokenProxy),
            POOL_ADDRESSES_PROVIDER_V2,
            targetLTV,
            swapProps
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
            IAToken(GUSDC),
            targetLTV,
            2 * targetLTV,
            POOL_ADDRESSES_PROVIDER_V2,
            DATA_PROVIDER,
            REWARDER,
            address(optionsTokenProxy),
            swapProps
        );
        vm.stopPrank();

        /* Prepare EOA and contracts for tests */
        helper.wrapEth{value: AMOUNT * 2}(WETH);

        MinAmountOutData memory minAmountOutData = MinAmountOutData(
            MinAmountOutKind.Absolute,
            0
        );
        weth.approve(address(reaperSwapper), AMOUNT);
        reaperSwapper.swapBal(
            address(weth),
            address(underlyingToken),
            AMOUNT,
            minAmountOutData,
            BEETX_VAULT_OP
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
            oath.balanceOf(address(exerciser))
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
            oath.balanceOf(address(exerciser))
        );

        /* Prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        fixture_prepareOptionToken(amount, address(strategySonneProxy));

        /* Check balances before compounding */
        IERC20 usdc = IERC20(cusdc.underlying());
        uint256 wethBalance = weth.balanceOf(address(strategySonneProxy));
        uint256 wantBalance = usdc.balanceOf(address(strategySonneProxy));

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
            usdc.balanceOf(address(strategySonneProxy)) > wantBalance,
            true,
            "Gain not greater than 0"
        );
        assertEq(
            wethBalance <= weth.balanceOf(address(strategySonneProxy)),
            true,
            "Lower weth balance than before"
        );
        assertEq(
            wantBalance <= usdc.balanceOf(address(strategySonneProxy)),
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
            oath.balanceOf(address(exerciser))
        );

        /* Prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        fixture_prepareOptionToken(amount, address(strategyGranaryProxy));

        /* Check balances before compounding */
        IERC20 usdc = IERC20(cusdc.underlying());
        uint256 wethBalance = weth.balanceOf(address(strategyGranaryProxy));
        uint256 wantBalance = usdc.balanceOf(address(strategyGranaryProxy));

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
            usdc.balanceOf(address(strategyGranaryProxy)) > wantBalance,
            true,
            "Gain not greater than 0"
        );
        assertEq(
            wethBalance <= weth.balanceOf(address(strategyGranaryProxy)),
            true,
            "Lower weth balance than before"
        );
        assertEq(
            wantBalance <= usdc.balanceOf(address(strategyGranaryProxy)),
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
            oath.balanceOf(address(exerciser))
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
            oath.balanceOf(address(exerciser))
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
            oath.balanceOf(address(exerciser))
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
            oath.balanceOf(address(exerciser))
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

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {ReaperStrategySonne} from "./strategies/ReaperStrategySonne.sol";
import {ReaperStrategyGranary} from "./strategies/ReaperStrategyGranary.sol";
import {BalancerOracle} from "optionsToken/src/oracles/BalancerOracle.sol";
import {BEETX_VAULT_OP} from "../src/OptionsCompounder.sol";
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
    uint16 constant PRICE_MULTIPLIER = 5000; // 0.5
    uint56 constant ORACLE_SECS = 30 minutes;
    uint56 constant ORACLE_AGO = 2 minutes;
    uint128 constant ORACLE_MIN_PRICE = 1e10;
    uint56 constant ORACLE_LARGEST_SAFETY_WINDOW = 24 hours;
    //uint256 constant ORACLE_INIT_TWAP_VALUE = 1e19;
    uint256 constant ORACLE_MIN_PRICE_DENOM = 10000;
    uint256 constant MAX_SUPPLY = 1e27; // the max supply of the options token & the underlying token
    address constant POOL_ADDRESSES_PROVIDER =
        0xdDE5dC81e40799750B92079723Da2acAF9e1C6D6; // Granary (aavev2)
    // AAVEv3 - 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant OATH = 0x00e1724885473B63bCE08a9f0a52F35b0979e35A; // V1: 0x39FdE572a18448F8139b7788099F0a0740f51205;
    address constant CUSDC = 0xEC8FEa79026FfEd168cCf5C627c7f486D77b765F;
    address constant GUSDC = 0x7A0FDDBA78FF45D353B1630B77f4D175A00df0c0;
    address constant DATA_PROVIDER = 0x9546F673eF71Ff666ae66d01Fd6E7C6Dae5a9995;
    bytes32 constant OATHV1_ETH_BPT =
        0xd20f6f1d8a675cdca155cb07b5dc9042c467153f0002000000000000000000bc; /* OATHv1/ETH BPT */
    bytes32 constant OATHV2_ETH_BPT =
        0xd13d81af624956327a24d0275cbe54b0ee0e9070000200000000000000000109; /* OATHv2/ETH BPT */
    bytes32 constant BTC_WETH_USDC_BPT =
        0x5028497af0c9a54ea8c6d42a054c0341b9fc6168000100000000000000000004;
    uint256 constant AMOUNT = 2e18; // 2 ETH

    address constant REWARDER = 0x6A0406B8103Ec68EE9A713A073C7bD587c5e04aD;

    /* Variables */
    ERC20 weth = ERC20(WETH);
    IERC20 oath = IERC20(OATH);
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

    function fixture_prepareOptionToken(
        uint256 _amount,
        address _strategy
    ) public {
        /* mint options tokens and transfer them to the strategy (rewards simulation) */
        vm.startPrank(tokenAdmin);
        optionsTokenProxy.mint(tokenAdmin, _amount);
        optionsTokenProxy.transfer(_strategy, _amount);
        vm.stopPrank();
    }

    function setUp() public {
        /* Test vectors definition */
        // initialAmount = bound(initialAmount, 1e17, 1e19);

        /* set up accounts */
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

        /* setup network */
        uint256 optimismFork = vm.createFork(OPTIMISM_MAINNET_URL);
        vm.selectFork(optimismFork);

        /* Variables */
        paymentToken = IERC20(WETH);
        underlyingToken = IERC20(OATH);
        address[] memory strategists = new address[](1);
        address[] memory multisigRoles = new address[](3);
        address[] memory keepers = new address[](1);
        strategists[0] = strategist;
        multisigRoles[0] = management1;
        multisigRoles[1] = management2;
        multisigRoles[2] = management3;
        keepers[0] = keeper;

        uint256 targetLTV = 0.0001 ether;

        /**** Contract deployments and configurations ****/
        helper = new Helper();

        /* Reaper deployment and configuration */
        reaperSwapper = new ReaperSwapper(
            strategists,
            address(this),
            address(this)
        );

        reaperSwapper.updateBalSwapPoolID(
            address(weth),
            address(oath),
            BEETX_VAULT_OP,
            OATHV2_ETH_BPT
        );
        reaperSwapper.updateBalSwapPoolID(
            address(oath),
            address(weth),
            BEETX_VAULT_OP,
            OATHV2_ETH_BPT
        );
        reaperSwapper.updateBalSwapPoolID(
            address(weth),
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
        // add exerciser to the list of options
        optionsTokenProxy.setExerciseContract(address(exerciser), true);

        /* Sonne strategy deployment */
        console2.log("Deployment contract");
        strategySonne = new ReaperStrategySonne();
        console2.log("Deployment strategy proxy");
        tmpProxy = new ERC1967Proxy(address(strategySonne), "");
        console2.log("Initialization proxied sonne strategy");
        strategySonneProxy = ReaperStrategySonne(address(tmpProxy));
        strategySonneProxy.initialize(
            vault,
            address(reaperSwapper),
            strategists,
            multisigRoles,
            keepers,
            CUSDC,
            address(optionsTokenProxy),
            POOL_ADDRESSES_PROVIDER,
            targetLTV
        );

        /* Granary strategy deployment */
        console2.log("Deployment contract");
        strategyGranary = new ReaperStrategyGranary();
        console2.log("Deployment strategy proxy");
        tmpProxy = new ERC1967Proxy(address(strategyGranary), "");
        console2.log("Initialization proxied sonne strategy");
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
            POOL_ADDRESSES_PROVIDER,
            DATA_PROVIDER,
            REWARDER,
            address(optionsTokenProxy)
        );
        vm.stopPrank();

        /* Prepare EOA and contracts for tests */
        helper.getWethFromEth{value: AMOUNT * 2}(WETH);

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
        initTwap = AMOUNT.mulDivUp(1e18, underlyingBalance); // Question: temporary inaccurate solution. How to get the newest price easily ?
        console2.log(">>>> Init TWAP: ", initTwap);
        oath.transfer(address(exerciser), underlyingBalance);

        // set up contracts
        balancerTwapOracle.setTwapValue(initTwap);
        paymentToken.approve(address(exerciser), type(uint256).max);

        // temp logs
        console2.log("Sonne strategy: ", address(strategySonneProxy));
        console2.log("Options Token: ", address(optionsTokenProxy));
        console2.log("Address of this contract: ", address(this));
        console2.log("Address of owner: ", owner);
        console2.log("Address of token admin: ", tokenAdmin);
    }

    function test_accessControlFunctionsChecks(
        address hacker,
        address randomOption,
        uint256 amount
    ) public {
        /* Test vectors definition */
        amount = bound(amount, 100, oath.balanceOf(address(exerciser)));
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
        strategySonneProxy.harvestOTokens(amount, address(exerciser));

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
        amount = bound(amount, 1e19, oath.balanceOf(address(exerciser)));

        /* prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        fixture_prepareOptionToken(amount, address(strategySonneProxy));

        /* Check balances before compounding */
        IERC20 usdc = IERC20(cusdc.underlying());
        uint256 wethBalance = weth.balanceOf(address(strategySonneProxy));
        uint256 wantBalance = usdc.balanceOf(address(strategySonneProxy));
        uint256 optionsBalance = optionsTokenProxy.balanceOf(
            address(strategySonneProxy)
        );
        // temporary logs
        console2.log(
            "[Test] 1. Strategy before flashloan redemption (weth): ",
            wethBalance
        );
        console2.log(
            "[Test] 1. Strategy before flashloan redemption (want): ",
            IERC20(cusdc.underlying()).balanceOf(address(strategySonneProxy))
        );

        vm.startPrank(keeper);
        /* already approved in fixture_prepareOptionToken */
        strategySonneProxy.harvestOTokens(amount, address(exerciser));
        vm.stopPrank();

        // temporary logs
        console2.log(
            "[Test] 2. Strategy after flashloan redemption (weth): ",
            weth.balanceOf(address(strategySonneProxy))
        );
        console2.log(
            "[Test] 2. Strategy after flashloan redemption (want): ",
            IERC20(cusdc.underlying()).balanceOf(address(strategySonneProxy))
        );
        console2.log("[Test] 2. Gain: ", strategySonneProxy.getLastGain());

        /* Check balances after compounding */
        /* Assertions */
        assertEq(
            strategySonneProxy.getLastGain() > 0,
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
            optionsBalance >
                optionsTokenProxy.balanceOf(address(strategySonneProxy)),
            true,
            "Lower balance than before"
        );
        assertEq(
            0 == optionsTokenProxy.balanceOf(address(strategySonneProxy)),
            true,
            "Options token balance is not 0"
        );
    }

    function test_flashloanPositiveScenarioGranary(uint256 amount) public {
        /* Test vectors definition */
        amount = bound(amount, 1e19, oath.balanceOf(address(exerciser)));

        /* prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        fixture_prepareOptionToken(amount, address(strategyGranaryProxy));

        /* Check balances before compounding */
        IERC20 usdc = IERC20(cusdc.underlying());
        uint256 wethBalance = weth.balanceOf(address(strategyGranaryProxy));
        uint256 wantBalance = usdc.balanceOf(address(strategyGranaryProxy));
        uint256 optionsBalance = optionsTokenProxy.balanceOf(
            address(strategyGranaryProxy)
        );
        // temporary logs
        console2.log(
            "[Test] 1. Strategy before flashloan redemption (weth): ",
            wethBalance
        );
        console2.log(
            "[Test] 1. Strategy before flashloan redemption (want): ",
            IERC20(cusdc.underlying()).balanceOf(address(strategyGranaryProxy))
        );

        vm.startPrank(keeper);
        /* already approved in fixture_prepareOptionToken */
        strategyGranaryProxy.harvestOTokens(amount, address(exerciser));
        vm.stopPrank();

        // temporary logs
        console2.log(
            "[Test] 2. Strategy after flashloan redemption (weth): ",
            weth.balanceOf(address(strategyGranaryProxy))
        );
        console2.log(
            "[Test] 2. Strategy after flashloan redemption (want): ",
            IERC20(cusdc.underlying()).balanceOf(address(strategyGranaryProxy))
        );
        console2.log("[Test] 2. Gain: ", strategyGranaryProxy.getLastGain());

        /* Check balances after compounding */
        /* Assertions */
        assertEq(
            strategyGranaryProxy.getLastGain() > 0,
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
            optionsBalance >
                optionsTokenProxy.balanceOf(address(strategyGranaryProxy)),
            true,
            "Lower balance than before"
        );
        assertEq(
            0 == optionsTokenProxy.balanceOf(address(strategyGranaryProxy)),
            true,
            "Options token balance is not 0"
        );
    }

    function test_flashloanNegativeScenario(uint256 amount) public {
        /* Test vectors definition */
        amount = bound(amount, 1e19, oath.balanceOf(address(exerciser)));

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

        /* Check balances before compounding */
        uint256 wethBalance = weth.balanceOf(address(strategySonneProxy));

        // temporary logs
        console2.log(
            "[Test] 1. Strategy before flashloan redemption (weth): ",
            wethBalance
        );
        console2.log(
            "[Test] 1. Strategy before flashloan redemption (want): ",
            IERC20(cusdc.underlying()).balanceOf(address(strategySonneProxy))
        );

        /* Already approved in fixture_prepareOptionToken */
        /* Notice: additional protection is in exerciser: Exercise__SlippageTooHigh */
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__FlashloanNotProfitable()"))
        );

        vm.startPrank(keeper);
        strategySonneProxy.harvestOTokens(amount, address(exerciser));
        vm.stopPrank();
    }

    function test_callExecuteOperationWithoutFlashloanTrigger(
        uint256 amount,
        address executor
    ) public {
        /* Test vectors definition */
        amount = bound(amount, 1e19, oath.balanceOf(address(exerciser)));

        /* Argument creation */
        address[] memory assets = new address[](1);
        assets[0] = address(paymentToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = DiscountExercise(exerciser).getPaymentAmount(amount);
        uint256[] memory premiums = new uint256[](1);
        bytes memory params;

        /* Assertion */
        vm.startPrank(executor);
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
        amount = bound(amount, 1e19, oath.balanceOf(address(exerciser)));

        vm.assume(fuzzedExerciser != address(exerciser));

        /* Prepare option tokens - distribute them to the specified strategy
        and approve for spending */
        fixture_prepareOptionToken(amount, address(strategySonneProxy));

        vm.startPrank(keeper);
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__NotExerciseContract()"))
        );
        strategySonneProxy.harvestOTokens(amount, fuzzedExerciser);
        vm.stopPrank();
    }
}

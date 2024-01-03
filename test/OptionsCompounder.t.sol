// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {ReaperStrategySonne} from "../src/ReaperStrategySonne.sol";
import {BalancerOracle} from "optionsToken/src/oracles/BalancerOracle.sol";
import {BEETX_VAULT_OP} from "../src/OptionsCompounder.sol";
import {CErc20I} from "../src/interfaces/CErc20I.sol";
import {OptionsToken} from "optionsToken/src/OptionsToken.sol";
import {DiscountExerciseParams, DiscountExercise} from "optionsToken/src/exercise/DiscountExercise.sol";
import {MockBalancerTwapOracle} from "optionsToken/test/mocks/MockBalancerTwapOracle.sol";
import {Helper} from "./mocks/HelperFunctions.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";

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
    address constant OATH = 0x39FdE572a18448F8139b7788099F0a0740f51205;
    address constant CUSDC = 0xEC8FEa79026FfEd168cCf5C627c7f486D77b765F;
    bytes32 constant OATHV1_ETH_BPT =
        0xd20f6f1d8a675cdca155cb07b5dc9042c467153f0002000000000000000000bc; /* OATHv1/ETH BPT */
    bytes32 constant BTC_WETH_USDC_BPT =
        0x5028497af0c9a54ea8c6d42a054c0341b9fc6168000100000000000000000004;
    uint256 constant AMOUNT = 1e18;

    /* Variables */
    ERC20 weth = ERC20(WETH);
    IERC20 oath = IERC20(OATH);
    CErc20I cusdc = CErc20I(CUSDC);
    IERC20 paymentToken;
    IERC20 underlyingToken;
    string OPTIMISM_MAINNET_URL = vm.envString("RPC_URL_MAINNET");

    address beetxVault = BEETX_VAULT_OP;
    address owner;
    address tokenAdmin;
    address treasury;
    address strategist = address(4);
    address vault;
    address management1;
    address management2;
    address management3;
    address keeper;

    /* Contract variables */
    OptionsToken optionsToken;
    ERC1967Proxy optionsProxy;
    OptionsToken optionsTokenProxy;
    DiscountExercise exerciser;
    BalancerOracle oracle;
    MockBalancerTwapOracle balancerTwapOracle;
    ReaperStrategySonne strategySonne;
    ERC1967Proxy strategyProxy;
    ReaperStrategySonne strategySonneProxy;
    ERC1967Proxy reaperProxy;
    ReaperSwapper reaperSwapperProxy;
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
        treasury = makeAddr("treasury");
        vault = makeAddr("vault");
        management1 = makeAddr("management1");
        management2 = makeAddr("management2");
        management3 = makeAddr("management3");
        keeper = makeAddr("keeper");
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
        reaperSwapperProxy = new ReaperSwapper(
            strategists,
            address(this),
            address(this)
        );
        // reaperSwapper = new ReaperSwapper();
        // reaperProxy = new ERC1967Proxy(address(reaperSwapper), "");
        // reaperSwapperProxy = ReaperSwapper(address(reaperSwapperProxy));
        // reaperSwapperProxy.initialize(
        // strategists,
        // address(this),
        // address(this)
        // );
        reaperSwapperProxy.updateBalSwapPoolID(
            address(weth),
            address(oath),
            beetxVault,
            OATHV1_ETH_BPT
        );
        reaperSwapperProxy.updateBalSwapPoolID(
            address(oath),
            address(weth),
            beetxVault,
            OATHV1_ETH_BPT
        );
        reaperSwapperProxy.updateBalSwapPoolID(
            address(weth),
            cusdc.underlying(),
            beetxVault,
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
        optionsProxy = new ERC1967Proxy(address(optionsToken), "");
        optionsTokenProxy = OptionsToken(address(optionsProxy));
        optionsTokenProxy.initialize(
            "TIT Call Option Token",
            "oTIT",
            tokenAdmin,
            tokenAdmin
        );

        exerciser = new DiscountExercise(
            optionsTokenProxy,
            owner,
            paymentToken,
            ERC20(address(underlyingToken)),
            oracle,
            PRICE_MULTIPLIER,
            treasury
        );
        // add exerciser to the list of options
        optionsTokenProxy.setExerciseContract(address(exerciser), true);

        /* Option compounder deployment */
        console2.log("Deployment contract");
        strategySonne = new ReaperStrategySonne();
        console2.log("Deployment strategy proxy");
        strategyProxy = new ERC1967Proxy(address(strategySonne), "");
        console2.log("Initialization proxied sonne strategy");
        strategySonneProxy = ReaperStrategySonne(address(strategyProxy));
        strategySonneProxy.initialize(
            vault,
            address(reaperSwapperProxy),
            strategists,
            multisigRoles,
            keepers,
            CUSDC,
            address(optionsTokenProxy),
            POOL_ADDRESSES_PROVIDER,
            targetLTV
        );
        vm.stopPrank();

        /* Prepare EOA and contracts for tests */
        helper.getWethFromEth{value: AMOUNT * 2}(WETH);

        MinAmountOutData memory minAmountOutData = MinAmountOutData(
            MinAmountOutKind.Absolute,
            0
        );
        weth.approve(address(reaperSwapperProxy), AMOUNT);
        reaperSwapperProxy.swapBal(
            address(weth),
            address(underlyingToken),
            AMOUNT,
            minAmountOutData,
            beetxVault
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

    function test_flashloanPositiveScenario(uint256 amount) public {
        /* Test vectors definition */
        amount = bound(amount, 1e19, oath.balanceOf(address(exerciser)));

        /* prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        fixture_prepareOptionToken(amount, address(strategySonneProxy));

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

        vm.startPrank(keeper);
        /* already approved in fixture_prepareOptionToken */
        strategySonneProxy.harvestOTokens(amount, address(exerciser));
        vm.stopPrank();

        // temporary logs
        console2.log(
            "[Test] 2. Strategy before flashloan redemption (weth): ",
            weth.balanceOf(address(strategySonneProxy))
        );
        console2.log(
            "[Test] 2. Strategy before flashloan redemption (want): ",
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
            "Lower balance than before"
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
}

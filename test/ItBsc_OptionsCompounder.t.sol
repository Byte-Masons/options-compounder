// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.13;

import "./Common.sol";

import {BalancerOracle} from "optionsToken/src/oracles/BalancerOracle.sol";
import {CErc20I} from "./strategies/interfaces/CErc20I.sol";
import {DiscountExerciseParams, DiscountExercise} from "optionsToken/src/exercise/DiscountExercise.sol";
import {MockBalancerTwapOracle} from "optionsToken/test/mocks/MockBalancerTwapOracle.sol";
import {Helper} from "./mocks/HelperFunctions.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";
import {IAToken} from "./strategies/interfaces/IAToken.sol";
import {IRToken} from "./strategies/interfaces/IRToken.sol";
import {MockedLendingPool, MockedStrategy} from "./mocks/MockedStrategy.sol";
import {ThenaOracle, IThenaPair} from "optionsToken/src/oracles/ThenaOracle.sol";
import {IOracle} from "optionsToken/src/interfaces/IOracle.sol";
import {RouterV2} from "./strategies/interfaces/RouterV2.sol";

contract OptionsTokenTest is Common {
    enum TestChain {
        OPTIMISM,
        BSC
    }

    TestChain testChain = TestChain.BSC;

    using FixedPointMathLib for uint256;

    /* Variable assignment (depends on chain) */
    string MAINNET_URL = vm.envString("BSC_RPC_URL_MAINNET");
    IRToken rusdc = IRToken(BSC_RUSDC);

    ExchangeType exchangeType = ExchangeType.VeloSolid;

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
    ThenaOracle underlyingPaymentOracle;
    ThenaOracle paymentWantOracle;
    MockBalancerTwapOracle balancerTwapOracle;
    MockedLendingPool lendingPool;
    MockedStrategy strategy;
    Helper helper;
    uint256 initTwap = 0;

    function setUp() public {
        /* Common assignments */
        nativeToken = IERC20(BSC_WBNB);
        paymentToken = nativeToken;
        underlyingToken = IERC20(BSC_THENA);
        wantToken = IERC20(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d); // IERC20(rusdc.UNDERLYING_ASSET_ADDRESS());

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
        feeBPS[0] = 0;
        feeBPS[1] = 0;
        vm.deal(address(this), AMOUNT * 3);
        vm.deal(owner, AMOUNT * 3);

        /* Setup network */
        uint256 bscFork = vm.createFork(MAINNET_URL); //, FORK_BLOCK);
        vm.selectFork(bscFork);

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
        RouterV2 router = RouterV2(payable(BSC_VELO_ROUTER));

        SwapProps memory swapProps = SwapProps(
            BSC_VELO_ROUTER,
            ExchangeType.VeloSolid
        );

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
        //balancerTwapOracle = new MockBalancerTwapOracle(tokens);
        address pair = router.pairFor(
            address(underlyingToken),
            address(paymentToken),
            false
        );
        console2.log("1. Pair: ", pair);
        underlyingPaymentOracle = new ThenaOracle(
            IThenaPair(pair),
            address(underlyingToken),
            owner,
            ORACLE_SECS,
            ORACLE_MIN_PRICE
        );
        console2.log("1. Price: ", underlyingPaymentOracle.getPrice());
        console2.log("Want address: ", address(wantToken));
        pair = router.pairFor(address(paymentToken), address(wantToken), false);
        console2.log("2. Pair: ", pair);
        paymentWantOracle = new ThenaOracle(
            IThenaPair(pair),
            address(paymentToken),
            owner,
            ORACLE_SECS,
            ORACLE_MIN_PRICE
        );
        console2.log("2. Price: ", paymentWantOracle.getPrice());
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

        /* Strategy deployment */
        lendingPool = new MockedLendingPool();
        strategy = new MockedStrategy();
        strategy.__MockedStrategy_init(
            address(reaperSwapper),
            address(wantToken),
            address(optionsTokenProxy),
            address(lendingPool),
            swapProps,
            oracles
        );
        lendingPool.setStrategy(address(strategy));
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
        paymentToken.transfer(
            address(lendingPool),
            paymentToken.balanceOf(address(this))
        );

        /* Set up contracts */
        // balancerTwapOracle.setTwapValue(initTwap);
        paymentToken.approve(address(exerciser), type(uint256).max);
    }

    function test_flashloanPositiveScenario(uint256 amount) public {
        /* Test vectors definition */
        amount = bound(
            amount,
            MIN_OATH_FOR_FUZZING,
            underlyingToken.balanceOf(address(exerciser))
        );

        /* Prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        console2.log("Strategy address: ", address(strategy));
        fixture_prepareOptionToken(
            amount,
            address(strategy),
            optionsTokenProxy,
            tokenAdmin
        );

        /* Check balances before compounding */
        uint256 paymentTokenBalance = paymentToken.balanceOf(address(strategy));
        uint256 wantBalance = wantToken.balanceOf(address(strategy));

        vm.startPrank(keeper);
        /* already approved in fixture_prepareOptionToken */
        strategy.harvestOTokens(amount, address(exerciser), NON_ZERO_PROFIT);
        vm.stopPrank();

        /* Assertions */
        assertEq(
            wantToken.balanceOf(address(strategy)) > wantBalance,
            true,
            "Gain not greater than 0"
        );
        assertEq(
            paymentTokenBalance <= paymentToken.balanceOf(address(strategy)),
            true,
            "Lower paymentToken balance than before"
        );
        assertEq(
            wantBalance <= wantToken.balanceOf(address(strategy)),
            true,
            "Lower want balance than before"
        );
        assertEq(
            0 == optionsTokenProxy.balanceOf(address(strategy)),
            true,
            "Options token balance is not 0"
        );
    }
}

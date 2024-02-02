// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.13;

import "./Common.sol";

import {BalancerOracle} from "optionsToken/src/oracles/BalancerOracle.sol";
import {CErc20I} from "./strategies/interfaces/CErc20I.sol";
import {MockBalancerTwapOracle} from "optionsToken/test/mocks/MockBalancerTwapOracle.sol";
import {Helper} from "./mocks/HelperFunctions.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IAToken} from "./strategies/interfaces/IAToken.sol";
import {MockedLendingPool, MockedStrategy} from "./mocks/MockedStrategy.sol";
import {IThenaRamRouter} from "vault-v2/interfaces/IThenaRamRouter.sol";

contract OptionsTokenTest is Common {
    using FixedPointMathLib for uint256;

    /* Variable assignment (depends on chain) */
    uint256 constant FORK_BLOCK = 35406073;
    string MAINNET_URL = vm.envString("BSC_RPC_URL_MAINNET");

    /* Contract variables */

    ThenaOracle paymentWantOracle;
    MockBalancerTwapOracle balancerTwapOracle;
    MockedLendingPool lendingPool;
    MockedStrategy strategy;
    Helper helper;
    uint256 initTwap;

    function setUp() public {
        /* Common assignments */
        ExchangeType[] memory exchangeTypes = new ExchangeType[](2);
        exchangeTypes[0] = ExchangeType.ThenaRam;
        exchangeTypes[1] = ExchangeType.ThenaRam;
        nativeToken = IERC20(BSC_WBNB);
        paymentToken = nativeToken;
        underlyingToken = IERC20(BSC_THENA);
        wantToken = IERC20(BSC_BUSD);
        thenaRamRouter = IThenaRamRouter(BSC_THENA_ROUTER);
        routerV2 = ISwapRouter(BSC_UNIV3_ROUTERV2);
        univ3Factory = IUniswapV3Factory(BSC_UNIV3_FACTORY);

        /* Setup accounts */
        fixture_setupAccountsAndFees(3000, 7000);
        vm.deal(address(this), AMOUNT * 3);
        vm.deal(owner, AMOUNT * 3);

        /* Setup network */
        uint256 bscFork = vm.createFork(MAINNET_URL); //FORK_BLOCK);
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

        SwapProps[] memory swapProps = fixture_getSwapProps(exchangeTypes);

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
        // address[] memory tokens = new address[](2);
        // tokens[0] = address(underlyingToken);
        // tokens[1] = address(paymentToken);
        //balancerTwapOracle = new MockBalancerTwapOracle(tokens);
        IOracle[] memory oracles = fixture_getOracles(exchangeTypes);

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
            oracles[0],
            PRICE_MULTIPLIER,
            treasuries,
            feeBPS
        );
        /* Add exerciser to the list of options */
        optionsTokenProxy.setExerciseContract(address(exerciser), true);

        /* Strategy deployment */
        uint256[] memory slippages = new uint256[](2);
        slippages[0] = 200; // 2%
        slippages[1] = 400; // 4%
        lendingPool = new MockedLendingPool();
        strategy = new MockedStrategy();
        strategy.__MockedStrategy_init(
            address(reaperSwapper),
            address(wantToken),
            address(optionsTokenProxy),
            address(lendingPool),
            slippages,
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
        reaperSwapper.swapThenaRam(
            address(paymentToken),
            address(underlyingToken),
            AMOUNT,
            minAmountOutData,
            address(thenaRamRouter),
            type(uint256).max,
            false
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

    function test_bscFlashloanPositiveScenario(uint256 amount) public {
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

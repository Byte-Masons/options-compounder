// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.13;

import "./Common.sol";

import {BalancerOracle} from "optionsToken/src/oracles/BalancerOracle.sol";
import {CErc20I} from "./strategies/interfaces/CErc20I.sol";
import {MockBalancerTwapOracle} from "optionsToken/test/mocks/MockBalancerTwapOracle.sol";
import {Helper} from "./mocks/HelperFunctions.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IAToken} from "./strategies/interfaces/IAToken.sol";
import {IThenaRamRouter} from "vault-v2/interfaces/IThenaRamRouter.sol";
import {ReaperStrategyGranary, Externals} from "./strategies/ReaperStrategyGranary.sol";
import {OptionsCompounder} from "../src/OptionsCompounder.sol";
import {MockedLendingPool} from "../test/mocks/MockedStrategy.sol";

contract OptionsTokenTest is Common {
    using FixedPointMathLib for uint256;

    /* Variable assignment (depends on chain) */
    uint256 constant FORK_BLOCK = 36349190;
    string MAINNET_URL = vm.envString("BSC_RPC_URL_MAINNET");

    /* Contract variables */
    OptionsCompounder optionsCompounder;
    ReaperStrategyGranary strategy;
    Helper helper;
    IOracle oracle;

    // string public vaultName = "?_? Vault";
    // string public vaultSymbol = "rf-?_?";
    // uint256 public vaultTvlCap = type(uint256).max;
    // address public treasuryAddress = 0xC17DfA7Eb4300871D5f022c107E07F98c750472e;

    // address public optionsTokenAddress =
    //     0x45c19a3068642B98F5AEf1dEdE023443cd1FbFAd;
    // address public discountExerciseAddress =
    //     0x3Fbf4f9cf73162e4e156972540f53Dabe65c2862;
    // address public bscTokenAdmin = 0x6eB1fF8E939aFBF3086329B2b32725b72095512C;

    function setUp() public {
        /* Common assignments */
        ExchangeType exchangeType = ExchangeType.ThenaRam;
        nativeToken = IERC20(BSC_WBNB);
        paymentToken = nativeToken;
        underlyingToken = IERC20(BSC_HBR);
        wantToken = IERC20(BSC_USDT);
        thenaRamRouter = IThenaRamRouter(BSC_THENA_ROUTER);
        swapRouter = ISwapRouter(BSC_PANCAKE_ROUTER);
        univ3Factory = IUniswapV3Factory(BSC_PANCAKE_FACTORY);
        addressProvider = BSC_ADDRESS_PROVIDER;
        // gWantAddress = BSC_GUSDT;
        // dataProvider = BSC_DATA_PROVIDER;
        // rewarder = BSC_REWARDER;

        /* Setup network */
        uint256 bscFork = vm.createFork(MAINNET_URL, FORK_BLOCK);
        vm.selectFork(bscFork);

        /* Setup accounts */
        fixture_setupAccountsAndFees(3000, 7000);
        vm.deal(address(this), AMOUNT * 3);
        vm.deal(owner, AMOUNT * 3);

        /* Setup roles */
        address[] memory strategists = new address[](1);
        // address[] memory multisigRoles = new address[](3);
        // address[] memory keepers = new address[](1);
        strategists[0] = strategist;
        // multisigRoles[0] = management1;
        // multisigRoles[1] = management2;
        // multisigRoles[2] = management3;
        // keepers[0] = keeper;

        /* Variables */
        SwapProps memory swapProps = fixture_getSwapProps(exchangeType, 200);

        /**** Contract deployments and configurations ****/
        helper = new Helper();

        /* Reaper deployment and configuration */
        reaperSwapper = new ReaperSwapper();
        tmpProxy = new ERC1967Proxy(address(reaperSwapper), "");
        reaperSwapper = ReaperSwapper(address(tmpProxy));
        reaperSwapper.initialize(strategists, address(this), address(this));

        /* Configure swapper */
        fixture_updateSwapperPaths(exchangeType);

        /* Oracle mocks deployment */
        oracle = fixture_getMockedOracle(exchangeType);

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

        /* Strategy deployment */
        strategy = new ReaperStrategyGranary();
        tmpProxy = new ERC1967Proxy(address(strategy), "");
        strategy = ReaperStrategyGranary(address(tmpProxy));
        optionsCompounder = new OptionsCompounder();
        tmpProxy = new ERC1967Proxy(address(optionsCompounder), "");
        optionsCompounder = OptionsCompounder(address(tmpProxy));
        MockedLendingPool addressProviderAndLendingPoolMock = new MockedLendingPool(
                address(optionsCompounder)
            );
        optionsCompounder.initialize(
            address(optionsTokenProxy),
            address(addressProviderAndLendingPoolMock),
            address(strategy),
            address(reaperSwapper),
            swapProps,
            oracle
        );

        // ReaperVaultV2 vault = new ReaperVaultV2(
        //     address(wantToken),
        //     vaultName,
        //     vaultSymbol,
        //     vaultTvlCap,
        //     treasuryAddress,
        //     strategists,
        //     multisigRoles
        // );
        // Externals memory externals = Externals(
        //     address(vault),
        //     address(reaperSwapper),
        //     addressProvider,
        //     dataProvider,
        //     rewarder,
        //     address(optionsCompounder),
        //     address(exerciser)
        // );
        // strategy.initialize(
        //     externals,
        //     strategists,
        //     multisigRoles,
        //     keepers,
        //     IAToken(gWantAddress),
        //     targetLtv,
        //     maxLtv
        // );
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
        paymentToken.transfer(
            address(addressProviderAndLendingPoolMock),
            paymentToken.balanceOf(address(this))
        );
        underlyingToken.transfer(address(exerciser), underlyingBalance);

        /* Set up contracts */
        paymentToken.approve(address(exerciser), type(uint256).max);
    }

    function test_bscFlashloanPositiveScenario(uint256 amount) public {
        /* Test vectors definition */
        amount = bound(
            amount,
            MIN_OATH_FOR_FUZZING,
            underlyingToken.balanceOf(address(exerciser))
        );
        uint256 minAmount = 5;

        /* Prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        fixture_prepareOptionToken(
            amount,
            address(optionsCompounder),
            optionsTokenProxy,
            tokenAdmin
        );

        /* Check balances before compounding */
        uint256 paymentTokenBalance = paymentToken.balanceOf(
            address(optionsCompounder)
        );

        vm.startPrank(address(strategy));
        /* already approved in fixture_prepareOptionToken */
        uint256 _balance = optionsTokenProxy.balanceOf(
            address(optionsCompounder)
        );
        optionsCompounder.harvestOTokens(
            _balance,
            address(exerciser),
            minAmount
        );
        vm.stopPrank();

        /* Assertions */
        assertGt(
            paymentToken.balanceOf(address(strategy)),
            paymentTokenBalance + minAmount,
            "Gain not greater than 0"
        );
        assertEq(
            optionsTokenProxy.balanceOf(address(optionsCompounder)),
            0,
            "Options token balance in compounder is 0"
        );
        assertEq(
            paymentToken.balanceOf(address(optionsCompounder)),
            0,
            "Payment token balance in compounder is 0"
        );
    }
}

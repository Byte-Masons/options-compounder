// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

import {OptionsCompounder} from "../src/OptionsCompounderAave2.sol";
import {OptionsToken, OptionStruct} from "../src/OptionsToken.sol";
import {ReaperSwapper, MinAmountOutData, MinAmountOutKind} from "../src/helpers/ReaperSwapper.sol";
import {DiscountExerciseParams, DiscountExerciseReturnData, DiscountExercise} from "../src/exercise/DiscountExercise.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {BalancerOracle} from "../src/oracles/BalancerOracle.sol";
import {MockBalancerTwapOracle} from "./mocks/MockBalancerTwapOracle.sol";
import {Helper} from "../src/helpers/HelperFunctions.sol";

contract OptionsTokenTest is Test {
    using FixedPointMathLib for uint256;
    /* Constants */
    uint16 constant ORACLE_MULTIPLIER = 5000; // 0.5
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
    address constant BEETX_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    bytes32 constant OATH_V1_ETH_BPT =
        0xd20f6f1d8a675cdca155cb07b5dc9042c467153f0002000000000000000000bc; /* OATHv1/ETH BPT */
    uint256 constant AMOUNT = 1e18;

    /* Variables */
    IERC20 weth = IERC20(WETH);
    IERC20 oath = IERC20(OATH);
    IERC20 paymentToken;
    IERC20 underlyingToken;
    bytes32 poolId = OATH_V1_ETH_BPT;
    string OPTIMISM_MAINNET_URL = vm.envString("RPC_URL_MAINNET");

    address vaultAddress = BEETX_VAULT;
    address owner;
    address tokenAdmin;
    address treasury;
    address strategist = address(4);
    address strategy;

    /* Contract variables */
    OptionsToken optionsToken;
    DiscountExercise exerciser;
    BalancerOracle oracle;
    MockBalancerTwapOracle balancerTwapOracle;
    OptionsCompounder optionsCompounder;
    ReaperSwapper reaperSwapper;
    Helper helper;

    function fixture_prepareOptionToken(
        uint256 _amount,
        address _strategy
    ) public {
        if (false == optionsCompounder.isStrategyAdded(_strategy)) {
            vm.prank(owner);
            optionsCompounder.addStrategy(_strategy);
        }
        /* mint options tokens and transfer them to the strategy (rewards simulation) */
        vm.startPrank(tokenAdmin);
        optionsToken.mint(tokenAdmin, _amount);
        optionsToken.transfer(strategy, _amount);
        vm.stopPrank();

        vm.prank(strategy);
        optionsToken.approve(address(optionsCompounder), _amount);
    }

    function setUp() public {
        /* set up accounts */
        owner = makeAddr("owner");
        tokenAdmin = makeAddr("tokenAdmin");
        treasury = makeAddr("treasury");
        strategy = makeAddr("strategy");
        vm.deal(address(this), AMOUNT * 3);
        vm.deal(owner, AMOUNT * 3);

        /* setup network */
        uint256 optimismFork = vm.createFork(OPTIMISM_MAINNET_URL);
        vm.selectFork(optimismFork);

        /* Variables */
        paymentToken = IERC20(WETH);
        underlyingToken = IERC20(OATH);
        address[] memory strategists = new address[](1);
        //address[] memory multisigRoles = new address[](3);
        strategists[0] = strategist;
        // multisigRoles[0] = management1;
        // multisigRoles[1] = management2;
        // multisigRoles[2] = management3;
        address[] memory strategies = new address[](1);
        strategies[0] = strategy;

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
            vaultAddress,
            poolId
        );
        reaperSwapper.updateBalSwapPoolID(
            address(oath),
            address(weth),
            vaultAddress,
            poolId
        );

        /* Oracle mocks deployment */
        balancerTwapOracle = new MockBalancerTwapOracle();
        oracle = new BalancerOracle(
            balancerTwapOracle,
            owner,
            ORACLE_MULTIPLIER,
            ORACLE_SECS,
            ORACLE_AGO,
            ORACLE_MIN_PRICE
        );

        /* Option token deployment */
        optionsToken = new OptionsToken(
            "TIT Call Option Token",
            "oTIT",
            owner,
            tokenAdmin
        );
        exerciser = new DiscountExercise(
            optionsToken,
            owner,
            paymentToken,
            ERC20(address(underlyingToken)),
            oracle,
            treasury
        );

        /* Option compounder deployment */
        vm.startPrank(owner);
        optionsCompounder = new OptionsCompounder(
            address(optionsToken),
            POOL_ADDRESSES_PROVIDER,
            address(reaperSwapper),
            strategies
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
            vaultAddress
        );
        uint256 underlyingBalance = underlyingToken.balanceOf(address(this));
        //console2.log("1. Balance after swapping: ", oathBalance);
        //uint256 wethBalance = weth.balanceOf(address(this));
        //console2.log("1. Balance after swapping: ", wethBalance);
        uint256 initTwap = AMOUNT.mulDivUp(1e18, underlyingBalance); // Question: temporary inaccurate solution. How to get the newest price easly ?
        console2.log(">>>> Init TWAP: ", initTwap);
        oath.transfer(address(exerciser), underlyingBalance);

        // add exerciser to the list of options
        vm.startPrank(owner);
        optionsToken.setOption(address(exerciser), true);
        vm.stopPrank();

        // set up contracts
        balancerTwapOracle.setTwapValue(initTwap);
        paymentToken.approve(address(exerciser), type(uint256).max);

        console2.log("Options Compunder: ", address(optionsCompounder));
        console2.log("Options Token: ", address(optionsToken));
        console2.log("Address of this contract: ", address(this));
        console2.log("Address of owner: ", owner);
        console2.log("Address of token admin: ", tokenAdmin);
    }

    function test_onlyOwnerFunctionsChecks(
        address hacker,
        address hackersStrategy,
        uint256 amount
    ) public {
        /* Test vectors definition */
        amount = bound(amount, 100, oath.balanceOf(address(exerciser)));
        vm.assume(hacker != tokenAdmin);
        vm.assume(hackersStrategy != strategy);

        /* Hacker tries to add and remove strategy */
        vm.startPrank(hacker);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("OwnableUnauthorizedAccount(address)")),
                hacker
            )
        );
        optionsCompounder.addStrategy(hackersStrategy);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("OwnableUnauthorizedAccount(address)")),
                hacker
            )
        );
        optionsCompounder.removeStrategy(hackersStrategy);

        /* Hacker tries to manipulate contract configuration */
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("OwnableUnauthorizedAccount(address)")),
                hacker
            )
        );
        optionsCompounder.setSwapper(hackersStrategy);
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("OwnableUnauthorizedAccount(address)")),
                hacker
            )
        );
        optionsCompounder.setOptionToken(hackersStrategy);
        vm.stopPrank();

        /* Not added hacker's strategy tries to use harvest and withdraw functions */
        vm.startPrank(hackersStrategy);
        vm.expectRevert(bytes4(keccak256("OptionsCompounder__NotAStrategy()")));
        optionsCompounder.harvestOTokens(amount, address(exerciser));
        vm.expectRevert(bytes4(keccak256("OptionsCompounder__NotAStrategy()")));
        optionsCompounder.withdrawProfit(address(exerciser));
    }

    function test_addingRemovingStrategies(
        address strategy1,
        address strategy2
    ) public {
        /* Test vectors definition */
        vm.assume(strategy1 != strategy);
        vm.assume(strategy2 != strategy && strategy2 != strategy1);
        uint256 initialNrOfStrategies = optionsCompounder
            .getNumberOfStrategiesAvailable();

        /* Try withdraw with not added strategy */
        vm.startPrank(strategy1);
        vm.expectRevert(bytes4(keccak256("OptionsCompounder__NotAStrategy()")));
        optionsCompounder.withdrawProfit(address(exerciser));
        vm.stopPrank();

        /* Try withdraw with added strategy - function should proceed but revert on funds */
        assertEq(optionsCompounder.isStrategyAdded(strategy1), false);
        vm.prank(owner);
        optionsCompounder.addStrategy(strategy1);
        assertEq(optionsCompounder.isStrategyAdded(strategy1), true);
        assertEq(
            optionsCompounder.getNumberOfStrategiesAvailable(),
            initialNrOfStrategies + 1
        );

        vm.startPrank(strategy1);
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__NotEnoughFunds()"))
        );
        optionsCompounder.withdrawProfit(address(exerciser));
        vm.stopPrank();

        /* Try to remove not existing strategy and add existing strategy */
        vm.startPrank(owner);
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__StrategyNotFound()"))
        );
        optionsCompounder.removeStrategy(strategy2);
        optionsCompounder.addStrategy(strategy2);
        assertEq(
            optionsCompounder.getNumberOfStrategiesAvailable(),
            initialNrOfStrategies + 2
        );
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__StrategyAlreadyExists()"))
        );
        optionsCompounder.addStrategy(strategy1);

        /* Remove strategy already added and check if it is removed properly 
        (not a strategy error for withdrawing) */
        optionsCompounder.removeStrategy(strategy1);
        assertEq(
            optionsCompounder.getNumberOfStrategiesAvailable(),
            initialNrOfStrategies + 1
        );
        vm.stopPrank();
        vm.startPrank(strategy1);
        vm.expectRevert(bytes4(keccak256("OptionsCompounder__NotAStrategy()")));
        optionsCompounder.withdrawProfit(address(exerciser));
        vm.stopPrank();

        /* Check whether after removal strategy1 and adding strategy2 still 
        withdrawProfit function is called without NotAStrategy reversion 
        (notEnaughFunds reversion expected) */
        vm.startPrank(strategy2);
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__NotEnoughFunds()"))
        );
        optionsCompounder.withdrawProfit(address(exerciser));
        vm.stopPrank();
    }

    function test_flashloanPositiveScenario(uint256 amount) public {
        /* Test vectors definition */
        amount = bound(amount, 1e15, oath.balanceOf(address(exerciser)));
        /* prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        fixture_prepareOptionToken(amount, strategy);

        /* Check balances before compounding */
        uint256 wethBalance = weth.balanceOf(strategy);
        console2.log(
            "This contract before flashloan redemption: ",
            weth.balanceOf(address(this))
        );
        console2.log("Strategy before flashloan redemption: ", wethBalance);

        vm.startPrank(strategy);
        /* already approved in fixture_prepareOptionToken */
        optionsCompounder.harvestOTokens(amount, address(exerciser));
        optionsCompounder.withdrawProfit(address(exerciser));
        vm.stopPrank();

        /* Check balances after compounding */
        // Question: Do we need accurate calculations about profits?
        console2.log(
            "This contract after flashloan redemption: ",
            weth.balanceOf(address(this))
        );
        console2.log(
            "Strategy after flashloan redemption: ",
            weth.balanceOf(strategy)
        );

        console2.log("Gain: ", optionsCompounder.getLastGain());
        assert(optionsCompounder.getLastGain() > 0);
        assert(wethBalance < weth.balanceOf(strategy));
    }

    function test_flashloanNegativeScenario(uint256 amount) public {
        /* Test vectors definition */
        amount = bound(amount, 1e15, oath.balanceOf(address(exerciser)));

        /* Prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        fixture_prepareOptionToken(amount, strategy);

        /* Decrease option discount in order to make redemption not profitable */
        /* Question: Multiplier must be higher than denom because of oracle inaccuracy (initTwap) */
        vm.prank(owner);
        oracle.setParams(10100, ORACLE_SECS, ORACLE_AGO, ORACLE_MIN_PRICE);

        /* Check balances before compounding */
        uint256 wethBalance = weth.balanceOf(strategy);
        console2.log(
            "This contract before flashloan redemption: ",
            weth.balanceOf(address(this))
        );
        console2.log("Strategy before flashloan redemption: ", wethBalance);
        console2.log(
            "OptionsCompounder before flashloan redemption: ",
            weth.balanceOf(address(optionsCompounder))
        );

        vm.startPrank(strategy);

        /* Already approved in fixture_prepareOptionToken */
        vm.expectRevert();
        optionsCompounder.harvestOTokens(amount, address(exerciser));
        // bytes4(
        //     keccak256("OptionsCompounder__NotEnoughFunsToPayFlashloan()")
        // ) - cannot expect specific values in error
        console2.log(
            "OptionsCompounder between flashloan redemption: ",
            weth.balanceOf(address(optionsCompounder))
        );
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__NotEnoughFunds()"))
        );
        optionsCompounder.withdrawProfit(address(exerciser));
        vm.stopPrank();

        /* Check balances after compounding */
        // Question: Do we need accurate calculations about profits?
        console2.log(
            "This contract after flashloan redemption: ",
            weth.balanceOf(address(this))
        );
        console2.log(
            "Strategy after flashloan redemption: ",
            weth.balanceOf(strategy)
        );
        console2.log(
            "OptionsCompounder after flashloan redemption: ",
            weth.balanceOf(address(optionsCompounder))
        );

        console2.log("Gain: ", optionsCompounder.getLastGain());
    }
}

// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {ReaperStrategySonne} from "./strategies/ReaperStrategySonne.sol";
// import {BalancerOracle} from "optionsToken/src/oracles/BalancerOracle.sol";
// import {BEETX_VAULT_OP} from "../src/OptionsCompounder.sol";
// import {CErc20I} from "../src/interfaces/CErc20I.sol";
// import {OptionsToken} from "optionsToken/src/OptionsToken.sol";
// import {DiscountExerciseParams, DiscountExercise} from "optionsToken/src/exercise/DiscountExercise.sol";
// import {MockBalancerTwapOracle} from "optionsToken/test/mocks/MockBalancerTwapOracle.sol";
// import {Helper} from "./mocks/HelperFunctions.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
// import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {UtMock} from "./mocks/UtMock.sol";

// import {ReaperSwapper, MinAmountOutData, MinAmountOutKind} from "vault-v2/ReaperSwapper.sol";
import {ReaperSwapper, MinAmountOutData, MinAmountOutKind} from "./mocks/ReaperSwapper.sol";

contract OptionsTokenTest is Test {
    using FixedPointMathLib for uint256;
    /* Constants */
    // uint16 constant PRICE_MULTIPLIER = 5000; // 0.5
    // uint56 constant ORACLE_SECS = 30 minutes;
    // uint56 constant ORACLE_AGO = 2 minutes;
    // uint128 constant ORACLE_MIN_PRICE = 1e10;
    // uint56 constant ORACLE_LARGEST_SAFETY_WINDOW = 24 hours;
    // //uint256 constant ORACLE_INIT_TWAP_VALUE = 1e19;
    // uint256 constant ORACLE_MIN_PRICE_DENOM = 10000;
    // uint256 constant MAX_SUPPLY = 1e27; // the max supply of the options token & the underlying token
    // address constant POOL_ADDRESSES_PROVIDER =
    //     0xdDE5dC81e40799750B92079723Da2acAF9e1C6D6; // Granary (aavev2)
    // // AAVEv3 - 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    // address constant WETH = 0x4200000000000000000000000000000000000006;
    // address constant OATH = 0x39FdE572a18448F8139b7788099F0a0740f51205;
    // address constant CUSDC = 0xEC8FEa79026FfEd168cCf5C627c7f486D77b765F;
    // bytes32 constant OATHV1_ETH_BPT =
    //     0xd20f6f1d8a675cdca155cb07b5dc9042c467153f0002000000000000000000bc; /* OATHv1/ETH BPT */
    // bytes32 constant BTC_WETH_USDC_BPT =
    //     0x5028497af0c9a54ea8c6d42a054c0341b9fc6168000100000000000000000004;
    uint256 constant AMOUNT = 2e18; // 2 ETH
    uint256 constant PERCENTAGE = 10_000;

    /* Variables */
    // ERC20 weth = ERC20(WETH);
    // IERC20 oath = IERC20(OATH);
    // CErc20I cusdc = CErc20I(CUSDC);
    IERC20 paymentToken;
    IERC20 underlyingToken;

    // string OPTIMISM_MAINNET_URL = vm.envString("RPC_URL_MAINNET");

    // address beetxVault = BEETX_VAULT_OP;
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

    // /* Contract variables */
    // OptionsToken optionsToken;
    ERC1967Proxy tmpProxy;
    // OptionsToken optionsTokenProxy;
    // DiscountExercise exerciser;
    // BalancerOracle oracle;
    // MockBalancerTwapOracle balancerTwapOracle;
    ReaperStrategySonne strategySonne;
    ReaperStrategySonne strategySonneProxy;

    // ReaperSwapper reaperSwapperProxy;
    // ReaperSwapper reaperSwapper;
    // Helper helper;
    // uint256 initTwap = 0;

    // function fixture_prepareOptionToken(
    //     uint256 _amount,
    //     address _strategy
    // ) public {
    //     /* mint options tokens and transfer them to the strategy (rewards simulation) */
    //     vm.startPrank(tokenAdmin);
    //     optionsTokenProxy.mint(tokenAdmin, _amount);
    //     optionsTokenProxy.transfer(_strategy, _amount);
    //     vm.stopPrank();
    // }

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
        // uint256 optimismFork = vm.createFork(OPTIMISM_MAINNET_URL);
        // vm.selectFork(optimismFork);

        /* Variables */
        // paymentToken = IERC20(WETH);
        // underlyingToken = IERC20(OATH);

        /**** Contract deployments and configurations ****/
        // helper = new Helper();

        /* Reaper deployment and configuration */
        // reaperSwapperProxy = new ReaperSwapper(
        //     strategists,
        //     address(this),
        //     address(this)
        // );

        // reaperSwapperProxy.updateBalSwapPoolID(
        //     address(weth),
        //     address(oath),
        //     beetxVault,
        //     OATHV1_ETH_BPT
        // );
        // reaperSwapperProxy.updateBalSwapPoolID(
        //     address(oath),
        //     address(weth),
        //     beetxVault,
        //     OATHV1_ETH_BPT
        // );
        // reaperSwapperProxy.updateBalSwapPoolID(
        //     address(weth),
        //     cusdc.underlying(),
        //     beetxVault,
        //     BTC_WETH_USDC_BPT
        // );

        /* Oracle mocks deployment */
        // address[] memory tokens = new address[](2);
        // tokens[0] = address(underlyingToken);
        // tokens[1] = address(paymentToken);
        // balancerTwapOracle = new MockBalancerTwapOracle(tokens);
        // oracle = new BalancerOracle(
        //     balancerTwapOracle,
        //     address(underlyingToken),
        //     owner,
        //     ORACLE_SECS,
        //     ORACLE_AGO,
        //     ORACLE_MIN_PRICE
        // );

        // /* Option token deployment */
        // vm.startPrank(owner);

        // tmpProxy = new ERC1967Proxy(address(optionsToken), "");
        // optionsTokenProxy = OptionsToken(address(tmpProxy));
        // optionsTokenProxy.initialize(
        //     "TIT Call Option Token",
        //     "oTIT",
        //     tokenAdmin
        // );

        // exerciser = new DiscountExercise(
        //     optionsTokenProxy,
        //     owner,
        //     paymentToken,
        //     underlyingToken,
        //     oracle,
        //     PRICE_MULTIPLIER,
        //     treasuries,
        //     feeBPS
        // );
        // // add exerciser to the list of options
        // optionsTokenProxy.setExerciseContract(address(exerciser), true);

        // /* Option compounder deployment */
        // console2.log("Deployment contract");
        // strategySonne = new ReaperStrategySonne();
        // console2.log("Deployment strategy proxy");
        // tmpProxy = new ERC1967Proxy(address(strategySonne), "");
        // console2.log("Initialization proxied sonne strategy");
        // strategySonneProxy = ReaperStrategySonne(address(tmpProxy));
        // strategySonneProxy.initialize(
        //     vault,
        //     address(reaperSwapperProxy),
        //     strategists,
        //     multisigRoles,
        //     keepers,
        //     CUSDC,
        //     address(optionsTokenProxy),
        //     POOL_ADDRESSES_PROVIDER,
        //     targetLTV
        // );
        // vm.stopPrank();

        // /* Prepare EOA and contracts for tests */
        // helper.getWethFromEth{value: AMOUNT * 2}(WETH);

        // MinAmountOutData memory minAmountOutData = MinAmountOutData(
        //     MinAmountOutKind.Absolute,
        //     0
        // );
        // weth.approve(address(reaperSwapperProxy), AMOUNT);
        // reaperSwapperProxy.swapBal(
        //     address(weth),
        //     address(underlyingToken),
        //     AMOUNT,
        //     minAmountOutData,
        //     beetxVault
        // );
        // uint256 underlyingBalance = underlyingToken.balanceOf(address(this));
        // initTwap = AMOUNT.mulDivUp(1e18, underlyingBalance); // Question: temporary inaccurate solution. How to get the newest price easily ?
        // console2.log(">>>> Init TWAP: ", initTwap);
        // oath.transfer(address(exerciser), underlyingBalance);

        // // set up contracts
        // balancerTwapOracle.setTwapValue(initTwap);
        // paymentToken.approve(address(exerciser), type(uint256).max);

        // // temp logs
        // console2.log("Sonne strategy: ", address(strategySonneProxy));
        // console2.log("Options Token: ", address(optionsTokenProxy));
        // console2.log("Address of this contract: ", address(this));
        // console2.log("Address of owner: ", owner);
        // console2.log("Address of token admin: ", tokenAdmin);
    }

    function fixture_convertion(
        uint256 value,
        uint256 divider,
        uint256 multiplier
    ) public pure returns (uint256) {
        return
            (value >= divider)
                ? (value / divider) * multiplier
                : (value * multiplier) / divider;
    }

    function test_utFlashloanPositiveScenario(
        uint256 paymentAmountToMint,
        uint256 initialPaymentBalance,
        uint256 paymentBalanceAfterSwap,
        uint256 underlyingAmount,
        uint256 wantAmount,
        uint256 oTokensAmount
    ) public {
        uint256 factor = 5000; // < PERCENTAGE
        uint256 premium = 100;
        /* Test vectors definition */
        /* Payment token amount which is transfered at init and imitates initial balance of the strategy before flashloan compound */
        initialPaymentBalance = 0; // bound(initialPaymentBalance, 0, 1 ether);
        console2.log("Initial Payment amount: ", initialPaymentBalance);

        /* Payment token amount to mint at init - must be greater than all required tokens (initial amount + amount transferred after swap) 
        Cannot be higher than (UINT256_MAX / PERCENTAGE) - 11.5e54 ETH */
        vm.assume(
            paymentAmountToMint > (initialPaymentBalance + premium) &&
                paymentAmountToMint < (UINT256_MAX / PERCENTAGE)
        );
        console2.log("Payment amount: ", paymentAmountToMint);

        /* Maximum amount of OTokens possible to simlate assuming minted and initial amount of payment token */
        uint256 maxAmountOfOTokens = ((paymentAmountToMint -
            initialPaymentBalance) * PERCENTAGE) / factor;
        console2.log(
            "Maximum amount of OTokens possible: ",
            maxAmountOfOTokens
        );
        vm.assume(oTokensAmount <= maxAmountOfOTokens);
        console2.log("OToken amount: ", oTokensAmount);

        /* Payment balance after swap shall be greater than borrowed asset + premium and less than minted asset - initial balance */
        uint256 borrowedAssetBalance = (oTokensAmount * factor) / PERCENTAGE;
        vm.assume(
            paymentBalanceAfterSwap > (premium + borrowedAssetBalance) &&
                paymentBalanceAfterSwap <
                (paymentAmountToMint - initialPaymentBalance)
        );
        console2.log("Borrowed Asset Amount: ", paymentBalanceAfterSwap);
        vm.assume(
            paymentAmountToMint >
                paymentBalanceAfterSwap + initialPaymentBalance
        );
        console2.log("Adjusted payment amount: ", paymentAmountToMint);

        uint256 targetLTV = 0.0001 ether;
        /* prepare option tokens - distribute them to the specified strategy 
        and approve for spending */
        // fixture_prepareOptionToken(amount, address(strategySonneProxy));
        address[] memory strategists = new address[](1);
        address[] memory multisigRoles = new address[](3);
        address[] memory keepers = new address[](1);
        strategists[0] = strategist;
        multisigRoles[0] = management1;
        multisigRoles[1] = management2;
        multisigRoles[2] = management3;
        keepers[0] = keeper;

        vm.startPrank(owner);
        /* Option compounder deployment */
        console2.log("Deployment contract");
        strategySonne = new ReaperStrategySonne();
        console2.log("Deployment strategy proxy");
        tmpProxy = new ERC1967Proxy(address(strategySonne), "");
        console2.log("Initialization proxied sonne strategy");
        strategySonneProxy = ReaperStrategySonne(address(tmpProxy));
        UtMock utMock = new UtMock(
            paymentAmountToMint,
            initialPaymentBalance,
            paymentBalanceAfterSwap,
            underlyingAmount,
            wantAmount,
            oTokensAmount,
            premium,
            address(strategySonneProxy)
        );
        strategySonneProxy.initialize(
            vault,
            address(utMock),
            strategists,
            multisigRoles,
            keepers,
            address(utMock),
            address(utMock),
            address(utMock),
            targetLTV
        );
        vm.stopPrank();

        vm.startPrank(keeper);
        /* already approved in fixture_prepareOptionToken */
        strategySonneProxy.harvestOTokens(oTokensAmount, address(utMock));
        vm.stopPrank();

        // temporary logs
        console2.log("[Test] 2. Gain: ", strategySonneProxy.getLastGain());

        /* Check balances after compounding */
        /* Assertions */
        // assertEq(
        //     strategySonneProxy.getLastGain() > 0,
        //     true,
        //     "Gain not greater than 0"
        // );
        // assertEq(
        //     wethBalance <= weth.balanceOf(address(strategySonneProxy)),
        //     true,
        //     "Lower weth balance than before"
        // );
        // assertEq(
        //     wantBalance <= usdc.balanceOf(address(strategySonneProxy)),
        //     true,
        //     "Lower want balance than before"
        // );
        // assertEq(
        //     optionsBalance >
        //         optionsTokenProxy.balanceOf(address(strategySonneProxy)),
        //     true,
        //     "Lower balance than before"
        // );
        // assertEq(
        //     0 == optionsTokenProxy.balanceOf(address(strategySonneProxy)),
        //     true,
        //     "Options token balance is not 0"
        // );
    }
}

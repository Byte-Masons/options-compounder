// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {ReaperStrategySonne} from "./strategies/ReaperStrategySonne.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {UtMock} from "./mocks/UtMock.sol";
import {ReaperSwapper, MinAmountOutData, MinAmountOutKind} from "./mocks/ReaperSwapper.sol";

contract OptionsTokenTest is Test {
    using FixedPointMathLib for uint256;

    /* Constants */
    uint256 constant AMOUNT = 2e18; // 2 ETH
    uint256 constant PERCENTAGE = 10_000;

    /* Variables */
    IERC20 paymentToken;
    IERC20 underlyingToken;
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
    ERC1967Proxy tmpProxy;
    ReaperStrategySonne strategySonne;
    ReaperStrategySonne strategySonneProxy;

    function setUp() public {
        /* Set up accounts */
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
    }

    function test_utFlashloanPositiveScenario(
        uint256 paymentAmountToMint,
        uint256 initialPaymentBalance,
        uint256 paymentBalanceAfterSwap,
        uint256 wantAmount,
        uint256 oTokensAmount,
        uint256 minWantAmount
    ) public {
        /* Fixed */
        uint256 factor = 5000; // < PERCENTAGE
        uint256 premium = 100;

        /*** Test vectors definitions ***/

        /* Payment token amount which is transfered at init and imitates initial 
        balance of the strategy before flashloan compound */
        initialPaymentBalance = bound(initialPaymentBalance, 0, 100 ether);

        /* Payment token amount to mint at init - must be greater than all required 
        tokens (initial amount + amount transferred after swap) 
        Cannot be higher than (UINT256_MAX / PERCENTAGE) - 11.5e54 ETH */
        vm.assume(
            paymentAmountToMint > (initialPaymentBalance + premium) &&
                paymentAmountToMint < (UINT256_MAX / PERCENTAGE)
        );

        /* Maximum amount of OTokens possible to simlate assuming minted and initial 
        amount of payment token */
        uint256 maxAmountOfOTokens = ((paymentAmountToMint -
            initialPaymentBalance) * PERCENTAGE) / factor;
        vm.assume(oTokensAmount <= maxAmountOfOTokens);

        /* Payment balance after swap shall be greater than borrowed asset + premium and 
        less than minted asset - initial balance */
        uint256 borrowedAssetBalance = (oTokensAmount * factor) / PERCENTAGE;
        vm.assume(
            paymentBalanceAfterSwap > (premium + borrowedAssetBalance) &&
                paymentBalanceAfterSwap <
                (paymentAmountToMint - initialPaymentBalance)
        );
        vm.assume(
            paymentAmountToMint >
                paymentBalanceAfterSwap + initialPaymentBalance
        );

        /* Want amount shall be grater than minWantAmount */
        minWantAmount = bound(minWantAmount, 1, 1e19);
        wantAmount = bound(wantAmount, minWantAmount, UINT256_MAX);

        /* Initialization of variables */
        uint256 targetLTV = 0.0001 ether;
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
        strategySonne = new ReaperStrategySonne();
        tmpProxy = new ERC1967Proxy(address(strategySonne), "");
        strategySonneProxy = ReaperStrategySonne(address(tmpProxy));
        UtMock utMock = new UtMock(
            paymentAmountToMint,
            initialPaymentBalance,
            paymentBalanceAfterSwap,
            wantAmount,
            oTokensAmount,
            premium,
            address(strategySonneProxy),
            factor
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
        strategySonneProxy.harvestOTokens(
            oTokensAmount,
            address(utMock),
            minWantAmount
        );
        vm.stopPrank();

        /* Check balances after compounding */
        /* Assertions */
        assertEq(
            utMock.mockedUnderlyingWant().balanceOf(
                address(strategySonneProxy)
            ) > 0,
            true,
            "Gain not greater than 0"
        );
        assertEq(
            (utMock.mockedPaymentToken().balanceOf(
                address(strategySonneProxy)
            ) - initialPaymentBalance) >=
                (paymentBalanceAfterSwap - borrowedAssetBalance),
            true,
            "Lower payment balance than before"
        );
        assertEq(
            utMock.nrOfCallsSwapBal() == 2,
            true,
            "Number of calls swapBal not equal 2"
        );
        assertEq(
            utMock.nrOfCallsExercise() == 1,
            true,
            "Number of calls swapBal not equal 1"
        );
        assertEq(
            utMock.nrOfCallsFlashloan() == 1,
            true,
            "Number of calls swapBal not equal 1"
        );
    }

    function test_utFlashloanNegativeScenario_TooFewPaymentTokens(
        uint256 paymentAmountToMint,
        uint256 initialPaymentBalance,
        uint256 paymentBalanceAfterSwap,
        uint256 wantAmount,
        uint256 oTokensAmount,
        uint256 minWantAmount
    ) public {
        /* Fixed */
        uint256 factor = 5000; // < PERCENTAGE
        uint256 premium = 100;

        /*** Test vectors definitions ***/

        /* Payment token amount which is transfered at init and imitates initial 
        balance of the strategy before flashloan compound */
        initialPaymentBalance = bound(initialPaymentBalance, 0, 100 ether);

        /* Payment token amount to mint at init - must be greater than all required 
        tokens (initial amount + amount transferred after swap) 
        Cannot be higher than (UINT256_MAX / PERCENTAGE) - 11.5e54 ETH */
        vm.assume(
            paymentAmountToMint > (initialPaymentBalance + premium) &&
                paymentAmountToMint < (UINT256_MAX / PERCENTAGE)
        );

        /* Maximum amount of OTokens possible to simulate assuming minted and initial 
        amount of payment token */
        uint256 maxAmountOfOTokens = ((paymentAmountToMint -
            initialPaymentBalance -
            premium) * PERCENTAGE) / factor;

        /* Otoken amount must be some value between 0 and maximum amount calculated above */
        oTokensAmount = bound(oTokensAmount, 0, maxAmountOfOTokens);

        /* Payment balance after swap shall be less than borrowed asset + premium 
        so it make flashloan not profitable */
        uint256 borrowedAssetBalance = (oTokensAmount * factor) / PERCENTAGE;
        paymentBalanceAfterSwap = bound(
            paymentBalanceAfterSwap,
            0,
            (premium + borrowedAssetBalance)
        );

        /* Want amount shall be grater than minWantAmount */
        minWantAmount = bound(minWantAmount, 1, 1e19);
        wantAmount = bound(wantAmount, minWantAmount, UINT256_MAX);

        /* Initialization of variables */
        uint256 targetLTV = 0.0001 ether;
        address[] memory strategists = new address[](1);
        address[] memory multisigRoles = new address[](3);
        address[] memory keepers = new address[](1);
        strategists[0] = strategist;
        multisigRoles[0] = management1;
        multisigRoles[1] = management2;
        multisigRoles[2] = management3;
        keepers[0] = keeper;

        vm.startPrank(owner);
        /* Option compounder deployment together with strategy */
        strategySonne = new ReaperStrategySonne();
        tmpProxy = new ERC1967Proxy(address(strategySonne), "");
        strategySonneProxy = ReaperStrategySonne(address(tmpProxy));
        UtMock utMock = new UtMock(
            paymentAmountToMint,
            initialPaymentBalance,
            paymentBalanceAfterSwap,
            wantAmount,
            oTokensAmount,
            premium,
            address(strategySonneProxy),
            factor
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
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__FlashloanNotProfitable()"))
        );
        strategySonneProxy.harvestOTokens(
            oTokensAmount,
            address(utMock),
            minWantAmount
        );
        vm.stopPrank();

        /* Check balances after compounding */
        /* Assertions - tx reverted so all calls shall be 0 */
        assertEq(
            utMock.nrOfCallsSwapBal() == 0,
            true,
            "Number of calls swapBal not equal 0"
        );
        assertEq(
            utMock.nrOfCallsExercise() == 0,
            true,
            "Number of calls swapBal not equal 0"
        );
        assertEq(
            utMock.nrOfCallsFlashloan() == 0,
            true,
            "Number of calls swapBal not equal 0"
        );
    }

    function test_utFlashloanNegativeScenario_WantIsZero(
        uint256 paymentAmountToMint,
        uint256 initialPaymentBalance,
        uint256 paymentBalanceAfterSwap,
        uint256 wantAmount,
        uint256 oTokensAmount,
        uint256 minWantAmount
    ) public {
        /* Fixed */
        uint256 premium = 1000;
        /* Fuzzed factor less than 100% */
        uint256 factor = 5000;

        /*** Test vectors definitions ***/

        /* Payment token amount which is transfered at init and imitates initial 
        balance of the strategy before flashloan compound */
        initialPaymentBalance = bound(initialPaymentBalance, 0, 100 ether);

        /* Payment token amount to mint at init - must be greater than all required 
        tokens (initial amount + amount transferred after swap) 
        Cannot be higher than (UINT256_MAX / PERCENTAGE) - 11.5e54 ETH */
        vm.assume(
            paymentAmountToMint > (initialPaymentBalance + premium) &&
                paymentAmountToMint < (UINT256_MAX / PERCENTAGE)
        );

        /* Maximum amount of OTokens possible to simlate assuming minted and initial 
        amount of payment token */
        uint256 maxAmountOfOTokens = ((paymentAmountToMint -
            initialPaymentBalance) * PERCENTAGE) / factor;
        vm.assume(oTokensAmount <= maxAmountOfOTokens);

        /* Borrowed token amount must reflect oTokenAmount value in payment token */
        uint256 borrowedAssetBalance = (oTokensAmount * factor) / PERCENTAGE;

        /* Payment token amount increase after swap - to not revert 
        it must be greater than borrowed asset + premium and 
        less than minted asset - initial balance*/
        vm.assume(
            paymentBalanceAfterSwap > (premium + borrowedAssetBalance) &&
                paymentBalanceAfterSwap <
                (paymentAmountToMint - initialPaymentBalance)
        );

        /* Want token shall be less than minWantAmount */
        minWantAmount = bound(minWantAmount, 1, 1e19);
        wantAmount = bound(wantAmount, 0, minWantAmount - 1);

        /* Initialization of variables */
        uint256 targetLTV = 0.0001 ether;
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
        strategySonne = new ReaperStrategySonne();
        tmpProxy = new ERC1967Proxy(address(strategySonne), "");
        strategySonneProxy = ReaperStrategySonne(address(tmpProxy));
        UtMock utMock = new UtMock(
            paymentAmountToMint,
            initialPaymentBalance,
            paymentBalanceAfterSwap,
            wantAmount,
            oTokensAmount,
            premium,
            address(strategySonneProxy),
            factor
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
        vm.expectRevert(
            bytes4(keccak256("OptionsCompounder__FlashloanNotProfitable()"))
        );
        strategySonneProxy.harvestOTokens(
            oTokensAmount,
            address(utMock),
            minWantAmount
        );
        vm.stopPrank();

        /* Check balances after compounding */
        /* Assertions - tx reverted so all calls shall be 0 */
        assertEq(
            utMock.nrOfCallsSwapBal() == 0,
            true,
            "Number of calls swapBal not equal 0"
        );
        assertEq(
            utMock.nrOfCallsExercise() == 0,
            true,
            "Number of calls swapBal not equal 0"
        );
        assertEq(
            utMock.nrOfCallsFlashloan() == 0,
            true,
            "Number of calls swapBal not equal 0"
        );
    }
}

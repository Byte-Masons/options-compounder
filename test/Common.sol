// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
// import {ReaperSwapper, MinAmountOutData, MinAmountOutKind} from "vault-v2/ReaperSwapper.sol";
import {ReaperSwapper, MinAmountOutData, MinAmountOutKind, IVeloRouter, RouterV2} from "./mocks/ReaperSwapper.sol";
import {OptionsToken} from "optionsToken/src/OptionsToken.sol";
import {SwapProps, ExchangeType} from "../src/OptionsCompounder.sol";

/* Constants */
uint256 constant FORK_BLOCK_OP = 114768697;
uint256 constant NON_ZERO_PROFIT = 1;
uint16 constant PRICE_MULTIPLIER = 5000; // 0.5
uint56 constant ORACLE_SECS = 30 minutes;
uint56 constant ORACLE_AGO = 2 minutes;
uint128 constant ORACLE_MIN_PRICE = 1e10;
uint56 constant ORACLE_LARGEST_SAFETY_WINDOW = 24 hours;
uint256 constant ORACLE_MIN_PRICE_DENOM = 10000;
uint256 constant MAX_SUPPLY = 1e27; // the max supply of the options token & the underlying token

uint256 constant AMOUNT = 2e18; // 2 ETH
address constant REWARDER = 0x6A0406B8103Ec68EE9A713A073C7bD587c5e04aD;
uint256 constant MIN_OATH_FOR_FUZZING = 1e19;

/* OP */
address constant OP_POOL_ADDRESSES_PROVIDER_V2 = 0xdDE5dC81e40799750B92079723Da2acAF9e1C6D6; // Granary (aavev2)
// AAVEv3 - 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
address constant OP_WETH = 0x4200000000000000000000000000000000000006;
address constant OP_OATHV1 = 0x39FdE572a18448F8139b7788099F0a0740f51205;
address constant OP_OATHV2 = 0x00e1724885473B63bCE08a9f0a52F35b0979e35A; // V1: 0x39FdE572a18448F8139b7788099F0a0740f51205;1
address constant OP_CUSDC = 0xEC8FEa79026FfEd168cCf5C627c7f486D77b765F; // Optimism
address constant OP_GUSDC = 0x7A0FDDBA78FF45D353B1630B77f4D175A00df0c0;
address constant OP_DATA_PROVIDER = 0x9546F673eF71Ff666ae66d01Fd6E7C6Dae5a9995;
bytes32 constant OP_OATHV1_ETH_BPT = 0xd20f6f1d8a675cdca155cb07b5dc9042c467153f0002000000000000000000bc; // OATHv1/ETH BPT
bytes32 constant OP_OATHV2_ETH_BPT = 0xd13d81af624956327a24d0275cbe54b0ee0e9070000200000000000000000109; // OATHv2/ETH BPT
bytes32 constant OP_BTC_WETH_USDC_BPT = 0x5028497af0c9a54ea8c6d42a054c0341b9fc6168000100000000000000000004;
address constant OP_BEETX_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

/* BSC */
address constant BSC_RUSDC = 0x3bDCEf9e656fD9D03eA98605946b4fbF362C342b;
address constant BSC_THENA = 0xF4C8E32EaDEC4BFe97E0F595AdD0f4450a863a11;
address constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant BSC_VELO_ROUTER = 0xd4ae6eCA985340Dd434D38F470aCCce4DC78D109;
address constant BSC_VELO_FACTORY = 0x2c788FE40A417612cb654b14a944cd549B5BF130;

contract Common is Test {
    IERC20 nativeToken;
    IERC20 paymentToken;
    IERC20 underlyingToken;
    IERC20 wantToken;

    ReaperSwapper reaperSwapper;
    address veloRouter = BSC_VELO_ROUTER;
    address veloFactory = BSC_VELO_FACTORY;
    bytes32 paymentUnderlyingBpt = OP_OATHV1_ETH_BPT;
    bytes32 paymentWantBpt = OP_BTC_WETH_USDC_BPT;
    address balancerVault = OP_BEETX_VAULT;

    // function assignCommon(address)
    /* Functions */
    function fixture_prepareOptionToken(
        uint256 _amount,
        address _strategy,
        OptionsToken _optionsToken,
        address _tokenAdmin
    ) public {
        /* Mint options tokens and transfer them to the strategy (rewards simulation) */
        vm.startPrank(_tokenAdmin);
        _optionsToken.mint(_tokenAdmin, _amount);
        _optionsToken.transfer(_strategy, _amount);
        vm.stopPrank();
    }

    function fixture_configureSwapper(ExchangeType _exchangeType) public {
        if (_exchangeType == ExchangeType.Bal) {
            /* Configure balancer like dexes */
            reaperSwapper.updateBalSwapPoolID(
                address(paymentToken),
                address(underlyingToken),
                balancerVault,
                paymentUnderlyingBpt
            );
            reaperSwapper.updateBalSwapPoolID(
                address(underlyingToken),
                address(paymentToken),
                balancerVault,
                paymentUnderlyingBpt
            );
            reaperSwapper.updateBalSwapPoolID(
                address(paymentToken),
                address(wantToken),
                balancerVault,
                paymentWantBpt
            );
        } else if (_exchangeType == ExchangeType.VeloSolid) {
            /* configure velo like dexes */
            RouterV2.route[] memory path = new RouterV2.route[](1);
            path[0] = RouterV2.route(
                address(paymentToken),
                address(underlyingToken),
                false
            );
            reaperSwapper.updateVeloSwapPath(
                address(paymentToken),
                address(underlyingToken),
                veloRouter,
                path
            );
            path[0] = RouterV2.route(
                address(underlyingToken),
                address(paymentToken),
                false
            );
            reaperSwapper.updateVeloSwapPath(
                address(underlyingToken),
                address(paymentToken),
                veloRouter,
                path
            );
            path[0] = RouterV2.route(
                address(paymentToken),
                address(wantToken),
                false
            );
            reaperSwapper.updateVeloSwapPath(
                address(paymentToken),
                address(wantToken),
                veloRouter,
                path
            );
        }
    }
}
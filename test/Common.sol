// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {ReaperSwapper, MinAmountOutData, MinAmountOutKind, IThenaRamRouter, ISwapRouter, UniV3SwapData} from "vault-v2/ReaperSwapper.sol";
import {OptionsToken} from "optionsToken/src/OptionsToken.sol";
import {SwapProps, ExchangeType} from "../src/OptionsCompounder.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {DiscountExerciseParams, DiscountExercise} from "optionsToken/src/exercise/DiscountExercise.sol";
import {IOracle} from "optionsToken/src/interfaces/IOracle.sol";
import {ThenaOracle, IThenaPair} from "optionsToken/src/oracles/ThenaOracle.sol";
import {IUniswapV3Factory} from "vault-v2/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool, UniswapV3Oracle} from "optionsToken/src/oracles/UniswapV3Oracle.sol";

error Common__NotYetImplemented();

/* Constants */
uint256 constant NON_ZERO_PROFIT = 1;
uint16 constant PRICE_MULTIPLIER = 5000; // 0.5
uint56 constant ORACLE_SECS = 30 minutes;
uint56 constant ORACLE_AGO = 2 minutes;
uint128 constant ORACLE_MIN_PRICE = 1e7;
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
address constant OP_OATHV2 = 0x00e1724885473B63bCE08a9f0a52F35b0979e35A;
address constant OP_CUSDC = 0xEC8FEa79026FfEd168cCf5C627c7f486D77b765F;
address constant OP_GUSDC = 0x7A0FDDBA78FF45D353B1630B77f4D175A00df0c0;
address constant OP_USDC = 0x7F5c764cBc14f9669B88837ca1490cCa17c31607;
address constant OP_DATA_PROVIDER = 0x9546F673eF71Ff666ae66d01Fd6E7C6Dae5a9995;
bytes32 constant OP_OATHV1_ETH_BPT = 0xd20f6f1d8a675cdca155cb07b5dc9042c467153f0002000000000000000000bc; // OATHv1/ETH BPT
bytes32 constant OP_OATHV2_ETH_BPT = 0xd13d81af624956327a24d0275cbe54b0ee0e9070000200000000000000000109; // OATHv2/ETH BPT
bytes32 constant OP_BTC_WETH_USDC_BPT = 0x5028497af0c9a54ea8c6d42a054c0341b9fc6168000100000000000000000004;
address constant OP_BEETX_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

/* BSC */
address constant BSC_BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
address constant BSC_RUSDC = 0x3bDCEf9e656fD9D03eA98605946b4fbF362C342b;
address constant BSC_THENA = 0xF4C8E32EaDEC4BFe97E0F595AdD0f4450a863a11;
address constant BSC_WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
address constant BSC_THENA_ROUTER = 0xd4ae6eCA985340Dd434D38F470aCCce4DC78D109;
address constant BSC_THENA_FACTORY = 0x2c788FE40A417612cb654b14a944cd549B5BF130;
address constant BSC_PANCAKE_ROUTERV3 = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
address constant BSC_PANCAKE_FACTORYV3 = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

/* ARB */
address constant ARB_USDCE = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
address constant ARB_RAM = 0xAAA6C1E32C55A7Bfa8066A6FAE9b42650F262418;
address constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
address constant ARB_RAM_ROUTER = 0xAAA87963EFeB6f7E0a2711F397663105Acb1805e;
address constant ARB_RAM_ROUTERV2 = 0xAA23611badAFB62D37E7295A682D21960ac85A90; //univ3
address constant ARB_RAM_FACTORYV2 = 0xAA2cd7477c451E703f3B9Ba5663334914763edF8;

contract Common is Test {
    IERC20 nativeToken;
    IERC20 paymentToken;
    IERC20 underlyingToken;
    IERC20 wantToken;
    IThenaRamRouter thenaRamRouter;
    ISwapRouter routerV2;

    ReaperSwapper reaperSwapper;
    bytes32 paymentUnderlyingBpt;
    bytes32 paymentWantBpt;
    address balancerVault;

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

    OptionsToken optionsToken;
    ERC1967Proxy tmpProxy;
    OptionsToken optionsTokenProxy;
    DiscountExercise exerciser;

    function fixture_setupAccountsAndFees(uint256 fee1, uint256 fee2) public {
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
        feeBPS[0] = fee1;
        feeBPS[1] = fee2;
    }

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

    function fixture_configureSwapper(
        ExchangeType[] memory exchangeType
    ) public {
        require(exchangeType.length == 2, "Length not 2");
        address[2][] memory paths = new address[2][](exchangeType.length);
        paths[0] = [address(underlyingToken), address(paymentToken)];
        paths[1] = [address(paymentToken), address(wantToken)];

        for (uint8 idx = 0; idx < exchangeType.length; idx++) {
            if (exchangeType[idx] == ExchangeType.Bal) {
                bytes32[] memory bpts = new bytes32[](2);
                bpts[0] = paymentUnderlyingBpt;
                bpts[1] = paymentWantBpt;
                /* Configure balancer like dexes */
                reaperSwapper.updateBalSwapPoolID(
                    paths[idx][0],
                    paths[idx][1],
                    balancerVault,
                    bpts[idx]
                );
                reaperSwapper.updateBalSwapPoolID(
                    paths[idx][1],
                    paths[idx][0],
                    balancerVault,
                    bpts[idx]
                );
            } else if (exchangeType[idx] == ExchangeType.ThenaRam) {
                /* Configure thena ram like dexes */
                IThenaRamRouter.route[]
                    memory thenaPath = new IThenaRamRouter.route[](1);
                thenaPath[0] = IThenaRamRouter.route(
                    paths[idx][0],
                    paths[idx][1],
                    false
                );
                reaperSwapper.updateThenaRamSwapPath(
                    paths[idx][0],
                    paths[idx][1],
                    address(thenaRamRouter),
                    thenaPath
                );
                thenaPath[0] = IThenaRamRouter.route(
                    paths[idx][1],
                    paths[idx][0],
                    false
                );
                reaperSwapper.updateThenaRamSwapPath(
                    paths[idx][1],
                    paths[idx][0],
                    address(thenaRamRouter),
                    thenaPath
                );
            } else if (exchangeType[idx] == ExchangeType.UniV3) {
                /* Configure univ3 like dexes */
                uint24[] memory univ3Fees = new uint24[](1);
                univ3Fees[0] = 500;
                address[] memory univ3Path = new address[](2);

                univ3Path[0] = paths[idx][0];
                univ3Path[1] = paths[idx][1];
                UniV3SwapData memory swapPathAndFees = UniV3SwapData(
                    univ3Path,
                    univ3Fees
                );
                reaperSwapper.updateUniV3SwapPath(
                    paths[idx][0],
                    paths[idx][1],
                    address(routerV2),
                    swapPathAndFees
                );

                // univ3Path[0] = paths[idx][1];
                // univ3Path[1] = paths[idx][0];
                // univ3Fees[0] = 500;
                // swapPathAndFees = UniV3SwapData(univ3Path, univ3Fees);
                // reaperSwapper.updateUniV3SwapPath(
                //     paths[idx][1],
                //     paths[idx][0],
                //     address(routerV2),
                //     swapPathAndFees
                // );
            } else {
                revert Common__NotYetImplemented();
            }
        }
    }

    function fixture_getOracles(
        ExchangeType[] memory exchangeType
    ) public returns (IOracle[] memory oracles) {
        require(exchangeType.length == 2, "Length not 2");
        oracles = new IOracle[](exchangeType.length);

        address[] memory tokens = new address[](exchangeType.length);
        tokens[0] = address(underlyingToken);
        tokens[1] = address(paymentToken);

        address[2][] memory paths = new address[2][](exchangeType.length);
        paths[0] = [address(underlyingToken), address(paymentToken)];
        paths[1] = [address(paymentToken), address(wantToken)];

        for (uint8 idx = 0; idx < exchangeType.length; idx++) {
            if (exchangeType[idx] == ExchangeType.Bal) {
                revert Common__NotYetImplemented();
            } else if (exchangeType[idx] == ExchangeType.ThenaRam) {
                IThenaRamRouter router = IThenaRamRouter(
                    payable(address(thenaRamRouter))
                );
                ThenaOracle underlyingPaymentOracle;
                address pair = router.pairFor(
                    paths[idx][0],
                    paths[idx][1],
                    false
                );
                underlyingPaymentOracle = new ThenaOracle(
                    IThenaPair(pair),
                    tokens[idx],
                    owner,
                    ORACLE_SECS,
                    ORACLE_MIN_PRICE
                );
                oracles[idx] = IOracle(address(underlyingPaymentOracle));
            } else if (exchangeType[idx] == ExchangeType.UniV3) {
                IUniswapV3Factory univ3Factory = IUniswapV3Factory(
                    BSC_PANCAKE_FACTORYV3
                );

                IUniswapV3Pool univ3Pool = IUniswapV3Pool(
                    univ3Factory.getPool(paths[0][idx], paths[1][idx], 500)
                );
                UniswapV3Oracle univ3Oracle = new UniswapV3Oracle(
                    univ3Pool,
                    tokens[idx],
                    owner,
                    uint32(ORACLE_SECS),
                    uint32(ORACLE_AGO),
                    ORACLE_MIN_PRICE
                );
                oracles[idx] = IOracle(address(univ3Oracle));
            } else {
                revert Common__NotYetImplemented();
            }
        }
    }

    function fixture_getSwapProps(
        ExchangeType[] memory exchangeType
    ) public view returns (SwapProps[] memory swapProps) {
        require(exchangeType.length == 2, "Length not 2");
        swapProps = new SwapProps[](exchangeType.length);

        for (uint8 idx = 0; idx < exchangeType.length; idx++) {
            if (exchangeType[idx] == ExchangeType.Bal) {
                revert Common__NotYetImplemented();
            } else if (exchangeType[idx] == ExchangeType.ThenaRam) {
                swapProps[idx] = SwapProps(
                    address(thenaRamRouter),
                    ExchangeType.ThenaRam
                );
            } else if (exchangeType[idx] == ExchangeType.UniV3) {
                swapProps[idx] = SwapProps(
                    address(routerV2),
                    ExchangeType.UniV3
                );
            } else {
                revert Common__NotYetImplemented();
            }
        }
    }
}

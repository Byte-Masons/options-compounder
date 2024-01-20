// SPDX-License-Identifier: BUSL1.1

pragma solidity ^0.8.0;

import {SwapProps, OptionsCompounder} from "../../src/OptionsCompounder.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {IOracle} from "optionsToken/src/oracles/ThenaOracle.sol";

contract MockedLendingPool {
    MockedStrategy strategy;

    constructor() {}

    function setStrategy(address _strategyAddress) external {
        strategy = MockedStrategy(_strategyAddress);
    }

    function getLendingPool() external view returns (address) {
        return address(this);
    }

    function flashLoan(
        address receiverAddress,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address onBehalfOf,
        bytes calldata params,
        uint16 referralCode
    ) external {
        require(
            address(strategy) != address(0),
            "Address of strategy is not set"
        );
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = 0;
        IERC20(assets[0]).transfer(address(strategy), amounts[0]);
        strategy.executeOperation(
            assets,
            amounts,
            premiums,
            msg.sender,
            params
        );
    }
}

contract MockedStrategy is OptionsCompounder {
    address want;
    address swapper;
    bytes32 constant KEEPER = keccak256("KEEPER");
    bytes32 constant ADMIN = keccak256("ADMIN");
    bytes32 constant DEFAULT_ADMIN_ROLE = keccak256("DEFAULT_ADMIN_ROLE");

    constructor() {}

    function __MockedStrategy_init(
        address _swapper,
        address _want,
        address _optionsToken,
        address _addressProvider,
        uint256 _maxSwapSlippage,
        SwapProps[] memory _swapProps,
        IOracle[] memory _oracles
    ) public initializer {
        __OptionsCompounder_init(
            _optionsToken,
            _addressProvider,
            _maxSwapSlippage,
            _swapProps,
            _oracles
        );
        want = _want;
        swapper = _swapper;
    }

    /* Override functions */
    /**
     * @dev Shall be implemented in the parent contract
     * @return Want token of the strategy
     */
    function wantToken() internal view virtual override returns (address) {
        return want;
    }

    /**
     * @dev Shall be implemented in the parent contract
     * @return Swapper contract used in the strategy
     */
    function swapperSwaps() internal view virtual override returns (address) {
        return address(swapper);
    }

    /**
     * @dev Subclasses should override this to specify their unique role-checking criteria.
     * @return Returns bool value. {true} if {_account} has been granted {_role}.
     */
    function hasRoleForOptionsCompounder(
        bytes32 _role,
        address _account
    ) internal view override returns (bool) {
        return true; // mocked
    }

    /**
     * @dev Shall be implemented in the parent contract
     * @return Keeper role of the strategy
     * */
    function getKeeperRole() internal pure override returns (bytes32) {
        return KEEPER;
    }

    /**
     * @dev Shall be implemented in the parent contract
     * @return Admin roles of the strategy
     * */
    function getAdminRoles() internal pure override returns (bytes32[] memory) {
        bytes32[] memory admins = new bytes32[](2);
        admins[0] = ADMIN;
        admins[1] = DEFAULT_ADMIN_ROLE;
        return admins;
    }
}

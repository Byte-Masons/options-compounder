// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {console2} from "forge-std/Test.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {IOptionsToken} from "../../src/interfaces/IOptionsToken.sol";
import {IOracle} from "../../src/interfaces/IOracle.sol";

import {IExercise} from "../../src/interfaces/IExercise.sol";

struct OptionStruct {
    uint256 paymentAmount;
}

/// @title Options Token
/// @author zefram.eth
/// @notice Options token representing the right to perform an advantageous action,
/// such as purchasing the underlying token at a discount to the market price.
contract OptionsToken is IOptionsToken, ERC20, Owned {
    /// -----------------------------------------------------------------------
    /// Errors
    /// -----------------------------------------------------------------------

    error OptionsToken__NotTokenAdmin();
    error OptionsToken__NotExerciseContract();
    error Upgradeable__Unauthorized();

    /// -----------------------------------------------------------------------
    /// Events
    /// -----------------------------------------------------------------------

    event Exercise(
        address indexed sender,
        address indexed recipient,
        uint256 amount,
        address data0,
        uint256 data1,
        uint256 data2
    );
    event SetOracle(IOracle indexed newOracle);
    event SetTreasury(address indexed newTreasury);
    event SetExerciseContract(address indexed _address, bool _isExercise);

    /// -----------------------------------------------------------------------
    /// Immutable parameters
    /// -----------------------------------------------------------------------

    uint256 public constant UPGRADE_TIMELOCK = 48 hours;
    uint256 public constant FUTURE_NEXT_PROPOSAL_TIME = 365 days * 100;
    /// @notice The contract that has the right to mint options tokens
    address public immutable tokenAdmin;

    mapping(address => bool) public isExerciseContract;

    /// -----------------------------------------------------------------------
    /// Storage variables
    /// -----------------------------------------------------------------------

    /// -----------------------------------------------------------------------
    /// Constructor
    /// -----------------------------------------------------------------------

    constructor(
        string memory name_,
        string memory symbol_,
        address owner_,
        address tokenAdmin_
    ) ERC20(name_, symbol_, 18) Owned(owner_) {
        tokenAdmin = tokenAdmin_;
    }

    /// -----------------------------------------------------------------------
    /// External functions
    /// -----------------------------------------------------------------------

    /// @notice Called by the token admin to mint options tokens
    /// @param to The address that will receive the minted options tokens
    /// @param amount The amount of options tokens that will be minted
    function mint(address to, uint256 amount) external virtual override {
        /// -----------------------------------------------------------------------
        /// Verification
        /// -----------------------------------------------------------------------

        if (msg.sender != tokenAdmin) revert OptionsToken__NotTokenAdmin();

        /// -----------------------------------------------------------------------
        /// State updates
        /// -----------------------------------------------------------------------

        // skip if amount is zero
        if (amount == 0) return;

        // mint options tokens
        _mint(to, amount);
    }

    /// @notice Exercises options tokens, giving the reward to the recipient.
    /// @dev WARNING: If `amount` is zero, the bytes returned will be empty and therefore, not decodable.
    /// @dev The options tokens are not burnt but sent to address(0) to avoid messing up the
    /// inflation schedule.
    /// @param amount The amount of options tokens to exercise
    /// @param recipient The recipient of the reward
    /// @param params Extra parameters to be used by the exercise function
    function exercise(
        uint256 amount,
        address recipient,
        address option,
        bytes calldata params
    )
        external
        virtual
        returns (
            uint256 paymentAmount,
            address,
            uint256,
            uint256 // misc data
        )
    {
        return _exercise(amount, recipient, option, params);
    }

    /// -----------------------------------------------------------------------
    /// Owner functions
    /// -----------------------------------------------------------------------

    function getPaymentAmount(
        uint256 amount,
        address option
    ) external view returns (uint256 paymentAmount) {
        paymentAmount = IExercise(option).getPaymentAmount(amount);
        return paymentAmount;
    }

    /// @notice Adds a new Exercise contract to the available options.
    /// @param _address Address of the Exercise contract, that implements BaseExercise.
    /// @param _isExercise Whether oToken holders should be allowed to exercise using this option.
    function setExerciseContract(
        address _address,
        bool _isExercise
    ) external onlyOwner {
        isExerciseContract[_address] = _isExercise;
        emit SetExerciseContract(_address, _isExercise);
    }

    /// -----------------------------------------------------------------------
    /// Internal functions
    /// -----------------------------------------------------------------------

    function _exercise(
        uint256 amount,
        address recipient,
        address option,
        bytes calldata params
    )
        internal
        virtual
        returns (
            uint256 paymentAmount,
            address data0,
            uint256 data1,
            uint256 data2 // misc data
        )
    {
        // skip if amount is zero
        if (amount == 0) return (0, address(0), 0, 0);

        // skip if option is not active
        if (!isExerciseContract[option])
            revert OptionsToken__NotExerciseContract();
        // transfer options tokens from msg.sender to address(0)
        // we transfer instead of burn because TokenAdmin cares about totalSupply
        // which we don't want to change in order to follow the emission schedule
        transfer(address(0x1), amount);

        // give rewards to recipient
        (paymentAmount, data0, data1, data2) = IExercise(option).exercise(
            msg.sender,
            amount,
            recipient,
            params
        );

        // emit event
        emit Exercise(msg.sender, recipient, amount, data0, data1, data2);
    }
}

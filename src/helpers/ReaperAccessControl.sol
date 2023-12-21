// SPDX-License-Identifier: BUSL-1.1

import "./ReaperMathUtils.sol";

pragma solidity ^0.8.0;

/**
 * A mixin to provide access control to a variety of roles. Designed to be compatible
 * with both upgradeable and non-upgradble contracts. HAS NO STORAGE.
 */
abstract contract ReaperAccessControl {
    using ReaperMathUtils for uint256;

    /**
     * @notice Checks cascading role privileges to ensure that caller has at least role {_role}.
     * Any higher privileged role should be able to perform all the functions of any lower privileged role.
     * This is accomplished using the {cascadingAccess} array that lists all roles from most privileged
     * to least privileged.
     * @param _role - The role in bytes from the keccak256 hash of the role name
     */
    function _atLeastRole(bytes32 _role) internal view {
        bytes32[] memory cascadingAccessRoles = _cascadingAccessRoles();
        uint256 numRoles = cascadingAccessRoles.length;
        bool specifiedRoleFound = false;
        bool senderHighestRoleFound = false;

        // {_role} must be found in the {cascadingAccessRoles} array.
        // Also, msg.sender's highest role index <= specified role index.
        for (uint256 i = 0; i < numRoles; i = i.uncheckedInc()) {
            if (
                !senderHighestRoleFound &&
                _hasRole(cascadingAccessRoles[i], msg.sender)
            ) {
                senderHighestRoleFound = true;
            }
            if (_role == cascadingAccessRoles[i]) {
                specifiedRoleFound = true;
                break;
            }
        }

        require(
            specifiedRoleFound && senderHighestRoleFound,
            "Unauthorized access"
        );
    }

    /**
     * @dev Returns an array of all the relevant roles arranged in descending order of privilege.
     *      Subclasses should override this to specify their unique roles arranged in the correct
     *      order, for example, [SUPER-ADMIN, ADMIN, GUARDIAN, STRATEGIST].
     */
    function _cascadingAccessRoles()
        internal
        view
        virtual
        returns (bytes32[] memory);

    /**
     * @dev Returns {true} if {_account} has been granted {_role}. Subclasses should override
     *      this to specify their unique role-checking criteria.
     */
    function _hasRole(
        bytes32 _role,
        address _account
    ) internal view virtual returns (bool);
}

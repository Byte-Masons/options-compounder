// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.0;

/**
 * @dev Full external interface for the Vault core contract - no external or public methods exist in the contract that
 * don't override one of these declarations.
 */
interface IVault {
    enum PoolSpecialization {
        GENERAL,
        MINIMAL_SWAP_INFO,
        TWO_TOKEN
    }

    /**
     * @dev Returns a Pool's contract address and specialization setting.
     */
    function getPool(
        bytes32 poolId
    ) external view returns (address, PoolSpecialization);
}

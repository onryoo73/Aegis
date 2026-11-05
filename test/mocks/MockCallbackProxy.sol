// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/**
 * @title MockCallbackProxy
 * @notice Local stand-in for Reactive Network's callback proxy on Unichain Sepolia.
 * @dev Reproduces the critical proxy behavior: the first 160 bits of the payload
 *      are replaced with the reactive contract address before the target call.
 */
contract MockCallbackProxy {
    mapping(address => uint256) internal _debts;

    uint256 public deliverCount;

    event CallbackDelivered(address indexed target, address indexed reactiveSender, bytes payload, bool success);

    function debt(address account_) external view returns (uint256) {
        return _debts[account_];
    }

    function setDebt(address account_, uint256 amount_) external {
        _debts[account_] = amount_;
    }

    function deliver(address target_, address reactiveSender_, bytes calldata payload_)
        external
        returns (bytes memory)
    {
        bytes memory patched = payload_;

        assembly {
            // `patched` points at the length slot; data starts at +32 and the
            // first argument (right after the 4-byte selector) starts at +36.
            let word := mload(add(patched, 36))
            // ABI-encoded addresses are right-aligned: keep the 12 zero padding
            // bytes, replace the low 160 bits with the reactive sender.
            word := or(and(word, 0xffffffffffffffffffffffff0000000000000000000000000000000000000000), reactiveSender_)
            mstore(add(patched, 36), word)
        }

        deliverCount += 1;
        (bool success, bytes memory returndata) = target_.call(patched);
        emit CallbackDelivered(target_, reactiveSender_, patched, success);

        if (!success) {
            assembly {
                revert(add(returndata, 32), mload(returndata))
            }
        }

        return returndata;
    }

    receive() external payable { }
}

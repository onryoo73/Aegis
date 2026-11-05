// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IReactive } from "@reactive/src/interfaces/IReactive.sol";
import { ISystemContract } from "@reactive/src/interfaces/ISystemContract.sol";

/**
 * @title MockSystemContract
 * @notice Local stand-in for Reactive Network's system contract.
 * @dev Tests deploy this at the canonical address 0x8888... using `deployCodeTo`
 *      so that `AbstractReactive` and `AbstractCallback` see the expected caller.
 */
contract MockSystemContract {
    struct Subscription {
        address subscriber;
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    Subscription[] internal _subscriptions;
    ISystemContract.CallbackConfiguration_V_1_0 internal _lastCallbackConfig;
    bool internal _hasCallback;
    mapping(address => uint256) internal _debts;

    uint256 public callbackCount;

    event Subscribed(
        address indexed subscriber,
        uint256 chainId,
        address contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    );
    event Unsubscribed(
        address indexed subscriber,
        uint256 chainId,
        address contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    );
    event CallbackRequest(
        uint256 indexed chainId,
        address indexed sender,
        address indexed recipient,
        ISystemContract.CallbackVersion version,
        bytes configuration
    );

    function subscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external {
        _subscriptions.push(
            Subscription({
                subscriber: msg.sender,
                chainId: chainId_,
                contractAddress: contract_,
                topic0: topic0_,
                topic1: topic1_,
                topic2: topic2_,
                topic3: topic3_
            })
        );

        emit Subscribed(msg.sender, chainId_, contract_, topic0_, topic1_, topic2_, topic3_);
    }

    function unsubscribe(
        uint256 chainId_,
        address contract_,
        uint256 topic0_,
        uint256 topic1_,
        uint256 topic2_,
        uint256 topic3_
    ) external {
        emit Unsubscribed(msg.sender, chainId_, contract_, topic0_, topic1_, topic2_, topic3_);
    }

    function requestCallbackV_1_0(ISystemContract.CallbackConfiguration_V_1_0 memory config_) external {
        _lastCallbackConfig = config_;
        _hasCallback = true;
        callbackCount += 1;

        emit CallbackRequest(
            config_.chainId, msg.sender, config_.recipient, ISystemContract.CallbackVersion.V_1_0, abi.encode(config_)
        );
    }

    function requestCallback(ISystemContract.CallbackVersion version_, bytes memory config_) external {
        callbackCount += 1;
        emit CallbackRequest(0, msg.sender, address(0), version_, config_);
    }

    function debt(address account_) external view returns (uint256) {
        return _debts[account_];
    }

    function setDebt(address account_, uint256 amount_) external {
        _debts[account_] = amount_;
    }

    function subscriptionCount() external view returns (uint256) {
        return _subscriptions.length;
    }

    function getSubscription(uint256 index_) external view returns (Subscription memory) {
        return _subscriptions[index_];
    }

    function hasCallback() external view returns (bool) {
        return _hasCallback;
    }

    function getLastCallback() external view returns (ISystemContract.CallbackConfiguration_V_1_0 memory) {
        return _lastCallbackConfig;
    }

    /// @notice Simulates the Reactive system invoking `react()` on a contract.
    function deliver(address target_, IReactive.LogRecord calldata log_) external {
        IReactive(payable(target_)).react(log_);
    }

    receive() external payable { }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title PriceOracle
/// @notice Origin-chain price feed on Base Sepolia emitting PriceUpdated events consumed by ReactiveVaultGuard.
contract PriceOracle {
    address public owner;
    mapping(address => bool) public authorizedUpdaters;
    mapping(address => uint256) public pricesE8;
    mapping(address => uint256) public lastUpdatedAt;

    event PriceUpdated(
        address indexed asset,
        uint256 oldPriceE8,
        uint256 newPriceE8,
        uint256 timestamp
    );
    event UpdaterSet(address indexed updater, bool authorized);

    error Unauthorized();
    error InvalidPrice();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyUpdater() {
        if (msg.sender != owner && !authorizedUpdaters[msg.sender]) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setUpdater(address updater, bool authorized) external onlyOwner {
        authorizedUpdaters[updater] = authorized;
        emit UpdaterSet(updater, authorized);
    }

    function setPrice(address asset, uint256 newPriceE8) external onlyUpdater {
        if (newPriceE8 == 0) revert InvalidPrice();
        uint256 oldPriceE8 = pricesE8[asset];
        pricesE8[asset] = newPriceE8;
        lastUpdatedAt[asset] = block.timestamp;
        emit PriceUpdated(asset, oldPriceE8, newPriceE8, block.timestamp);
    }
}

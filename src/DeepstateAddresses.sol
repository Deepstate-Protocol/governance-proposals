// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Canonical pre-Rewarder-V2 deployment recorded in the protocol documentation on August 16, 2026.
/// @dev Verify these constants against https://deepstate.sh/docs before every proposal submission. Rewarder V2
/// activation intentionally changes some ownership and role assertions; record an explicit post-activation baseline.
library DeepstateAddresses {
    string internal constant NETWORK = "Robinhood Chain";
    uint256 internal constant CHAIN_ID = 4_663;
    uint48 internal constant GOVERNANCE_START = 1_788_074_638;

    uint8 internal constant DEEP_DECIMALS = 18;
    uint8 internal constant STATE_DECIMALS = 18;
    uint8 internal constant USDG_DECIMALS = 6;
    uint8 internal constant NVDA_DECIMALS = 18;
    uint16 internal constant ROUTER_FEE_BPS = 10;

    address internal constant GOVERNOR = 0x3DC3b787EBDC78bf916f4e30195C61c764C111Ff;
    bytes32 internal constant GOVERNOR_CODEHASH = 0x72016f3b397262520f32391d64ecc34c6208f02570cfecac53d9ce9b2203eb31;
    address internal constant DEEP = 0x1DA24f6Bb623b9d1aFEae3F3146659A2662D6d27;
    bytes32 internal constant DEEP_CODEHASH = 0xbaa66790940277398fa140294409b82b1bfe357f6784dc431e133aba893977da;
    address internal constant STATE = 0xbfb7b3Ff3D498a559b946B836d26F0E168f273D5;
    bytes32 internal constant STATE_CODEHASH = 0x3bafdc526d98da599f5bef66d916b75d3031fe56a36e807d88122c7663a0a62d;
    address internal constant ROUTER = 0x6cf19308C22FC82ea620Fa0B3E94948d20f27B96;
    bytes32 internal constant ROUTER_CODEHASH = 0x287d53a803f8e488b46c74c73308554c77768e4f271f208632ab6283fa73caa3;
    address internal constant REWARDER = 0xE85ADBC03a6b52a2c9894c1BB525eC883ea156D7;
    bytes32 internal constant REWARDER_CODEHASH = 0xc78061023adf4f48ecbaab8e8a75080eaa8611b38ed2bf842cb07621245577cd;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    bytes32 internal constant NVDA_USDG_POOL_ID = 0x42819cadfbb25aab80543236e280fba4e61aa61e0b5b777541de54ae69da35e4;
}

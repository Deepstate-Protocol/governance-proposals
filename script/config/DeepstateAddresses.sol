// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Canonical pre-Rewarder-V2 deployment recorded in the protocol documentation on August 16, 2026.
/// @dev Verify these constants against https://deepstate.sh/docs before every proposal submission. Rewarder V2
/// activation intentionally changes some ownership and role assertions; record an explicit post-activation baseline.
library DeepstateAddresses {
    string internal constant NETWORK = "Robinhood Chain";
    uint256 internal constant CHAIN_ID = 4_663;
    uint48 internal constant GOVERNANCE_START = 1_788_074_638;

    // Release policy, not protocol-discovered values. Changing any value creates a different CREATE2 deployment.
    uint256 internal constant MINTER_LIVE_SUPPLY_CAP = 3_000_000_000e18;
    uint256 internal constant MINTER_GROSS_ISSUANCE_CAP = 3_000_000_000e18;
    uint256 internal constant FACTORY_LIFETIME_FUNDING_BUDGET = 1_000_000_000e18;
    uint256 internal constant MINIMUM_ACTIVATION_ISSUANCE_HEADROOM = 442_857_142_857_142_857_142_857_142;

    // Immutable configuration of the live predecessor Rewarder used by the one-time endowment snapshot and migration.
    uint96 internal constant LEGACY_REWARDER_SIDE_EMISSION_CAP = 500_000_000e18;
    uint32 internal constant LEGACY_REWARDER_EMISSION_DURATION = 34_128_000; // 395 days
    uint160 internal constant LEGACY_USDG_START_QUANTITY = 1e6;
    uint160 internal constant LEGACY_USDG_MAX_QUANTITY = 1_000_000e6;
    uint160 internal constant LEGACY_NVDA_START_QUANTITY = 1e18;
    uint160 internal constant LEGACY_NVDA_MAX_QUANTITY = 5_000e18;

    uint8 internal constant DEEP_DECIMALS = 18;
    uint8 internal constant STATE_DECIMALS = 18;
    uint8 internal constant USDG_DECIMALS = 6;
    uint8 internal constant NVDA_DECIMALS = 18;
    uint16 internal constant ROUTER_FEE_BPS = 10;

    address internal constant GOVERNOR = 0x3DC3b787EBDC78bf916f4e30195C61c764C111Ff;
    bytes32 internal constant GOVERNOR_CODEHASH = 0x72016f3b397262520f32391d64ecc34c6208f02570cfecac53d9ce9b2203eb31;
    address internal constant DEEP = 0x1DA24f6Bb623b9d1aFEae3F3146659A2662D6d27;
    bytes32 internal constant DEEP_CODEHASH = 0xbaa66790940277398fa140294409b82b1bfe357f6784dc431e133aba893977da;
    uint256 internal constant DEEP_DEPLOYMENT_BLOCK = 36_932_568;
    bytes32 internal constant DEEP_DEPLOYMENT_BLOCK_HASH =
        0x825b0a72b74ea8661868132676ce26372953f214a099db9794ece645e8bd53d4;
    address internal constant DEEP_DEPLOYER = 0xf2dE38643d0c35Bb7250E7c78133ce07333c75db;
    address internal constant STATE = 0xbfb7b3Ff3D498a559b946B836d26F0E168f273D5;
    bytes32 internal constant STATE_CODEHASH = 0x3bafdc526d98da599f5bef66d916b75d3031fe56a36e807d88122c7663a0a62d;
    address internal constant ROUTER = 0x6cf19308C22FC82ea620Fa0B3E94948d20f27B96;
    bytes32 internal constant ROUTER_CODEHASH = 0x287d53a803f8e488b46c74c73308554c77768e4f271f208632ab6283fa73caa3;
    address internal constant REWARDER = 0xE85ADBC03a6b52a2c9894c1BB525eC883ea156D7;
    bytes32 internal constant REWARDER_CODEHASH = 0xc78061023adf4f48ecbaab8e8a75080eaa8611b38ed2bf842cb07621245577cd;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    bytes32 internal constant USDG_CODEHASH = 0x864cc9ad53b338b82da1f7cab85ab0b3d5c8861acb422b6fec63cf36234f36a6;
    address internal constant USDG_IMPLEMENTATION = 0x68184C449E1a8f34fA18d289737129FD27B66f8F;
    bytes32 internal constant USDG_IMPLEMENTATION_CODEHASH =
        0x3a551ac5c744af57e68a1d1431ac403c0f516ffd7d224a75746aee11fc4f3baf;
    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    bytes32 internal constant NVDA_CODEHASH = 0x6c1fdd40002dcb440c7fff6a84171404d279ccb057803b65826f7546acd65630;
    address internal constant NVDA_BEACON = 0xe10b6f6B275de231345c20D14Ab812db62151b00;
    bytes32 internal constant NVDA_BEACON_CODEHASH = 0x8b465c0b53a2ba499566e9b4ca67d8c90ed6131743df806a570d156956a7e90e;
    address internal constant NVDA_IMPLEMENTATION = 0xb35490d6f9163DE4F80d88dc75c3516eb64C5aE2;
    bytes32 internal constant NVDA_IMPLEMENTATION_CODEHASH =
        0xdc07e86ee482f99641bdafb9a0d772846b167401e094d90a666b94dbdcd1eec7;
    bytes32 internal constant NVDA_USDG_POOL_ID = 0x42819cadfbb25aab80543236e280fba4e61aa61e0b5b777541de54ae69da35e4;

    // Deepstate Inc submits proposals through a 1-of-1 Safe. The owner is also the intended Governor proposer.
    address internal constant DEEPSTATE_INC_SAFE = 0x83fB2739abd9963c5341E4A176D93a7E5Ee73445;
    bytes32 internal constant DEEPSTATE_INC_SAFE_CODEHASH =
        0xd7d408ebcd99b2b70be43e20253d6d92a8ea8fab29bd3be7f55b10032331fb4c;
    address internal constant DEEPSTATE_INC_SAFE_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    bytes32 internal constant DEEPSTATE_INC_SAFE_SINGLETON_CODEHASH =
        0xb1f926978a0f44a2c0ec8fe822418ae969bd8c3f18d61e5103100339894f81ff;
    address internal constant DEEPSTATE_INC_SAFE_OWNER = 0x5F43Cd8B5Eead549de4444a644B4Cb425A4ea5b2;
    address internal constant PROPOSER = DEEPSTATE_INC_SAFE_OWNER;
    uint256 internal constant DEEPSTATE_INC_SAFE_THRESHOLD = 1;

    // Official Sablier Lockup v4 deployment for Robinhood Chain. The original vanity Comptroller was compromised;
    // Lockup is wired to this official replacement proxy. Pin the proxy implementation because it is upgradeable.
    address internal constant SABLIER_LOCKUP = 0x548129a58bC230549DF7F9e33f27E77F6779ff0f;
    bytes32 internal constant SABLIER_LOCKUP_CODEHASH =
        0x814be48f2bf951ff8ff6d59a551d7087376cb791f3d1f455ac82a82c22b2de12;
    uint256 internal constant SABLIER_LOCKUP_DEPLOYMENT_BLOCK = 10_420_411;
    address internal constant SABLIER_COMPTROLLER = 0x12d70713796A9460314C282c613DE307FdED1a36;
    bytes32 internal constant SABLIER_COMPTROLLER_CODEHASH =
        0xf76356484ac0ad9ffef49c8025506908355a417a99bfbaf3b216f029a8683ea4;
    address internal constant SABLIER_COMPTROLLER_IMPLEMENTATION = 0xdE834835d254CF5251e27c9B9eDA81632b9a6730;
    bytes32 internal constant SABLIER_COMPTROLLER_IMPLEMENTATION_CODEHASH =
        0xc5211d5df605d1fdc4c38436af79384daf89cbf7b6b39e1882b405c3bb04c107;
    address internal constant SABLIER_COMPTROLLER_ADMIN = 0xcB88fBf459000853F22a7296b23d163901BB385E;
    address internal constant SABLIER_COMPTROLLER_ORACLE = 0x0000000000000000000000000000000000000000;
    string internal constant SABLIER_COMPTROLLER_VERSION = "v1.1";
    uint256 internal constant SABLIER_LOCKUP_MIN_FEE_USD = 0;
    uint256 internal constant SABLIER_MAX_FEE_USD = 10_000_000_000;

    // Arachnid's canonical deterministic deployment proxy, used only after an explicit deployment confirmation.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes32 internal constant CREATE2_DEPLOYER_CODEHASH =
        0x2fa86add0aed31f33a762c9d88e807c475bd51d0f52bd0955754b2608f7e4989;

    // Deterministic Rewarder V2 system deployments. These addresses are fixed by the reviewed CREATE2 deployer,
    // salts, init code, constructor arguments, compiler settings, and pinned dependency revisions.
    address internal constant MINTER_CONTROLLER = 0xA2D743FE8387Ea6030F7aD2BdCa2A7556EA495B5;
    bytes32 internal constant MINTER_CONTROLLER_CODEHASH =
        0xaa7292db515a0de6a611bccd4f953a26e299c54adbad09920cb5630731d63dc5;
    address internal constant DGP001_BOOTSTRAP = 0x46f59ca750D4781b882a8F92BE11F0b23f537932;
    bytes32 internal constant DGP001_BOOTSTRAP_CODEHASH =
        0x5dbd6a010679b3dc1de4c62cb6cbfad824276ff75cbc783695fe748d1b332282;
    address internal constant V1_CONTROLLER = 0x8900cd1D03Aaa1F9d4B7649a268985E0C48B4476;
    bytes32 internal constant V1_CONTROLLER_CODEHASH =
        0x4a0cd3f52cc0439045246c716fef929520d7899c7e4cfae76878703bd0540fcc;
    address internal constant REWARDER_FACTORY = 0xFF9E7971aB6E7111BB2F0aDA57a8E2c1256c3f98;
    bytes32 internal constant REWARDER_FACTORY_CODEHASH =
        0x8839004510aeb49e9725d929193c8deb2fff5f0950b65fdd22c6fae4ded93049;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Fixed addresses Tremor deploys against. Sources: Uniswap v4-periphery broadcast logs and
///         Reactive's "Origins and destinations" docs, checked on-chain before use.
library Addresses {
    // Chain IDs
    uint256 internal constant BASE_SEPOLIA = 84532;
    uint256 internal constant UNICHAIN_SEPOLIA = 1301;
    uint256 internal constant LASNA = 5318007;

    // Uniswap v4 on Base Sepolia
    address internal constant BASE_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;
    address internal constant BASE_MODIFY_LIQUIDITY_ROUTER = 0x37429cD17Cb1454C34E7F50b09725202Fd533039;
    address internal constant BASE_SWAP_ROUTER = 0x8B5bcC363ddE2614281aD875bad385E0A785D3B9;

    // Uniswap v4 on Unichain Sepolia
    address internal constant UNI_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address internal constant UNI_MODIFY_LIQUIDITY_ROUTER = 0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB;
    address internal constant UNI_SWAP_ROUTER = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;

    // Reactive
    address internal constant UNI_CALLBACK_PROXY = 0x775c9B990ADe401060B78D0e98684eEf8d2466C1;
    address internal constant BASE_LREACT_FAUCET = 0x2afaFD298b23b62760711756088F75B7409f5967;

    // Deterministic CREATE2 deployer used by forge script
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Full-range ticks for tick spacings 30 and 60
    int24 internal constant MIN_TICK = -887220;
    int24 internal constant MAX_TICK = 887220;

    /// @notice Starting market price: 3,000 tUSD per tETH.
    uint256 internal constant START_PRICE_X18 = 3000e18;
}

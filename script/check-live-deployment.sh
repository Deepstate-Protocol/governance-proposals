#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDRESS_REGISTRY="$ROOT_DIR/src/DeepstateAddresses.sol"
RPC_URL="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com/}"
DEFAULT_ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$command_name" >&2
        exit 1
    fi
}

normalize_address() {
    cast to-check-sum-address "$1"
}

solidity_address() {
    local name="$1"
    local value
    value="$(sed -nE "s/.*constant ${name} = (0x[[:xdigit:]]{40});/\1/p" "$ADDRESS_REGISTRY")"
    if [[ -z "$value" ]]; then
        printf 'Unable to read %s from %s\n' "$name" "$ADDRESS_REGISTRY" >&2
        exit 1
    fi
    printf '%s\n' "$value"
}

solidity_uint() {
    local name="$1"
    local value
    value="$(sed -nE "s/.*constant ${name} = ([0-9_]+);/\1/p" "$ADDRESS_REGISTRY")"
    if [[ -z "$value" ]]; then
        printf 'Unable to read %s from %s\n' "$name" "$ADDRESS_REGISTRY" >&2
        exit 1
    fi
    printf '%s\n' "${value//_/}"
}

solidity_bytes32() {
    local name="$1"
    local value
    value="$(sed -nE "s/.*constant ${name} = (0x[[:xdigit:]]{64});/\1/p" "$ADDRESS_REGISTRY")"
    if [[ -z "$value" ]]; then
        printf 'Unable to read %s from %s\n' "$name" "$ADDRESS_REGISTRY" >&2
        exit 1
    fi
    printf '%s\n' "$value"
}

rpc_call() {
    cast call "$@" --rpc-url "$RPC_URL" --block "$SNAPSHOT_BLOCK"
}

rpc_uint() {
    local value
    value="$(rpc_call "$@")"
    printf '%s\n' "${value%% *}"
}

require_address() {
    local label="$1"
    local actual
    local expected
    actual="$(normalize_address "$2")"
    expected="$(normalize_address "$3")"
    if [[ "$actual" != "$expected" ]]; then
        printf '%s mismatch: expected %s, received %s\n' "$label" "$expected" "$actual" >&2
        exit 1
    fi
}

require_command cast

EXPECTED_CHAIN_ID="$(solidity_uint CHAIN_ID)"
EXPECTED_GOVERNANCE_START="$(solidity_uint GOVERNANCE_START)"
EXPECTED_GOVERNOR_CODEHASH="$(solidity_bytes32 GOVERNOR_CODEHASH)"
EXPECTED_DEEP_CODEHASH="$(solidity_bytes32 DEEP_CODEHASH)"
EXPECTED_STATE_CODEHASH="$(solidity_bytes32 STATE_CODEHASH)"
EXPECTED_ROUTER_CODEHASH="$(solidity_bytes32 ROUTER_CODEHASH)"
EXPECTED_REWARDER_CODEHASH="$(solidity_bytes32 REWARDER_CODEHASH)"
EXPECTED_ROUTER_FEE_BPS="$(solidity_uint ROUTER_FEE_BPS)"
EXPECTED_NVDA_USDG_POOL_ID="$(solidity_bytes32 NVDA_USDG_POOL_ID)"
GOVERNOR="$(solidity_address GOVERNOR)"
DEEP="$(solidity_address DEEP)"
STATE="$(solidity_address STATE)"
ROUTER="$(solidity_address ROUTER)"
REWARDER="$(solidity_address REWARDER)"
USDG="$(solidity_address USDG)"
NVDA="$(solidity_address NVDA)"

chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
    printf 'Chain ID mismatch: expected %s, received %s\n' "$EXPECTED_CHAIN_ID" "$chain_id" >&2
    exit 1
fi

SNAPSHOT_BLOCK="$(cast block-number --rpc-url "$RPC_URL")"
SNAPSHOT_BLOCK_HASH="$(cast block "$SNAPSHOT_BLOCK" --field hash --rpc-url "$RPC_URL")"

for contract_address in "$GOVERNOR" "$DEEP" "$STATE" "$ROUTER" "$REWARDER" "$USDG" "$NVDA"; do
    if [[ "$(cast code "$contract_address" --rpc-url "$RPC_URL" --block "$SNAPSHOT_BLOCK")" == "0x" ]]; then
        printf 'No contract code at %s\n' "$contract_address" >&2
        exit 1
    fi
done

for codehash_spec in \
    "Governor:$GOVERNOR:$EXPECTED_GOVERNOR_CODEHASH" \
    "DEEP:$DEEP:$EXPECTED_DEEP_CODEHASH" \
    "STATE:$STATE:$EXPECTED_STATE_CODEHASH" \
    "Router:$ROUTER:$EXPECTED_ROUTER_CODEHASH" \
    "Rewarder:$REWARDER:$EXPECTED_REWARDER_CODEHASH"; do
    codehash_label="${codehash_spec%%:*}"
    codehash_rest="${codehash_spec#*:}"
    codehash_address="${codehash_rest%%:*}"
    expected_codehash="${codehash_rest##*:}"
    actual_codehash="$(cast codehash "$codehash_address" --rpc-url "$RPC_URL" --block "$SNAPSHOT_BLOCK")"
    if [[ "$actual_codehash" != "$expected_codehash" ]]; then
        printf '%s code hash mismatch: expected %s, received %s\n' \
            "$codehash_label" "$expected_codehash" "$actual_codehash" >&2
        exit 1
    fi
done

governor_name="$(rpc_call "$GOVERNOR" 'name()(string)')"
if [[ "$governor_name" != '"DeepstateGovernor"' ]]; then
    printf 'Governor name mismatch: %s\n' "$governor_name" >&2
    exit 1
fi

require_address \
    "Governor voting token" \
    "$(rpc_call "$GOVERNOR" 'token()(address)')" \
    "$STATE"
require_address "STATE owner" "$(rpc_call "$STATE" 'owner()(address)')" "$GOVERNOR"
require_address "Router owner" "$(rpc_call "$ROUTER" 'owner()(address)')" "$GOVERNOR"
require_address "Rewarder owner" "$(rpc_call "$REWARDER" 'owner()(address)')" "$GOVERNOR"

router_fee_config="$(rpc_call "$ROUTER" 'feeConfig()(address,uint16)')"
router_fee_recipient="$(sed -n '1p' <<<"$router_fee_config")"
router_fee_bps="$(sed -n '2p' <<<"$router_fee_config")"
router_fee_bps="${router_fee_bps%% *}"
require_address "Router fee recipient" "$router_fee_recipient" "$STATE"
if [[ "$router_fee_bps" != "$EXPECTED_ROUTER_FEE_BPS" ]]; then
    printf 'Router fee mismatch: expected %s bps, received %s bps\n' \
        "$EXPECTED_ROUTER_FEE_BPS" "$router_fee_bps" >&2
    exit 1
fi

require_address \
    "NVDA/USDG pool hook" \
    "$(rpc_call "$ROUTER" 'poolHook(bytes32)(address)' "$EXPECTED_NVDA_USDG_POOL_ID")" \
    "$REWARDER"

governor_is_deep_admin="$(rpc_call "$DEEP" 'hasRole(bytes32,address)(bool)' "$DEFAULT_ADMIN_ROLE" "$GOVERNOR")"
if [[ "$governor_is_deep_admin" != "true" ]]; then
    printf 'Governor does not hold the DEEP default admin role\n' >&2
    exit 1
fi

default_admin_count="$(rpc_uint "$DEEP" 'defaultAdminCount()(uint256)')"
if [[ "$default_admin_count" != "1" ]]; then
    printf 'Unexpected DEEP default admin count: %s\n' "$default_admin_count" >&2
    exit 1
fi

minter_role="$(rpc_call "$DEEP" 'MINTER_ROLE()(bytes32)')"
for known_non_minter in "$GOVERNOR" "$REWARDER"; do
    if [[ "$(rpc_call "$DEEP" 'hasRole(bytes32,address)(bool)' "$minter_role" "$known_non_minter")" != "false" ]]; then
        printf 'Unexpected DEEP token-level minter: %s\n' "$known_non_minter" >&2
        exit 1
    fi
done

for token_spec in \
    "$DEEP:DEEP_DECIMALS" \
    "$STATE:STATE_DECIMALS" \
    "$USDG:USDG_DECIMALS" \
    "$NVDA:NVDA_DECIMALS"; do
    token_address="${token_spec%%:*}"
    decimals_name="${token_spec##*:}"
    expected_decimals="$(solidity_uint "$decimals_name")"
    actual_decimals="$(rpc_uint "$token_address" 'decimals()(uint8)')"
    if [[ "$actual_decimals" != "$expected_decimals" ]]; then
        printf '%s mismatch: expected %s, received %s\n' \
            "$decimals_name" "$expected_decimals" "$actual_decimals" >&2
        exit 1
    fi
done

governance_start="$(rpc_uint "$GOVERNOR" 'governanceStart()(uint48)')"
if [[ "$governance_start" != "$EXPECTED_GOVERNANCE_START" ]]; then
    printf 'Governance start mismatch: expected %s, received %s\n' \
        "$EXPECTED_GOVERNANCE_START" "$governance_start" >&2
    exit 1
fi

clock_mode="$(rpc_call "$GOVERNOR" 'CLOCK_MODE()(string)')"
if [[ "$clock_mode" != '"mode=timestamp"' ]]; then
    printf 'Unexpected Governor clock mode: %s\n' "$clock_mode" >&2
    exit 1
fi

counting_mode="$(rpc_call "$GOVERNOR" 'COUNTING_MODE()(string)')"
if [[ "$counting_mode" != '"support=bravo&quorum=for,abstain"' ]]; then
    printf 'Unexpected Governor counting mode: %s\n' "$counting_mode" >&2
    exit 1
fi

if [[ "$(rpc_call "$GOVERNOR" 'proposalNeedsQueuing(uint256)(bool)' 0)" != "false" ]]; then
    printf 'Governor unexpectedly requires proposal queuing\n' >&2
    exit 1
fi

current_clock="$(rpc_uint "$GOVERNOR" 'clock()(uint48)')"
if (( current_clock < governance_start )); then
    governance_status="not open until 2026-08-30T07:23:58Z"
else
    governance_status="open"
fi

printf 'Deepstate live pre-activation deployment verified\n'
printf '  snapshot block: %s\n' "$SNAPSHOT_BLOCK"
printf '  snapshot hash: %s\n' "$SNAPSHOT_BLOCK_HASH"
printf '  chain ID: %s\n' "$chain_id"
printf '  Governor: %s\n' "$GOVERNOR"
printf '  STATE: %s\n' "$STATE"
printf '  Router fee: %s bps to %s\n' "$router_fee_bps" "$STATE"
printf '  NVDA/USDG hook: %s\n' "$REWARDER"
printf '  governance start: %s (2026-08-30T07:23:58Z)\n' "$governance_start"
printf '  governance status at snapshot: %s\n' "$governance_status"
printf '  proposal threshold: %s\n' "$(rpc_uint "$GOVERNOR" 'proposalThreshold()(uint256)')"
printf '  voting delay: %s seconds\n' "$(rpc_uint "$GOVERNOR" 'votingDelay()(uint256)')"
printf '  voting period: %s seconds\n' "$(rpc_uint "$GOVERNOR" 'votingPeriod()(uint256)')"
printf '  late-quorum extension: %s seconds\n' "$(rpc_uint "$GOVERNOR" 'lateQuorumVoteExtension()(uint48)')"
printf '  quorum numerator: %s/100\n' "$(rpc_uint "$GOVERNOR" 'quorumNumerator()(uint256)')"

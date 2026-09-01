#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDRESS_REGISTRY="$ROOT_DIR/script/config/DeepstateAddresses.sol"
RPC_URL="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com/}"
DEFAULT_ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
ZERO_ADDRESS=0x0000000000000000000000000000000000000000
SAFE_MODULES_SENTINEL=0x0000000000000000000000000000000000000001
ERC1967_IMPLEMENTATION_SLOT=0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
SABLIER_PROTOCOL_LOCKUP=2

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

lowercase() {
    tr '[:upper:]' '[:lower:]' <<<"$1"
}

decimal_greater_than_or_equal() {
    local left="${1#${1%%[!0]*}}"
    local right="${2#${2%%[!0]*}}"
    left="${left:-0}"
    right="${right:-0}"
    if (( ${#left} != ${#right} )); then
        (( ${#left} > ${#right} ))
        return
    fi
    [[ "$left" == "$right" || "$left" > "$right" ]]
}

decimal_subtract() {
    local value="${1#${1%%[!0]*}}"
    local subtrahend="${2#${2%%[!0]*}}"
    local borrow=0
    local result=""
    local index
    local subtrahend_index
    local digit
    local subtrahend_digit
    local difference
    value="${value:-0}"
    subtrahend="${subtrahend:-0}"
    if ! decimal_greater_than_or_equal "$value" "$subtrahend"; then
        printf 'Cannot subtract decimal value %s from %s\n' "$subtrahend" "$value" >&2
        exit 1
    fi
    subtrahend_index=$((${#subtrahend} - 1))
    for ((index = ${#value} - 1; index >= 0; --index)); do
        digit="${value:index:1}"
        subtrahend_digit=0
        if (( subtrahend_index >= 0 )); then
            subtrahend_digit="${subtrahend:subtrahend_index:1}"
            ((subtrahend_index -= 1)) || true
        fi
        difference=$((10#$digit - 10#$subtrahend_digit - borrow))
        if (( difference < 0 )); then
            difference=$((difference + 10))
            borrow=1
        else
            borrow=0
        fi
        result="${difference}${result}"
    done
    if (( borrow != 0 )); then
        printf 'Cannot subtract from decimal value %s\n' "$value" >&2
        exit 1
    fi
    result="${result#${result%%[!0]*}}"
    printf '%s\n' "${result:-0}"
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
    local coefficient
    local exponent
    value="$(sed -nE "s/.*constant ${name} = ([0-9_]+(e[0-9_]+)?);.*/\1/p" "$ADDRESS_REGISTRY")"
    if [[ -z "$value" ]]; then
        printf 'Unable to read %s from %s\n' "$name" "$ADDRESS_REGISTRY" >&2
        exit 1
    fi
    value="${value//_/}"
    if [[ "$value" == *e* ]]; then
        coefficient="${value%%e*}"
        exponent="${value##*e}"
        printf '%s' "$coefficient"
        printf '%0*d\n' "$exponent" 0
        return
    fi
    printf '%s\n' "$value"
}

solidity_bytes32() {
    local name="$1"
    local value
    value="$(
        sed -nE "/constant ${name} =/ {
            s/.*= (0x[[:xdigit:]]{64});/\1/p
            n
            s/[[:space:]]*(0x[[:xdigit:]]{64});/\1/p
        }" "$ADDRESS_REGISTRY"
    )"
    if [[ -z "$value" ]]; then
        printf 'Unable to read %s from %s\n' "$name" "$ADDRESS_REGISTRY" >&2
        exit 1
    fi
    printf '%s\n' "$value"
}

solidity_string() {
    local name="$1"
    local value
    value="$(sed -nE "s/.*constant ${name} = \"([^\"]+)\";/\1/p" "$ADDRESS_REGISTRY")"
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

require_distinct_address() {
    local label="$1"
    local actual
    local forbidden
    actual="$(normalize_address "$2")"
    forbidden="$(normalize_address "$3")"
    if [[ "$actual" == "$forbidden" ]]; then
        printf '%s must not be %s\n' "$label" "$forbidden" >&2
        exit 1
    fi
}

require_uint() {
    local label="$1"
    local actual="$2"
    local expected="$3"
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
EXPECTED_USDG_CODEHASH="$(solidity_bytes32 USDG_CODEHASH)"
EXPECTED_USDG_IMPLEMENTATION_CODEHASH="$(solidity_bytes32 USDG_IMPLEMENTATION_CODEHASH)"
EXPECTED_NVDA_CODEHASH="$(solidity_bytes32 NVDA_CODEHASH)"
EXPECTED_NVDA_BEACON_CODEHASH="$(solidity_bytes32 NVDA_BEACON_CODEHASH)"
EXPECTED_NVDA_IMPLEMENTATION_CODEHASH="$(solidity_bytes32 NVDA_IMPLEMENTATION_CODEHASH)"
EXPECTED_SABLIER_LOCKUP_CODEHASH="$(solidity_bytes32 SABLIER_LOCKUP_CODEHASH)"
EXPECTED_SABLIER_COMPTROLLER_CODEHASH="$(solidity_bytes32 SABLIER_COMPTROLLER_CODEHASH)"
EXPECTED_SABLIER_COMPTROLLER_IMPLEMENTATION_CODEHASH="$(solidity_bytes32 SABLIER_COMPTROLLER_IMPLEMENTATION_CODEHASH)"
EXPECTED_SAFE_CODEHASH="$(solidity_bytes32 DEEPSTATE_INC_SAFE_CODEHASH)"
EXPECTED_SAFE_SINGLETON_CODEHASH="$(solidity_bytes32 DEEPSTATE_INC_SAFE_SINGLETON_CODEHASH)"
EXPECTED_CREATE2_DEPLOYER_CODEHASH="$(solidity_bytes32 CREATE2_DEPLOYER_CODEHASH)"
EXPECTED_ROUTER_FEE_BPS="$(solidity_uint ROUTER_FEE_BPS)"
EXPECTED_NVDA_USDG_POOL_ID="$(solidity_bytes32 NVDA_USDG_POOL_ID)"
EXPECTED_SAFE_THRESHOLD="$(solidity_uint DEEPSTATE_INC_SAFE_THRESHOLD)"
EXPECTED_SABLIER_LOCKUP_MIN_FEE_USD="$(solidity_uint SABLIER_LOCKUP_MIN_FEE_USD)"
EXPECTED_SABLIER_MAX_FEE_USD="$(solidity_uint SABLIER_MAX_FEE_USD)"
EXPECTED_SABLIER_COMPTROLLER_VERSION="$(solidity_string SABLIER_COMPTROLLER_VERSION)"
EXPECTED_MINTER_MAX_SUPPLY="$(solidity_uint MINTER_MAX_SUPPLY)"
EXPECTED_MINIMUM_ACTIVATION_ISSUANCE_HEADROOM="$(solidity_uint MINIMUM_ACTIVATION_ISSUANCE_HEADROOM)"
EXPECTED_LEGACY_REWARDER_SIDE_EMISSION_CAP="$(solidity_uint LEGACY_REWARDER_SIDE_EMISSION_CAP)"
EXPECTED_LEGACY_REWARDER_EMISSION_DURATION="$(solidity_uint LEGACY_REWARDER_EMISSION_DURATION)"
EXPECTED_LEGACY_USDG_START_QUANTITY="$(solidity_uint LEGACY_USDG_START_QUANTITY)"
EXPECTED_LEGACY_USDG_MAX_QUANTITY="$(solidity_uint LEGACY_USDG_MAX_QUANTITY)"
EXPECTED_LEGACY_NVDA_START_QUANTITY="$(solidity_uint LEGACY_NVDA_START_QUANTITY)"
EXPECTED_LEGACY_NVDA_MAX_QUANTITY="$(solidity_uint LEGACY_NVDA_MAX_QUANTITY)"
GOVERNOR="$(solidity_address GOVERNOR)"
DEEP="$(solidity_address DEEP)"
STATE="$(solidity_address STATE)"
ROUTER="$(solidity_address ROUTER)"
REWARDER="$(solidity_address REWARDER)"
USDG="$(solidity_address USDG)"
USDG_IMPLEMENTATION="$(solidity_address USDG_IMPLEMENTATION)"
NVDA="$(solidity_address NVDA)"
NVDA_BEACON="$(solidity_address NVDA_BEACON)"
NVDA_IMPLEMENTATION="$(solidity_address NVDA_IMPLEMENTATION)"
DEEPSTATE_INC_SAFE="$(solidity_address DEEPSTATE_INC_SAFE)"
DEEPSTATE_INC_SAFE_OWNER="$(solidity_address DEEPSTATE_INC_SAFE_OWNER)"
DEEPSTATE_INC_SAFE_SINGLETON="$(solidity_address DEEPSTATE_INC_SAFE_SINGLETON)"
PROPOSER="$(solidity_address DEEPSTATE_INC_SAFE_OWNER)"
SABLIER_LOCKUP="$(solidity_address SABLIER_LOCKUP)"
SABLIER_COMPTROLLER="$(solidity_address SABLIER_COMPTROLLER)"
SABLIER_COMPTROLLER_IMPLEMENTATION="$(solidity_address SABLIER_COMPTROLLER_IMPLEMENTATION)"
SABLIER_COMPTROLLER_ADMIN="$(solidity_address SABLIER_COMPTROLLER_ADMIN)"
CREATE2_DEPLOYER="$(solidity_address CREATE2_DEPLOYER)"

chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
    printf 'Chain ID mismatch: expected %s, received %s\n' "$EXPECTED_CHAIN_ID" "$chain_id" >&2
    exit 1
fi

SNAPSHOT_BLOCK="$(cast block-number --rpc-url "$RPC_URL")"
SNAPSHOT_BLOCK_HASH="$(cast block "$SNAPSHOT_BLOCK" --field hash --rpc-url "$RPC_URL")"

for contract_address in \
    "$GOVERNOR" \
    "$DEEP" \
    "$STATE" \
    "$ROUTER" \
    "$REWARDER" \
    "$USDG" \
    "$USDG_IMPLEMENTATION" \
    "$NVDA" \
    "$NVDA_BEACON" \
    "$NVDA_IMPLEMENTATION" \
    "$DEEPSTATE_INC_SAFE" \
    "$DEEPSTATE_INC_SAFE_SINGLETON" \
    "$SABLIER_LOCKUP" \
    "$SABLIER_COMPTROLLER" \
    "$SABLIER_COMPTROLLER_IMPLEMENTATION" \
    "$CREATE2_DEPLOYER"; do
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
    "Rewarder:$REWARDER:$EXPECTED_REWARDER_CODEHASH" \
    "USDG:$USDG:$EXPECTED_USDG_CODEHASH" \
    "USDG implementation:$USDG_IMPLEMENTATION:$EXPECTED_USDG_IMPLEMENTATION_CODEHASH" \
    "NVDA:$NVDA:$EXPECTED_NVDA_CODEHASH" \
    "NVDA beacon:$NVDA_BEACON:$EXPECTED_NVDA_BEACON_CODEHASH" \
    "NVDA implementation:$NVDA_IMPLEMENTATION:$EXPECTED_NVDA_IMPLEMENTATION_CODEHASH" \
    "Deepstate Inc Safe:$DEEPSTATE_INC_SAFE:$EXPECTED_SAFE_CODEHASH" \
    "Deepstate Inc Safe singleton:$DEEPSTATE_INC_SAFE_SINGLETON:$EXPECTED_SAFE_SINGLETON_CODEHASH" \
    "Sablier Lockup:$SABLIER_LOCKUP:$EXPECTED_SABLIER_LOCKUP_CODEHASH" \
    "Sablier Comptroller:$SABLIER_COMPTROLLER:$EXPECTED_SABLIER_COMPTROLLER_CODEHASH" \
    "Sablier Comptroller implementation:$SABLIER_COMPTROLLER_IMPLEMENTATION:$EXPECTED_SABLIER_COMPTROLLER_IMPLEMENTATION_CODEHASH" \
    "CREATE2 deployer:$CREATE2_DEPLOYER:$EXPECTED_CREATE2_DEPLOYER_CODEHASH"; do
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

usdg_implementation_word="$(
    cast storage "$USDG" "$ERC1967_IMPLEMENTATION_SLOT" --rpc-url "$RPC_URL" --block "$SNAPSHOT_BLOCK"
)"
require_address "USDG ERC-1967 implementation" "0x${usdg_implementation_word: -40}" "$USDG_IMPLEMENTATION"
require_address \
    "NVDA beacon implementation" \
    "$(rpc_call "$NVDA_BEACON" 'implementation()(address)')" \
    "$NVDA_IMPLEMENTATION"

require_address \
    "Sablier Lockup Comptroller" \
    "$(rpc_call "$SABLIER_LOCKUP" 'comptroller()(address)')" \
    "$SABLIER_COMPTROLLER"
require_distinct_address \
    "Sablier Lockup native token" \
    "$(rpc_call "$SABLIER_LOCKUP" 'nativeToken()(address)')" \
    "$DEEP"

deep_total_supply="$(rpc_uint "$DEEP" 'totalSupply()(uint256)')"
maximum_supply_with_minimum_headroom="$(
    decimal_subtract "$EXPECTED_MINTER_MAX_SUPPLY" "$EXPECTED_MINIMUM_ACTIVATION_ISSUANCE_HEADROOM"
)"
if ! decimal_greater_than_or_equal "$maximum_supply_with_minimum_headroom" "$deep_total_supply"; then
    printf 'DEEP supply leaves less than the required %s base-unit activation headroom: supply %s, maximum supply %s\n' \
        "$EXPECTED_MINIMUM_ACTIVATION_ISSUANCE_HEADROOM" "$deep_total_supply" \
        "$EXPECTED_MINTER_MAX_SUPPLY" >&2
    exit 1
fi

comptroller_implementation_word="$(
    cast storage "$SABLIER_COMPTROLLER" "$ERC1967_IMPLEMENTATION_SLOT" \
        --rpc-url "$RPC_URL" --block "$SNAPSHOT_BLOCK"
)"
require_address \
    "Sablier Comptroller ERC-1967 implementation" \
    "0x${comptroller_implementation_word: -40}" \
    "$SABLIER_COMPTROLLER_IMPLEMENTATION"

comptroller_version="$(rpc_call "$SABLIER_COMPTROLLER" 'VERSION()(string)')"
if [[ "$comptroller_version" != "\"$EXPECTED_SABLIER_COMPTROLLER_VERSION\"" ]]; then
    printf 'Sablier Comptroller version mismatch: expected %s, received %s\n' \
        "$EXPECTED_SABLIER_COMPTROLLER_VERSION" "$comptroller_version" >&2
    exit 1
fi
require_address \
    "Sablier Comptroller admin" \
    "$(rpc_call "$SABLIER_COMPTROLLER" 'admin()(address)')" \
    "$SABLIER_COMPTROLLER_ADMIN"
require_address \
    "Sablier Comptroller oracle" \
    "$(rpc_call "$SABLIER_COMPTROLLER" 'oracle()(address)')" \
    "$ZERO_ADDRESS"

sablier_max_fee_usd="$(rpc_uint "$SABLIER_COMPTROLLER" 'MAX_FEE_USD()(uint256)')"
if [[ "$sablier_max_fee_usd" != "$EXPECTED_SABLIER_MAX_FEE_USD" ]]; then
    printf 'Sablier maximum USD fee mismatch: expected %s, received %s\n' \
        "$EXPECTED_SABLIER_MAX_FEE_USD" "$sablier_max_fee_usd" >&2
    exit 1
fi
sablier_lockup_min_fee_usd="$(
    rpc_uint "$SABLIER_COMPTROLLER" 'getMinFeeUSD(uint8)(uint256)' "$SABLIER_PROTOCOL_LOCKUP"
)"
if [[ "$sablier_lockup_min_fee_usd" != "$EXPECTED_SABLIER_LOCKUP_MIN_FEE_USD" ]]; then
    printf 'Sablier Lockup minimum USD fee mismatch: expected %s, received %s\n' \
        "$EXPECTED_SABLIER_LOCKUP_MIN_FEE_USD" "$sablier_lockup_min_fee_usd" >&2
    exit 1
fi
sablier_lockup_min_fee_wei="$(
    rpc_uint "$SABLIER_COMPTROLLER" 'calculateMinFeeWei(uint8)(uint256)' "$SABLIER_PROTOCOL_LOCKUP"
)"
if [[ "$sablier_lockup_min_fee_wei" != "0" ]]; then
    printf 'Sablier Lockup currently requires a nonzero native-token fee: %s wei\n' \
        "$sablier_lockup_min_fee_wei" >&2
    exit 1
fi

safe_singleton_word="$(cast storage "$DEEPSTATE_INC_SAFE" 0 --rpc-url "$RPC_URL" --block "$SNAPSHOT_BLOCK")"
require_address \
    "Deepstate Inc Safe singleton" \
    "0x${safe_singleton_word: -40}" \
    "$DEEPSTATE_INC_SAFE_SINGLETON"

safe_owners="$(rpc_call "$DEEPSTATE_INC_SAFE" 'getOwners()(address[])')"
expected_safe_owners="[$DEEPSTATE_INC_SAFE_OWNER]"
if [[ "$(lowercase "$safe_owners")" != "$(lowercase "$expected_safe_owners")" ]]; then
    printf 'Deepstate Inc Safe owner set mismatch: expected %s, received %s\n' \
        "$expected_safe_owners" "$safe_owners" >&2
    exit 1
fi
safe_threshold="$(rpc_uint "$DEEPSTATE_INC_SAFE" 'getThreshold()(uint256)')"
if [[ "$safe_threshold" != "$EXPECTED_SAFE_THRESHOLD" ]]; then
    printf 'Deepstate Inc Safe threshold mismatch: expected %s, received %s\n' \
        "$EXPECTED_SAFE_THRESHOLD" "$safe_threshold" >&2
    exit 1
fi
safe_modules="$(
    rpc_call "$DEEPSTATE_INC_SAFE" 'getModulesPaginated(address,uint256)(address[],address)' \
        "$SAFE_MODULES_SENTINEL" 100
)"
safe_module_list="$(sed -n '1p' <<<"$safe_modules")"
safe_next_module="$(sed -n '2p' <<<"$safe_modules")"
if [[ "$safe_module_list" != "[]" ]]; then
    printf 'Deepstate Inc Safe unexpectedly has enabled modules: %s\n' "$safe_module_list" >&2
    exit 1
fi
require_address "Deepstate Inc Safe module sentinel" "$safe_next_module" "$SAFE_MODULES_SENTINEL"
if [[ "$(cast code "$DEEPSTATE_INC_SAFE_OWNER" --rpc-url "$RPC_URL" --block "$SNAPSHOT_BLOCK")" != "0x" ]]; then
    printf 'Deepstate Inc Safe sole owner/proposer is no longer an EOA: %s\n' "$DEEPSTATE_INC_SAFE_OWNER" >&2
    exit 1
fi

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
require_address "Legacy Rewarder Router" "$(rpc_call "$REWARDER" 'deepstate()(address)')" "$ROUTER"
require_address "Legacy Rewarder reward token" "$(rpc_call "$REWARDER" 'rewardToken()(address)')" "$DEEP"
require_address "Legacy Rewarder token0" "$(rpc_call "$REWARDER" 'token0()(address)')" "$USDG"
require_address "Legacy Rewarder token1" "$(rpc_call "$REWARDER" 'token1()(address)')" "$NVDA"

legacy_rewarder_pool_id="$(rpc_call "$REWARDER" 'poolId()(bytes32)')"
if [[ "$legacy_rewarder_pool_id" != "$EXPECTED_NVDA_USDG_POOL_ID" ]]; then
    printf 'Legacy Rewarder pool ID mismatch: expected %s, received %s\n' \
        "$EXPECTED_NVDA_USDG_POOL_ID" "$legacy_rewarder_pool_id" >&2
    exit 1
fi
require_uint \
    "Legacy Rewarder side emission cap" \
    "$(rpc_uint "$REWARDER" 'sideEmissionCap()(uint96)')" \
    "$EXPECTED_LEGACY_REWARDER_SIDE_EMISSION_CAP"
require_uint \
    "Legacy Rewarder emission duration" \
    "$(rpc_uint "$REWARDER" 'emissionDuration()(uint32)')" \
    "$EXPECTED_LEGACY_REWARDER_EMISSION_DURATION"
require_uint \
    "Legacy Rewarder USDG start quantity" \
    "$(rpc_uint "$REWARDER" 'token0StartQuantity()(uint160)')" \
    "$EXPECTED_LEGACY_USDG_START_QUANTITY"
require_uint \
    "Legacy Rewarder USDG maximum quantity" \
    "$(rpc_uint "$REWARDER" 'token0MaxQuantity()(uint160)')" \
    "$EXPECTED_LEGACY_USDG_MAX_QUANTITY"
require_uint \
    "Legacy Rewarder NVDA start quantity" \
    "$(rpc_uint "$REWARDER" 'token1StartQuantity()(uint160)')" \
    "$EXPECTED_LEGACY_NVDA_START_QUANTITY"
require_uint \
    "Legacy Rewarder NVDA maximum quantity" \
    "$(rpc_uint "$REWARDER" 'token1MaxQuantity()(uint160)')" \
    "$EXPECTED_LEGACY_NVDA_MAX_QUANTITY"

legacy_usdg_total_accrued="$(rpc_uint "$REWARDER" 'totalAccrued(address)(uint96)' "$USDG")"
legacy_nvda_total_accrued="$(rpc_uint "$REWARDER" 'totalAccrued(address)(uint96)' "$NVDA")"
if ! decimal_greater_than_or_equal "$EXPECTED_LEGACY_REWARDER_SIDE_EMISSION_CAP" "$legacy_usdg_total_accrued"; then
    printf 'Legacy Rewarder USDG accrued amount exceeds its side cap: %s > %s\n' \
        "$legacy_usdg_total_accrued" "$EXPECTED_LEGACY_REWARDER_SIDE_EMISSION_CAP" >&2
    exit 1
fi
if ! decimal_greater_than_or_equal "$EXPECTED_LEGACY_REWARDER_SIDE_EMISSION_CAP" "$legacy_nvda_total_accrued"; then
    printf 'Legacy Rewarder NVDA accrued amount exceeds its side cap: %s > %s\n' \
        "$legacy_nvda_total_accrued" "$EXPECTED_LEGACY_REWARDER_SIDE_EMISSION_CAP" >&2
    exit 1
fi

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

proposal_threshold="$(rpc_uint "$GOVERNOR" 'proposalThreshold()(uint256)')"
proposer_votes="$(rpc_uint "$GOVERNOR" 'getVotes(address,uint256)(uint256)' "$PROPOSER" "$((current_clock - 1))")"
if ! decimal_greater_than_or_equal "$proposer_votes" "$proposal_threshold"; then
    printf 'Configured proposer has insufficient delegated votes: %s votes, %s required\n' \
        "$proposer_votes" "$proposal_threshold" >&2
    exit 1
fi

ROBINHOOD_RPC_URL="$RPC_URL" bash "$ROOT_DIR/script/check-deep-role-history.sh" "$SNAPSHOT_BLOCK"

printf 'Deepstate live pre-activation deployment verified\n'
printf '  snapshot block: %s\n' "$SNAPSHOT_BLOCK"
printf '  snapshot hash: %s\n' "$SNAPSHOT_BLOCK_HASH"
printf '  chain ID: %s\n' "$chain_id"
printf '  Governor: %s\n' "$GOVERNOR"
printf '  STATE: %s\n' "$STATE"
printf '  Deepstate Inc Safe: %s (1-of-1, no modules)\n' "$DEEPSTATE_INC_SAFE"
printf '  sole Safe owner and proposer: %s\n' "$PROPOSER"
printf '  proposer votes: %s\n' "$proposer_votes"
printf '  Sablier Lockup v4: %s\n' "$SABLIER_LOCKUP"
printf '  Sablier replacement Comptroller: %s (%s, Lockup fee %s USD units)\n' \
    "$SABLIER_COMPTROLLER" "$EXPECTED_SABLIER_COMPTROLLER_VERSION" "$sablier_lockup_min_fee_usd"
printf '  deterministic CREATE2 deployer: %s\n' "$CREATE2_DEPLOYER"
printf '  Router fee: %s bps to %s\n' "$router_fee_bps" "$STATE"
printf '  NVDA/USDG hook: %s\n' "$REWARDER"
printf '  legacy Rewarder total accrued: USDG %s, NVDA %s\n' \
    "$legacy_usdg_total_accrued" "$legacy_nvda_total_accrued"
printf '  governance start: %s (2026-08-30T07:23:58Z)\n' "$governance_start"
printf '  governance status at snapshot: %s\n' "$governance_status"
printf '  proposal threshold: %s\n' "$proposal_threshold"
printf '  voting delay: %s seconds\n' "$(rpc_uint "$GOVERNOR" 'votingDelay()(uint256)')"
printf '  voting period: %s seconds\n' "$(rpc_uint "$GOVERNOR" 'votingPeriod()(uint256)')"
printf '  late-quorum extension: %s seconds\n' "$(rpc_uint "$GOVERNOR" 'lateQuorumVoteExtension()(uint48)')"
printf '  quorum numerator: %s/100\n' "$(rpc_uint "$GOVERNOR" 'quorumNumerator()(uint256)')"

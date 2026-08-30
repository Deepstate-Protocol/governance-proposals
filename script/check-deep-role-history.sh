#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDRESS_REGISTRY="$ROOT_DIR/src/DeepstateAddresses.sol"
RPC_URL="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com/}"
SNAPSHOT_BLOCK="${1:-}"
DEFAULT_ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
ROLE_GRANTED_TOPIC=0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d
ROLE_REVOKED_TOPIC=0xf6391f5c32d9c69d2a47ea670b442974b53935d1edc7fd64eb21e047a839171b
MINTER_ROLE=0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6
LOG_CHUNK_SIZE="${DEEP_ROLE_LOG_CHUNK_SIZE:-1000000}"

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf 'Missing required command: %s\n' "$command_name" >&2
        exit 1
    fi
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

topic_address() {
    printf '0x%064s\n' "${1#0x}" | tr ' ' '0' | tr '[:upper:]' '[:lower:]'
}

lowercase() {
    tr '[:upper:]' '[:lower:]' <<<"$1"
}

rpc_call() {
    cast call "$@" --rpc-url "$RPC_URL" --block "$SNAPSHOT_BLOCK"
}

require_false() {
    local role="$1"
    local account="$2"
    if [[ "$(rpc_call "$DEEP" 'hasRole(bytes32,address)(bool)' "$role" "$account")" != "false" ]]; then
        printf 'Unexpected live DEEP role %s on %s at block %s\n' "$role" "$account" "$SNAPSHOT_BLOCK" >&2
        exit 1
    fi
}

require_command cast
require_command jq

if [[ ! "$LOG_CHUNK_SIZE" =~ ^[1-9][0-9]*$ ]]; then
    printf 'DEEP_ROLE_LOG_CHUNK_SIZE must be a positive integer\n' >&2
    exit 1
fi

EXPECTED_CHAIN_ID="$(solidity_uint CHAIN_ID)"
DEEP_DEPLOYMENT_BLOCK="$(solidity_uint DEEP_DEPLOYMENT_BLOCK)"
DEEP_DEPLOYMENT_BLOCK_HASH="$(solidity_bytes32 DEEP_DEPLOYMENT_BLOCK_HASH)"
DEEP="$(solidity_address DEEP)"
DEEP_DEPLOYER="$(solidity_address DEEP_DEPLOYER)"
GOVERNOR="$(solidity_address GOVERNOR)"

chain_id="$(cast chain-id --rpc-url "$RPC_URL")"
if [[ "$chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
    printf 'Chain ID mismatch: expected %s, received %s\n' "$EXPECTED_CHAIN_ID" "$chain_id" >&2
    exit 1
fi

if [[ -z "$SNAPSHOT_BLOCK" ]]; then
    SNAPSHOT_BLOCK="$(cast block-number --rpc-url "$RPC_URL")"
fi
if [[ ! "$SNAPSHOT_BLOCK" =~ ^[0-9]+$ ]] || (( SNAPSHOT_BLOCK < DEEP_DEPLOYMENT_BLOCK )); then
    printf 'Invalid snapshot block %s; expected a decimal block at or after %s\n' \
        "$SNAPSHOT_BLOCK" "$DEEP_DEPLOYMENT_BLOCK" >&2
    exit 1
fi

actual_deployment_hash="$(cast block "$DEEP_DEPLOYMENT_BLOCK" --field hash --rpc-url "$RPC_URL")"
if [[ "$(lowercase "$actual_deployment_hash")" != "$(lowercase "$DEEP_DEPLOYMENT_BLOCK_HASH")" ]]; then
    printf 'DEEP deployment block hash mismatch: expected %s, received %s\n' \
        "$DEEP_DEPLOYMENT_BLOCK_HASH" "$actual_deployment_hash" >&2
    exit 1
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf -- "$temporary_dir"' EXIT
logs_file="$temporary_dir/role-logs.jsonl"
: >"$logs_file"

from_block="$DEEP_DEPLOYMENT_BLOCK"
while (( from_block <= SNAPSHOT_BLOCK )); do
    to_block=$((from_block + LOG_CHUNK_SIZE - 1))
    if (( to_block > SNAPSHOT_BLOCK )); then
        to_block="$SNAPSHOT_BLOCK"
    fi
    filter="[{\"fromBlock\":\"0x$(printf '%x' "$from_block")\",\"toBlock\":\"0x$(printf '%x' "$to_block")\",\"address\":\"$DEEP\",\"topics\":[[\"$ROLE_GRANTED_TOPIC\",\"$ROLE_REVOKED_TOPIC\"]]}]"
    cast rpc --rpc-url "$RPC_URL" eth_getLogs "$filter" --raw \
        | jq -c '.[]' >>"$logs_file"
    from_block=$((to_block + 1))
done

actual_history="$(
    jq -sr \
        '.[] | [.blockNumber, .transactionIndex, .logIndex, .topics[0], .topics[1], .topics[2], .topics[3]]
        | map(ascii_downcase) | @tsv' \
        "$logs_file"
)"
deployer_topic="$(topic_address "$DEEP_DEPLOYER")"
governor_topic="$(topic_address "$GOVERNOR")"
expected_history="$(printf '%b\n' \
    "0x2338bd8\t0x1\t0x0\t$ROLE_GRANTED_TOPIC\t$DEFAULT_ADMIN_ROLE\t$deployer_topic\t$deployer_topic" \
    "0x2338bef\t0x2\t0x0\t$ROLE_GRANTED_TOPIC\t$MINTER_ROLE\t$deployer_topic\t$deployer_topic" \
    "0x2338c0f\t0x5\t0xe\t$ROLE_REVOKED_TOPIC\t$MINTER_ROLE\t$deployer_topic\t$deployer_topic" \
    "0x2338c1d\t0x3\t0x3\t$ROLE_GRANTED_TOPIC\t$DEFAULT_ADMIN_ROLE\t$governor_topic\t$deployer_topic" \
    "0x2338c22\t0x1\t0x0\t$ROLE_REVOKED_TOPIC\t$DEFAULT_ADMIN_ROLE\t$deployer_topic\t$deployer_topic"
)"
if [[ "$actual_history" != "$expected_history" ]]; then
    printf 'DEEP RoleGranted/RoleRevoked history differs from the exact pre-activation baseline.\n' >&2
    printf 'Expected:\n%s\nActual:\n%s\n' "$expected_history" "$actual_history" >&2
    exit 1
fi

live_minter_role="$(rpc_call "$DEEP" 'MINTER_ROLE()(bytes32)')"
if [[ "$(lowercase "$live_minter_role")" != "$MINTER_ROLE" ]]; then
    printf 'DEEP MINTER_ROLE mismatch: expected %s, received %s\n' "$MINTER_ROLE" "$live_minter_role" >&2
    exit 1
fi
if [[ "$(rpc_call "$DEEP" 'hasRole(bytes32,address)(bool)' "$DEFAULT_ADMIN_ROLE" "$GOVERNOR")" != "true" ]]; then
    printf 'Governor is not the live DEEP default admin at block %s\n' "$SNAPSHOT_BLOCK" >&2
    exit 1
fi
require_false "$DEFAULT_ADMIN_ROLE" "$DEEP_DEPLOYER"
require_false "$MINTER_ROLE" "$DEEP_DEPLOYER"
require_false "$MINTER_ROLE" "$GOVERNOR"

default_admin_count="$(rpc_call "$DEEP" 'defaultAdminCount()(uint256)')"
default_admin_count="${default_admin_count%% *}"
if [[ "$default_admin_count" != "1" ]]; then
    printf 'Unexpected DEEP default admin count at block %s: %s\n' "$SNAPSHOT_BLOCK" "$default_admin_count" >&2
    exit 1
fi

printf 'Exact DEEP pre-activation role history verified\n'
printf '  deployment block: %s\n' "$DEEP_DEPLOYMENT_BLOCK"
printf '  snapshot block: %s\n' "$SNAPSHOT_BLOCK"
printf '  role events: 5\n'
printf '  sole default admin: %s\n' "$GOVERNOR"
printf '  token-level minters: none\n'

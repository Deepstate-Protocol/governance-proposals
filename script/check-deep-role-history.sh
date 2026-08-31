#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: check-deep-role-history.sh [snapshot-block] [pre-activation|post-activation]
# The post-activation mode additionally proves the exact five DGP-001 DEEP role events and the Factory's sole
# RolesUpdated grant on each Controller, all from the same atomic Governor execution.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDRESS_REGISTRY="$ROOT_DIR/script/config/DeepstateAddresses.sol"
RPC_URL="${ROBINHOOD_RPC_URL:-https://rpc.mainnet.chain.robinhood.com/}"
SNAPSHOT_BLOCK="${1:-}"
ROLE_PHASE="${2:-pre-activation}"
DEFAULT_ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
ROLE_GRANTED_TOPIC=0x2f8788117e7eff1d82e926ec794901d17c78024a50270940304540a733656f0d
ROLE_REVOKED_TOPIC=0xf6391f5c32d9c69d2a47ea670b442974b53935d1edc7fd64eb21e047a839171b
MINTER_ROLE=0x9f2df0fed2c77648de5860a4cc508cd0818c85b8b8a1ab4ceeef8d981c8956a6
ROLES_UPDATED_TOPIC=0x715ad5ce61fc9595c7b415289d59cf203f23a94fa06f04af7e489a0a76e1fe26
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

if [[ "$ROLE_PHASE" != "pre-activation" && "$ROLE_PHASE" != "post-activation" ]]; then
    printf 'Invalid role phase %s; expected pre-activation or post-activation\n' "$ROLE_PHASE" >&2
    exit 1
fi

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
MINTER_CONTROLLER="$(solidity_address MINTER_CONTROLLER)"
DGP001_BOOTSTRAP="$(solidity_address DGP001_BOOTSTRAP)"
V1_CONTROLLER="$(solidity_address V1_CONTROLLER)"
REWARDER_FACTORY="$(solidity_address REWARDER_FACTORY)"
DEEPSTATE_INC_SAFE="$(solidity_address DEEPSTATE_INC_SAFE)"
REWARDER="$(solidity_address REWARDER)"

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
role_event_count="$(jq -s 'length' "$logs_file")"
deployer_topic="$(topic_address "$DEEP_DEPLOYER")"
governor_topic="$(topic_address "$GOVERNOR")"
minter_controller_topic="$(topic_address "$MINTER_CONTROLLER")"
bootstrap_topic="$(topic_address "$DGP001_BOOTSTRAP")"
expected_history="$(printf '%b\n' \
    "0x2338bd8\t0x1\t0x0\t$ROLE_GRANTED_TOPIC\t$DEFAULT_ADMIN_ROLE\t$deployer_topic\t$deployer_topic" \
    "0x2338bef\t0x2\t0x0\t$ROLE_GRANTED_TOPIC\t$MINTER_ROLE\t$deployer_topic\t$deployer_topic" \
    "0x2338c0f\t0x5\t0xe\t$ROLE_REVOKED_TOPIC\t$MINTER_ROLE\t$deployer_topic\t$deployer_topic" \
    "0x2338c1d\t0x3\t0x3\t$ROLE_GRANTED_TOPIC\t$DEFAULT_ADMIN_ROLE\t$governor_topic\t$deployer_topic" \
    "0x2338c22\t0x1\t0x0\t$ROLE_REVOKED_TOPIC\t$DEFAULT_ADMIN_ROLE\t$deployer_topic\t$deployer_topic"
)"
if [[ "$ROLE_PHASE" == "pre-activation" ]]; then
    if [[ "$role_event_count" != "5" || "$actual_history" != "$expected_history" ]]; then
        printf 'DEEP RoleGranted/RoleRevoked history differs from the exact pre-activation baseline.\n' >&2
        printf 'Expected:\n%s\nActual:\n%s\n' "$expected_history" "$actual_history" >&2
        exit 1
    fi
else
    baseline_history="$(head -n 5 <<<"$actual_history")"
    if [[ "$role_event_count" != "10" || "$baseline_history" != "$expected_history" ]]; then
        printf 'DEEP role history does not begin with the exact five-event pre-activation baseline.\n' >&2
        printf 'Expected baseline:\n%s\nActual history:\n%s\n' "$expected_history" "$actual_history" >&2
        exit 1
    fi

    actual_activation_history="$(
        jq -sr \
            '.[5:] | .[] | [.topics[0], .topics[1], .topics[2], .topics[3]]
            | map(ascii_downcase) | @tsv' \
            "$logs_file"
    )"
    expected_activation_history="$(printf '%b\n' \
        "$ROLE_GRANTED_TOPIC\t$MINTER_ROLE\t$bootstrap_topic\t$governor_topic" \
        "$ROLE_REVOKED_TOPIC\t$MINTER_ROLE\t$bootstrap_topic\t$bootstrap_topic" \
        "$ROLE_GRANTED_TOPIC\t$DEFAULT_ADMIN_ROLE\t$minter_controller_topic\t$governor_topic" \
        "$ROLE_REVOKED_TOPIC\t$DEFAULT_ADMIN_ROLE\t$governor_topic\t$governor_topic" \
        "$ROLE_GRANTED_TOPIC\t$MINTER_ROLE\t$minter_controller_topic\t$minter_controller_topic"
    )"
    if [[ "$actual_activation_history" != "$expected_activation_history" ]]; then
        printf 'DEEP activation role events differ from the exact DGP-001 sequence.\n' >&2
        printf 'Expected activation:\n%s\nActual activation:\n%s\n' \
            "$expected_activation_history" "$actual_activation_history" >&2
        exit 1
    fi
    if ! jq -se \
        'length == 10
        and ((.[5:10] | map(.transactionHash | ascii_downcase) | unique | length) == 1)
        and ((.[5:10] | map(.blockNumber | ascii_downcase) | unique | length) == 1)' \
        "$logs_file" >/dev/null; then
        printf 'The five DEEP activation role events were not emitted by one atomic transaction.\n' >&2
        exit 1
    fi
fi

live_minter_role="$(rpc_call "$DEEP" 'MINTER_ROLE()(bytes32)')"
if [[ "$(lowercase "$live_minter_role")" != "$MINTER_ROLE" ]]; then
    printf 'DEEP MINTER_ROLE mismatch: expected %s, received %s\n' "$MINTER_ROLE" "$live_minter_role" >&2
    exit 1
fi
if [[ "$ROLE_PHASE" == "pre-activation" ]]; then
    if [[ "$(rpc_call "$DEEP" 'hasRole(bytes32,address)(bool)' "$DEFAULT_ADMIN_ROLE" "$GOVERNOR")" != "true" ]]; then
        printf 'Governor is not the live DEEP default admin at block %s\n' "$SNAPSHOT_BLOCK" >&2
        exit 1
    fi
    require_false "$DEFAULT_ADMIN_ROLE" "$DEEP_DEPLOYER"
    require_false "$MINTER_ROLE" "$DEEP_DEPLOYER"
    require_false "$MINTER_ROLE" "$GOVERNOR"
    require_false "$DEFAULT_ADMIN_ROLE" "$DGP001_BOOTSTRAP"
    require_false "$MINTER_ROLE" "$DGP001_BOOTSTRAP"
else
    if [[ "$(rpc_call "$DEEP" 'hasRole(bytes32,address)(bool)' "$DEFAULT_ADMIN_ROLE" "$MINTER_CONTROLLER")" != "true" ]]; then
        printf 'Minter Controller is not the live DEEP default admin at block %s\n' "$SNAPSHOT_BLOCK" >&2
        exit 1
    fi
    if [[ "$(rpc_call "$DEEP" 'hasRole(bytes32,address)(bool)' "$MINTER_ROLE" "$MINTER_CONTROLLER")" != "true" ]]; then
        printf 'Minter Controller is not the live DEEP token minter at block %s\n' "$SNAPSHOT_BLOCK" >&2
        exit 1
    fi
    for account in "$DEEP_DEPLOYER" "$GOVERNOR" "$DGP001_BOOTSTRAP" "$REWARDER_FACTORY" "$DEEPSTATE_INC_SAFE" "$REWARDER"; do
        require_false "$DEFAULT_ADMIN_ROLE" "$account"
        require_false "$MINTER_ROLE" "$account"
    done
fi

default_admin_count="$(rpc_call "$DEEP" 'defaultAdminCount()(uint256)')"
default_admin_count="${default_admin_count%% *}"
if [[ "$default_admin_count" != "1" ]]; then
    printf 'Unexpected DEEP default admin count at block %s: %s\n' "$SNAPSHOT_BLOCK" "$default_admin_count" >&2
    exit 1
fi

if [[ "$ROLE_PHASE" == "pre-activation" ]]; then
    printf 'Exact DEEP pre-activation role history verified\n'
    printf '  deployment block: %s\n' "$DEEP_DEPLOYMENT_BLOCK"
    printf '  snapshot block: %s\n' "$SNAPSHOT_BLOCK"
    printf '  role events: 5\n'
    printf '  sole default admin: %s\n' "$GOVERNOR"
    printf '  token-level minters: none\n'
else
    activation_transaction="$(jq -sr '.[5].transactionHash | ascii_downcase' "$logs_file")"
    factory_topic="$(topic_address "$REWARDER_FACTORY")"
    role_one_topic="$(topic_address 0x1)"

    for controller in "$MINTER_CONTROLLER" "$V1_CONTROLLER"; do
        controller_logs="$temporary_dir/$(lowercase "$controller").jsonl"
        : >"$controller_logs"
        from_block="$DEEP_DEPLOYMENT_BLOCK"
        while (( from_block <= SNAPSHOT_BLOCK )); do
            to_block=$((from_block + LOG_CHUNK_SIZE - 1))
            if (( to_block > SNAPSHOT_BLOCK )); then
                to_block="$SNAPSHOT_BLOCK"
            fi
            filter="[{\"fromBlock\":\"0x$(printf '%x' "$from_block")\",\"toBlock\":\"0x$(printf '%x' "$to_block")\",\"address\":\"$controller\",\"topics\":[\"$ROLES_UPDATED_TOPIC\"]}]"
            cast rpc --rpc-url "$RPC_URL" eth_getLogs "$filter" --raw | jq -c '.[]' >>"$controller_logs"
            from_block=$((to_block + 1))
        done

        controller_event_count="$(jq -s 'length' "$controller_logs")"
        controller_history="$(
            jq -sr \
                '.[] | [.topics[0], .topics[1], .topics[2], .transactionHash]
                | map(ascii_downcase) | @tsv' \
                "$controller_logs"
        )"
        expected_controller_history="$(
            printf '%b' "$ROLES_UPDATED_TOPIC\t$factory_topic\t$role_one_topic\t$activation_transaction"
        )"
        if [[ "$controller_event_count" != "1" || "$controller_history" != "$expected_controller_history" ]]; then
            printf 'Controller role history differs from the exact DGP-001 Factory grant for %s.\n' "$controller" >&2
            printf 'Expected:\n%s\nActual:\n%s\n' "$expected_controller_history" "$controller_history" >&2
            exit 1
        fi

        controller_roles="$(rpc_call "$controller" 'rolesOf(address)(uint256)' "$REWARDER_FACTORY")"
        controller_roles="${controller_roles%% *}"
        if [[ "$controller_roles" != "1" ]]; then
            printf 'Factory roles on %s are not exactly 1 at block %s: %s\n' \
                "$controller" "$SNAPSHOT_BLOCK" "$controller_roles" >&2
            exit 1
        fi
    done

    printf 'Exact post-DGP-001 role histories verified\n'
    printf '  deployment block: %s\n' "$DEEP_DEPLOYMENT_BLOCK"
    printf '  snapshot block: %s\n' "$SNAPSHOT_BLOCK"
    printf '  DEEP role events: 10\n'
    printf '  activation transaction: %s\n' "$activation_transaction"
    printf '  sole DEEP default admin/minter: %s\n' "$MINTER_CONTROLLER"
    printf '  sole Controller-local delegate: %s\n' "$REWARDER_FACTORY"
fi

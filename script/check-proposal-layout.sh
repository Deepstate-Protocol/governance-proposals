#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
shopt -s nullglob

fail() {
    printf 'Proposal layout check failed: %s\n' "$1" >&2
    exit 1
}

reject_placeholders() {
    local file="$1"
    if grep -En 'DGP-XXX|DGPXXX|DGPNNN|REPLACE_WITH_|TODO|IProposalTarget|functionName|Proposal title' \
        "$file" >/dev/null; then
        fail "template placeholder remains in ${file#"$ROOT_DIR"/}"
    fi
}

proposal_count=0
proposal_numbers=()
for proposal_file in "$ROOT_DIR"/proposals/DGP-*.md; do
    proposal_count=$((proposal_count + 1))
    filename="$(basename "$proposal_file")"
    if [[ ! "$filename" =~ ^DGP-([0-9]{3})\.md$ ]]; then
        fail "invalid proposal filename: $filename"
    fi

    number="${BASH_REMATCH[1]}"
    proposal_numbers+=("$number")
    script_file="$ROOT_DIR/script/proposals/DGP${number}/Deploy.s.sol"
    test_file="$ROOT_DIR/test/proposals/DGP${number}/Proposal.t.sol"

    [[ -f "$script_file" ]] || fail "$filename is missing script/proposals/DGP${number}/Deploy.s.sol"
    [[ -f "$test_file" ]] || fail "$filename is missing test/proposals/DGP${number}/Proposal.t.sol"
    [[ -s "$proposal_file" ]] || fail "$filename is empty"

    script_source="$(perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$script_file")"
    test_source="$(perl -0777 -pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g' "$test_file")"

    grep -Eq "^# DGP-${number}: .+" "$proposal_file" || fail "$filename has an invalid title"
    if grep -F '#proposer=' "$proposal_file" >/dev/null; then
        fail "$filename must not contain a manual proposer suffix; the base script appends it"
    fi

    grep -Eq "contract[[:space:]]+DeployDGP${number}[[:space:]]+is[[:space:]]+DeepstateProposalScript" \
        <<<"$script_source" \
        || fail "DGP-${number} deployment contract must be named DeployDGP${number}"
    grep -F "\"proposals/DGP-${number}.md\"" <<<"$script_source" >/dev/null \
        || fail "DGP-${number} deployment script does not use its own Markdown description"
    grep -Eq "contract[[:space:]]+DGP${number}Test[[:space:]]+is[[:space:]]+Test" <<<"$test_source" \
        || fail "DGP-${number} test contract must be named DGP${number}Test"
    if grep -F '#proposer=' "$script_file" >/dev/null; then
        fail "DGP-${number} deployment script must not append its own proposer suffix"
    fi
    grep -Eq 'function[[:space:]]+_afterExecution[[:space:]]*\(' <<<"$script_source" \
        || fail "DGP-${number} deployment script has no live postcondition check"
    grep -Eq 'proposal[[:space:]]*\.[[:space:]]*verifyExecution[[:space:]]*\(' <<<"$test_source" \
        || fail "DGP-${number} lifecycle test does not invoke the live execution verifier"

    if grep -Eq 'EXPECTED_PROPOSAL_ID[[:space:]]*=[[:space:]]*(0|0x0+)[[:space:]]*;' "$script_file"; then
        fail "DGP-${number} has no pinned proposal ID"
    fi
    if grep -Eq 'PROPOSER[[:space:]]*=[[:space:]]*0x0{40}[[:space:]]*;' "$script_file"; then
        fail "DGP-${number} has no intended proposer"
    fi
    proposer_address="$(sed -nE 's/.*constant PROPOSER = (0x[[:xdigit:]]{40});/\1/p' "$script_file")"
    [[ -n "$proposer_address" ]] || fail "DGP-${number} proposer must be a literal address"
    grep -Fi "$proposer_address" "$proposal_file" >/dev/null \
        || fail "DGP-${number} Markdown does not identify its configured proposer"
    fork_block="$(sed -nE \
        's/^[[:space:]]*uint256[[:space:]]+internal[[:space:]]+constant[[:space:]]+FORK_BLOCK[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*;[[:space:]]*$/\1/p' \
        <<<"$test_source")"
    [[ "$fork_block" =~ ^[1-9][0-9]*$ ]] || fail "DGP-${number} has no literal nonzero fork block"
    grep -F "$fork_block" "$proposal_file" >/dev/null \
        || fail "DGP-${number} Markdown does not record its pinned fork block"

    fork_block_hash="$(sed -nE \
        's/^[[:space:]]*bytes32[[:space:]]+internal[[:space:]]+constant[[:space:]]+FORK_BLOCK_HASH[[:space:]]*=[[:space:]]*(0x[[:xdigit:]]{64})[[:space:]]*;[[:space:]]*$/\1/p' \
        <<<"$test_source")"
    [[ "$fork_block_hash" =~ ^0x[[:xdigit:]]{64}$ ]] \
        || fail "DGP-${number} has no literal fork block hash"
    [[ "$fork_block_hash" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]] \
        || fail "DGP-${number} has no pinned fork block hash"
    grep -Fi "$fork_block_hash" "$proposal_file" >/dev/null \
        || fail "DGP-${number} Markdown does not record its pinned fork block hash"
    grep -F 'blockhash(FORK_BLOCK)' <<<"$test_source" >/dev/null \
        || fail "DGP-${number} test does not verify its pinned fork block hash"
    if grep -Eq 'EXPECTED_DESCRIPTION_HASH[[:space:]]*=[[:space:]]*(bytes32\(0\)|0x0{64})' "$test_file"; then
        fail "DGP-${number} has no pinned description hash"
    fi
    if grep -Eq 'QUORUM_VOTER[[:space:]]*=[[:space:]]*address\(0\)' "$test_file"; then
        fail "DGP-${number} has no pinned quorum voter"
    fi

    reject_placeholders "$proposal_file"
    reject_placeholders "$script_file"
    reject_placeholders "$test_file"
done

if ((proposal_count > 0)); then
    command -v forge >/dev/null 2>&1 || fail "forge is required to discover proposal tests"
    command -v jq >/dev/null 2>&1 || fail "jq is required to inspect the Forge test manifest"

    if ! test_manifest="$(cd "$ROOT_DIR" && NO_COLOR=1 forge test --list --json)"; then
        fail "Forge could not compile and discover the proposal tests"
    fi
    required_tests='["testProposalPayload","testAuthorizedTargetCallsAndPostconditions","testFullGovernorLifecycle"]'

    for number in "${proposal_numbers[@]}"; do
        if ! jq -e \
            --arg file "test/proposals/DGP${number}/Proposal.t.sol" \
            --arg contract "DGP${number}Test" \
            --argjson required "$required_tests" '
                (.[$file][$contract] // []) as $discovered
                | ($discovered | type == "array")
                    and (($required - $discovered) | length == 0)
            ' <<<"$test_manifest" >/dev/null; then
            fail "DGP-${number} is missing its concrete test contract or required discovered tests"
        fi
    done
fi

for script_file in "$ROOT_DIR"/script/proposals/DGP*/Deploy.s.sol; do
    directory="$(basename "$(dirname "$script_file")")"
    [[ "$directory" =~ ^DGP([0-9]{3})$ ]] || fail "invalid proposal script directory: $directory"
    number="${BASH_REMATCH[1]}"
    [[ -f "$ROOT_DIR/proposals/DGP-${number}.md" ]] || fail "$directory has no matching proposal Markdown"
done

for test_file in "$ROOT_DIR"/test/proposals/DGP*/Proposal.t.sol; do
    directory="$(basename "$(dirname "$test_file")")"
    [[ "$directory" =~ ^DGP([0-9]{3})$ ]] || fail "invalid proposal test directory: $directory"
    number="${BASH_REMATCH[1]}"
    [[ -f "$ROOT_DIR/proposals/DGP-${number}.md" ]] || fail "$directory has no matching proposal Markdown"
done

printf 'Proposal layout verified (%s concrete proposals)\n' "$proposal_count"

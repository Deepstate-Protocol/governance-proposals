#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_FILE="$ROOT_DIR/lib/deepstate-protocol/src/DeepstateRewarder.sol"
LOCAL_FILE="$ROOT_DIR/src/DeepstateRewarder.sol"
PATCH_FILE="$ROOT_DIR/patches/deepstate-rewarder-retirement.patch"

fail() {
    printf 'Rewarder fork check failed: %s\n' "$1" >&2
    exit 1
}

for required_command in cmp mktemp patch; do
    command -v "$required_command" >/dev/null 2>&1 || fail "missing required command: $required_command"
done

[[ -f "$UPSTREAM_FILE" ]] || fail "pinned upstream Rewarder is missing"
[[ -f "$LOCAL_FILE" ]] || fail "local Rewarder fork is missing"
[[ -f "$PATCH_FILE" ]] || fail "reviewed retirement patch is missing"

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/deepstate-rewarder-fork.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
CANDIDATE_FILE="$TEMP_DIR/DeepstateRewarder.sol"

cp "$UPSTREAM_FILE" "$CANDIDATE_FILE"
patch --silent "$CANDIDATE_FILE" < "$PATCH_FILE" || fail "reviewed retirement patch no longer applies"
cmp -s "$CANDIDATE_FILE" "$LOCAL_FILE" || fail "local Rewarder differs from the reviewed upstream patch"

printf 'Rewarder fork verified against pinned upstream source\n'

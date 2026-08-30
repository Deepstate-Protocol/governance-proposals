#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK_FILE="$ROOT_DIR/foundry.lock"
REMAPPINGS_FILE="$ROOT_DIR/remappings.txt"

fail() {
    printf 'Dependency layout check failed: %s\n' "$1" >&2
    exit 1
}

for required_command in forge git jq; do
    command -v "$required_command" >/dev/null 2>&1 || fail "missing required command: $required_command"
done

locked_paths="$(jq -r 'keys[]' "$LOCK_FILE" | sort)"
configured_paths="$(git config -f "$ROOT_DIR/.gitmodules" --get-regexp '^submodule\..*\.path$' \
    | awk '{ print $2 }' | sort)"
gitlink_paths="$(git -C "$ROOT_DIR" ls-files --stage \
    | awk '$1 == "160000" { print $4 }' | sort)"

if [[ "$locked_paths" != "$configured_paths" ]]; then
    fail ".gitmodules paths do not exactly match foundry.lock"
fi
if [[ "$locked_paths" != "$gitlink_paths" ]]; then
    fail "tracked gitlinks do not exactly match foundry.lock"
fi

while IFS= read -r dependency_path; do
    expected_revision="$(
        jq -r --arg path "$dependency_path" '.[$path].rev // .[$path].tag.rev // empty' "$LOCK_FILE"
    )"
    [[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || fail "$dependency_path has no pinned revision"
    [[ -e "$ROOT_DIR/$dependency_path/.git" ]] || fail "$dependency_path is not initialized"

    actual_revision="$(git -C "$ROOT_DIR/$dependency_path" rev-parse HEAD)"
    [[ "$actual_revision" == "$expected_revision" ]] \
        || fail "$dependency_path expected $expected_revision, found $actual_revision"

    gitlink_revision="$(git -C "$ROOT_DIR" ls-files --stage "$dependency_path" | awk '$1 == "160000" { print $2 }')"
    [[ "$gitlink_revision" == "$expected_revision" ]] \
        || fail "$dependency_path gitlink is not pinned to $expected_revision"

    if [[ -n "$(git -C "$ROOT_DIR/$dependency_path" status --porcelain --untracked-files=all)" ]]; then
        fail "$dependency_path contains dirty or untracked files"
    fi
done < <(jq -r 'keys[]' "$LOCK_FILE")

if ! cmp -s <(cd "$ROOT_DIR" && forge remappings) "$REMAPPINGS_FILE"; then
    fail "Forge remappings differ from the reviewed explicit remappings"
fi

if forge remappings | grep -E 'lib/(deepstate-protocol|deepstate-contracts)/lib/' >/dev/null; then
    fail "a nested upstream dependency leaked into Forge remappings"
fi

for upstream_path in lib/deepstate-protocol lib/deepstate-contracts; do
    if git -C "$ROOT_DIR/$upstream_path" submodule status | grep -Ev '^-' >/dev/null; then
        fail "$upstream_path has initialized nested submodules; use direct root dependencies only"
    fi
done

printf 'Dependency layout verified (%s pinned root libraries)\n' "$(jq 'keys | length' "$LOCK_FILE")"

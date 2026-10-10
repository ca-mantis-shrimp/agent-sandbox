#!/bin/sh
# Host checks use stubs; never query or alter real system-manager units.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/links" "$tmp/runs" "$tmp/path" "$tmp/base" "$tmp/images"
ln -s "$tool/bin/agent-status" "$tmp/links/agent-status"
AGENT_RUNS="$tmp/runs" "$tmp/links/agent-status"
export AGENT_RUNS="$tmp/runs"
unset AGENT_PI_PROVIDER
mkdir "$AGENT_RUNS/.pi"
printf '%s\n' '{"openai":{"type":"oauth","access":"test"}}' >"$AGENT_RUNS/.pi/auth.json"
for cmd in git jq flock awk dirname readlink; do ln -s "$(command -v "$cmd")" "$tmp/path/$cmd"; done
printf '%s\n' '#!/bin/sh' 'echo "${TEST_GROUPS:-users agents}"' >"$tmp/path/id"
printf '%s\n' '#!/bin/sh' 'case "$1" in --version) echo "systemd ${TEST_VERSION:-257}" ;; show) case "$2" in agent@.service) echo not-found ;; *) echo "${TEST_LOAD:-loaded}" ;; esac ;; *) exit 1 ;; esac' >"$tmp/path/systemctl"
chmod +x "$tmp/path/id" "$tmp/path/systemctl"
export AGENT_BASE="$tmp/base" AGENT_LAYERS="$tmp/images"
touch "$AGENT_LAYERS/harness.raw"
PATH="$tmp/path" "$tool/bin/agent-doctor" >"$tmp/out"
grep -q 'calling process is in agents group' "$tmp/out"
grep -q 'ok       agent@.service installed' "$tmp/out"
grep -Fq 'note     Claude sessions need /etc/credstore/agent.claude_token (plain) or /etc/credstore.encrypted/agent.claude_token (sealed with systemd-creds encrypt, e.g. to the TPM); neither root-only credstore can be checked from this user' "$tmp/out"
! grep -q 'agent.claude_token.*missing' "$tmp/out"
grep -q 'ok       shared pi login for provider openai' "$tmp/out"
# A different provider is selected by the same environment override as launches.
AGENT_PI_PROVIDER=other PATH="$tmp/path" "$tool/bin/agent-doctor" >"$tmp/out" && exit 1
grep -q 'MISSING  shared pi login for provider other' "$tmp/out"
printf '%s\n' '{"other":{"type":"oauth","access":"test"}}' >"$AGENT_RUNS/.pi/auth.json"
AGENT_PI_PROVIDER=other PATH="$tmp/path" "$tool/bin/agent-doctor" >"$tmp/out"
grep -q 'ok       shared pi login for provider other' "$tmp/out"
for contents in '{}' '[]' 'invalid'; do
    printf '%s\n' "$contents" >"$AGENT_RUNS/.pi/auth.json"
    PATH="$tmp/path" "$tool/bin/agent-doctor" >"$tmp/out" && exit 1
    grep -q 'MISSING  shared pi login for provider openai' "$tmp/out"
done
rm "$AGENT_RUNS/.pi/auth.json"
PATH="$tmp/path" "$tool/bin/agent-doctor" >"$tmp/out" && exit 1
grep -q 'MISSING  shared pi login for provider openai' "$tmp/out"
printf '%s\n' '{"openai":{"type":"oauth","access":"test"}}' >"$AGENT_RUNS/.pi/auth.json"
for mode in version groups unit base layer; do
    case "$mode" in
        version) export TEST_VERSION=256 ;;
        groups) export TEST_GROUPS=users ;;
        unit) export TEST_LOAD=not-found ;;
        base) AGENT_BASE="$tmp/missing" ;;
        layer) rm "$AGENT_LAYERS/harness.raw" ;;
    esac
    if PATH="$tmp/path" "$tool/bin/agent-doctor" >"$tmp/out"; then echo "expected failed $mode check" >&2; exit 1; fi
    grep -q MISSING "$tmp/out"
    unset TEST_VERSION TEST_GROUPS TEST_LOAD
    AGENT_BASE="$tmp/base"
done
echo 'doctor.test > ok'

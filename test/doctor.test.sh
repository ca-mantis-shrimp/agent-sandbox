#!/bin/sh
#
# Tests that a command reached through a symlink (how a PATH entry or a
# package may expose it) finds its install, and that agent-doctor fails on a
# host without podman while changing nothing. Each assertion aborts under
# set -e, so reaching the final line is the pass.
set -eu

tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Through a link, agent-status still finds lib/ beside the real bin/.
mkdir "$tmp/links" "$tmp/runs"
ln -s "$tool/bin/agent-status" "$tmp/links/agent-status"
AGENT_RUNS="$tmp/runs" "$tmp/links/agent-status"

# A PATH with everything the doctor uses except podman.
mkdir "$tmp/path"
for cmd in id git jq flock systemctl grep sort loginctl; do
    ln -s "$(command -v "$cmd")" "$tmp/path/$cmd"
done
if PATH="$tmp/path" "$tool/bin/agent-doctor" >"$tmp/out"; then
    echo "doctor.test > expected a failure without podman" >&2
    exit 1
fi
grep -q 'MISSING  podman' "$tmp/out"
grep -q 'ok       git' "$tmp/out"

echo "doctor.test > ok"

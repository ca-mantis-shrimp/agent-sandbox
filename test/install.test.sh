#!/bin/sh
#
# Tests install.sh: it links every command into $PREFIX/bin, a linked command
# finds the install through the link, a rerun is quiet, and a file it does
# not own is left alone. Each assertion aborts under set -e, so reaching the
# final line is the pass.
set -eu

tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

PREFIX="$tmp/prefix" "$tool/install.sh" 2>/dev/null
for cmd in "$tool"/bin/*; do
    [ "$(readlink -f "$tmp/prefix/bin/$(basename "$cmd")")" = "$cmd" ]
done
# Through the link, the command still finds lib/ beside the real bin/.
mkdir "$tmp/runs"
AGENT_RUNS="$tmp/runs" "$tmp/prefix/bin/agent-status"

# A rerun links nothing new.
PREFIX="$tmp/prefix" "$tool/install.sh" 2>"$tmp/log"
! grep -q 'linked' "$tmp/log"

# Someone else's agent-stop is reported and kept.
rm "$tmp/prefix/bin/agent-stop"
echo mine >"$tmp/prefix/bin/agent-stop"
if PREFIX="$tmp/prefix" "$tool/install.sh" 2>"$tmp/log"; then
    echo "install.test > expected a conflict to fail" >&2
    exit 1
fi
grep -q 'not replacing .*/agent-stop' "$tmp/log"
[ "$(cat "$tmp/prefix/bin/agent-stop")" = mine ]

echo "install.test > ok"

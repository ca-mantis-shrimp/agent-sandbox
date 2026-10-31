#!/bin/sh
# agent-mailbox on a synthetic queue and inbox: the forced command never runs
# what the outside agent sends, and writes only inside its own inbox.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_QUEUE="$tmp/queue" AGENT_MAILBOX="$tmp/mailbox"
mkdir -p "$AGENT_QUEUE/to-muse/incoming"
printf '{"id":"t1"}\n' >"$AGENT_QUEUE/to-muse/incoming/t1.json"
printf '{"id":"t2"}\n' >"$AGENT_QUEUE/to-muse/incoming/t2.json"
box() { SSH_ORIGINAL_COMMAND=$1 sh "$tool/bin/agent-mailbox" muse; }
refused() { # <ssh command>; must fail and leave no stray file behind
    if printf 'x\n' | box "$1" >"$tmp/out" 2>"$tmp/err"; then
        echo "unexpected success: $1" >&2; exit 1
    fi
    [ -s "$tmp/err" ]
}
inbox="$AGENT_MAILBOX/muse"

# tasks lists the queued ids; get prints one task as queued.
[ "$(box tasks)" = "$(printf 't1\nt2')" ]
box 'get t1' | cmp - "$AGENT_QUEUE/to-muse/incoming/t1.json"
refused 'get t3'
refused 'get ../incoming/t1'

# put stores stdin as the report, or under a given name, and never overwrites.
printf '# report\n' | box 'put t1' 2>/dev/null
printf '# report\n' | cmp - "$inbox/t1/report.md"
printf 'a,b\n' | box 'put t1 data.csv' 2>/dev/null
[ "$(cat "$inbox/t1/data.csv")" = 'a,b' ]
refused 'put t1'
[ "$(cat "$inbox/t1/report.md")" = '# report' ]

# Names cannot leave the inbox or hide; nothing in a command is evaluated.
refused 'put ../escape'
refused 'put t1 ../../escape'
refused 'put .hidden'
refused 'put t1 a/b'
refused "put t1; touch $tmp/pwned"
refused "tasks \$(touch $tmp/pwned)"
refused 'tasks *'
refused ''
refused 'sh'
for f in "$tmp/pwned" "$AGENT_MAILBOX/escape" "$tmp/escape"; do
    [ ! -e "$f" ] || { echo "wrote outside the inbox: $f" >&2; exit 1; }
done

# Oversized content is refused and leaves no partial file.
AGENT_MAILBOX_MAX_FILE=8 SSH_ORIGINAL_COMMAND='put t2' sh "$tool/bin/agent-mailbox" muse \
    <"$AGENT_QUEUE/to-muse/incoming/t1.json" 2>/dev/null && { echo 'oversize accepted' >&2; exit 1; }
[ -z "$(ls -A "$inbox/t2" 2>/dev/null)" ]

# Every call is logged on one line, control characters made visible.
box "$(printf 'bogus\nforged line')" 2>/dev/null || :
[ "$(grep -c 'forged line' "$inbox/calls.log")" -eq 1 ]
if grep -qx 'forged line' "$inbox/calls.log"; then
    echo 'log line forged' >&2; exit 1
fi
echo 'agent-mailbox.test > ok'

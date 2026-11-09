#!/bin/sh
# agent-status --held, with unit state supplied by a PATH stub.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_RUNS="$tmp/runs" TEST_STATE="$tmp/state" TEST_LOG="$tmp/log"
mkdir -p "$tmp/bin"
printf '%s\n' '#!/bin/sh' 'echo "$*" >>"$TEST_LOG"' \
    'case "$*" in *"-p ActiveState --value") cat "$TEST_STATE" ;; *) exit 2 ;; esac' >"$tmp/bin/systemctl"
chmod +x "$tmp/bin/systemctl"
export PATH="$tmp/bin:$tool/bin:$PATH"
repo="$tmp/repo with spaces"
git init -q "$repo"
git -C "$repo" config user.name t
git -C "$repo" config user.email t@t
ln -s "$repo" "$tmp/alias"
fails() { if "$@"; then echo "expected failure: $*" >&2; exit 1; fi; }
not_held() {
    code=0
    agent-status --held "$1" >"$tmp/out" || code=$?
    [ "$code" -eq 3 ] && [ ! -s "$tmp/out" ]
}
# No run directory, no sessions and no units: not held.
not_held "$repo"
[ ! -e "$TEST_LOG" ]
[ ! -e "$TEST_LOG" ]
mkdir -p "$AGENT_RUNS/a/sessions" "$AGENT_RUNS/b/sessions" "$AGENT_RUNS/other/sessions"
for ws in a b; do
    jq -n --arg repo "$tmp/alias" '{repo:$repo,state:"ready"}' >"$AGENT_RUNS/$ws/manifest.json"
done
jq -n --arg repo "$tmp" '{repo:$repo}' >"$AGENT_RUNS/other/manifest.json"
echo '{"n":1,"state":"running"}' >"$AGENT_RUNS/other/sessions/1.json"
echo active >"$TEST_STATE"
not_held "$repo"
[ ! -e "$TEST_LOG" ]
# A deleted scratch origin must not poison unrelated hold checks or commits.
mkdir -p "$AGENT_RUNS/deleted/sessions"
jq -n --arg repo "$tmp/deleted/scratch/repo" '{repo:$repo}' >"$AGENT_RUNS/deleted/manifest.json"
echo '{"n":1,"state":"running"}' >"$AGENT_RUNS/deleted/sessions/1.json"
not_held "$repo"
[ ! -e "$TEST_LOG" ]
# An inaccessible origin is not proof of absence; keep failing closed.
mkdir -p "$tmp/private/origin"
jq -n --arg repo "$tmp/private/origin" '{repo:$repo}' >"$AGENT_RUNS/deleted/manifest.json"
ln -s "$tmp/private/origin" "$tmp/private-link"
chmod 000 "$tmp/private"
if [ ! -x "$tmp/private" ]; then
    for origin in "$tmp/private/origin" "$tmp/private-link"; do
        jq -n --arg repo "$origin" '{repo:$repo}' >"$AGENT_RUNS/deleted/manifest.json"
        code=0
        agent-status --held "$repo" >"$tmp/out" 2>"$tmp/error" || code=$?
        [ "$code" -eq 2 ]
    done
else
    echo 'SKIP: inaccessible-origin permissions cannot be tested as this user' >&2
fi
chmod 700 "$tmp/private"
# An unresolved symlink cannot prove absence: its target may be inaccessible.
ln -s "$tmp/absent-target" "$tmp/unresolved-link"
jq -n --arg repo "$tmp/unresolved-link" '{repo:$repo}' >"$AGENT_RUNS/deleted/manifest.json"
code=0
agent-status --held "$repo" >"$tmp/out" 2>"$tmp/error" || code=$?
[ "$code" -eq 2 ]
# Bad manifest data must still fail closed, even for an unrelated workspace.
for origin in relative ''; do
    jq -n --arg repo "$origin" '{repo:$repo}' >"$AGENT_RUNS/deleted/manifest.json"
    code=0
    agent-status --held "$repo" >"$tmp/out" 2>"$tmp/error" || code=$?
    [ "$code" -eq 2 ]
done
printf '{\n' >"$AGENT_RUNS/deleted/manifest.json"
# Keep the deleted origin present throughout the remaining active-holder checks.
jq -n --arg repo "$tmp/deleted/scratch/repo" '{repo:$repo}' >"$AGENT_RUNS/deleted/manifest.json"
# Readers alone do not hold or query units, even with an unavailable manager.
echo '{"n":1,"state":"running","read_only":true}' >"$AGENT_RUNS/a/sessions/1.json"
echo '{"n":2,"state":"finished"}' >"$AGENT_RUNS/a/sessions/2.json"
echo '' >"$TEST_STATE"
not_held "$repo"
[ ! -e "$TEST_LOG" ]
# Still validate records alongside readers; corruption must fail closed.
echo '{' >"$AGENT_RUNS/a/sessions/2.json"
# A writer alongside a reader holds; legacy records count as writers too.
echo active >"$TEST_STATE"
echo '{"n":2,"state":"running","read_only":false}' >"$AGENT_RUNS/a/sessions/2.json"
echo '{"n":1,"state":"running"}' >"$AGENT_RUNS/b/sessions/1.json"
[ "$(agent-status --held "$tmp/alias")" = "$(printf 'a\tactive\nb\tactive')" ]
# Known stopped states release stale records, without reconciliation writes.
for state in inactive failed; do
    echo "$state" >"$TEST_STATE"
    not_held "$repo"
done
# Startup, shutdown and manager silence retain the hold.
for state in activating deactivating ''; do
    echo "$state" >"$TEST_STATE"
    [ "$(agent-status --held "$repo")" = "$(printf 'a\t%s\nb\t%s' "${state:-unavailable}" "${state:-unavailable}")" ]
done
# Even an unsuccessful query that prints inactive is not proof of a stop.
printf '%s\n' '#!/bin/sh' 'echo inactive; exit 1' >"$tmp/bin/systemctl"
[ "$(agent-status --held "$repo")" = "$(printf 'a\tunavailable\nb\tunavailable')" ]
printf '%s\n' '#!/bin/sh' 'cat "$TEST_STATE"' >"$tmp/bin/systemctl"
# Finished records do not hold even if a unit reports active.
echo active >"$TEST_STATE"
for ws in a b; do echo '{"n":1,"state":"finished"}' >"$AGENT_RUNS/$ws/sessions/1.json"; done
echo '{"n":2,"state":"finished"}' >"$AGENT_RUNS/a/sessions/2.json"
not_held "$repo"
fails agent-status --held >"$tmp/out" 2>"$tmp/error"
fails agent-status --held "$tmp/missing" >"$tmp/out" 2>"$tmp/error"
# Corruption in any record must propagate, including before a valid record.
for corrupt in '{' '' 'null'; do
    printf '%s\n' "$corrupt" >"$AGENT_RUNS/a/sessions/1.json"
    code=0
    agent-status --held "$repo" >"$tmp/out" 2>"$tmp/error" || code=$?
    [ "$code" -eq 2 ]
done
echo '{"n":1,"state":"finished"}' >"$AGENT_RUNS/a/sessions/1.json"
echo "held tests passed"

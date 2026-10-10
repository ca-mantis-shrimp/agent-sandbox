#!/bin/sh
# Held checks and real Git hooks, with unit state supplied by a PATH stub.
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
    [ "$code" -eq 1 ] && [ ! -s "$tmp/out" ]
}
# No run directory, no sessions and no units: hook must never block.
not_held "$repo"
[ ! -e "$TEST_LOG" ]
[ ! -e "$repo/.git/hooks/pre-commit" ]
agent-doctor --install-hooks "$repo"
agent-doctor --install-hooks "$repo"
git -C "$repo" commit -q --allow-empty -m no-runs
[ ! -e "$TEST_LOG" ]
mkdir -p "$AGENT_RUNS/a/sessions" "$AGENT_RUNS/b/sessions" "$AGENT_RUNS/other/sessions"
for ws in a b; do
    jq -n --arg repo "$tmp/alias" '{repo:$repo,state:"ready"}' >"$AGENT_RUNS/$ws/manifest.json"
done
jq -n --arg repo "$tmp" '{repo:$repo}' >"$AGENT_RUNS/other/manifest.json"
echo '{"n":1,"state":"running"}' >"$AGENT_RUNS/other/sessions/1.json"
echo active >"$TEST_STATE"
not_held "$repo"
git -C "$repo" commit -q --allow-empty -m no-sessions
[ ! -e "$TEST_LOG" ]
# Readers hold too; multiple matching workspaces are printed once each.
echo '{"n":1,"state":"running","read_only":true}' >"$AGENT_RUNS/a/sessions/1.json"
echo '{"n":2,"state":"finished"}' >"$AGENT_RUNS/a/sessions/2.json"
echo '{"n":1,"state":"running"}' >"$AGENT_RUNS/b/sessions/1.json"
[ "$(agent-status --held "$tmp/alias")" = "$(printf 'a\nb')" ]
fails git -C "$repo" commit -q --allow-empty -m refused 2>"$tmp/error"
grep -q 'repository held by workspace(s)' "$tmp/error"
grep -qx a "$tmp/error"
grep -qx b "$tmp/error"
grep -q 'git commit --no-verify' "$tmp/error"
git -C "$repo" commit -q --no-verify --allow-empty -m human-override
# Known stopped states release stale records, without reconciliation writes.
for state in inactive failed; do
    echo "$state" >"$TEST_STATE"
    not_held "$repo"
    git -C "$repo" commit -q --allow-empty -m released
done
# Startup, shutdown and manager silence retain the hold.
for state in activating deactivating ''; do
    echo "$state" >"$TEST_STATE"
    [ "$(agent-status --held "$repo")" = "$(printf 'a\nb')" ]
done
# Finished records do not hold even if a unit reports active.
echo active >"$TEST_STATE"
for ws in a b; do echo '{"n":1,"state":"finished"}' >"$AGENT_RUNS/$ws/sessions/1.json"; done
not_held "$repo"
git -C "$repo" commit -q --allow-empty -m finished
fails agent-status --held >"$tmp/out" 2>"$tmp/error"
fails agent-status --held "$tmp/missing" >"$tmp/out" 2>"$tmp/error"
# Do not overwrite an existing hook, including one selected by core.hooksPath.
git -C "$repo" config core.hooksPath 'custom hooks'
mkdir "$repo/custom hooks"
echo human-hook >"$repo/custom hooks/pre-commit"
fails agent-doctor --install-hooks "$repo" 2>"$tmp/error"
[ "$(cat "$repo/custom hooks/pre-commit")" = human-hook ]
rm "$repo/custom hooks/pre-commit"
agent-doctor --install-hooks "$repo"
[ -x "$repo/custom hooks/pre-commit" ]
git -C "$repo" commit -q --allow-empty -m custom-hooks
# A check error is not the no-hold exit code and the hook refuses it.
echo '{}' >"$AGENT_RUNS/a/manifest.json"
code=0
agent-status --held "$repo" >"$tmp/out" 2>"$tmp/error" || code=$?
[ "$code" -eq 2 ]
fails git -C "$repo" commit -q --allow-empty -m check-error 2>"$tmp/error"
grep -q 'cannot check repository holds' "$tmp/error"
printf 'claim-guard tests passed\n'

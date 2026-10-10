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
    [ "$code" -eq 3 ] && [ ! -s "$tmp/out" ]
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
# Readers alone do not hold or query units, even with an unavailable manager.
echo '{"n":1,"state":"running","read_only":true}' >"$AGENT_RUNS/a/sessions/1.json"
echo '{"n":2,"state":"finished"}' >"$AGENT_RUNS/a/sessions/2.json"
echo '' >"$TEST_STATE"
not_held "$repo"
git -C "$repo" commit -q --allow-empty -m reader-only
[ ! -e "$TEST_LOG" ]
# Still validate records alongside readers; corruption must fail closed.
echo '{' >"$AGENT_RUNS/a/sessions/2.json"
fails git -C "$repo" commit -q --allow-empty -m corrupt-reader 2>"$tmp/error"
grep -q 'cannot check repository holds' "$tmp/error"
# A writer alongside a reader holds; legacy records count as writers too.
echo active >"$TEST_STATE"
echo '{"n":2,"state":"running","read_only":false}' >"$AGENT_RUNS/a/sessions/2.json"
echo '{"n":1,"state":"running"}' >"$AGENT_RUNS/b/sessions/1.json"
[ "$(agent-status --held "$tmp/alias")" = "$(printf 'a\tactive\nb\tactive')" ]
fails git -C "$repo" commit -q --allow-empty -m refused 2>"$tmp/error"
grep -q 'repository held by workspace(s)' "$tmp/error"
grep -qx "$(printf 'a\tactive')" "$tmp/error"
grep -qx "$(printf 'b\tactive')" "$tmp/error"
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
    [ "$(agent-status --held "$repo")" = "$(printf 'a\t%s\nb\t%s' "${state:-unavailable}" "${state:-unavailable}")" ]
done
# Even an unsuccessful query that prints inactive is not proof of a stop.
printf '%s\n' '#!/bin/sh' 'echo inactive; exit 1' >"$tmp/bin/systemctl"
[ "$(agent-status --held "$repo")" = "$(printf 'a\tunavailable\nb\tunavailable')" ]
fails git -C "$repo" commit -q --allow-empty -m unavailable 2>"$tmp/error"
printf '%s\n' '#!/bin/sh' 'cat "$TEST_STATE"' >"$tmp/bin/systemctl"
# Finished records do not hold even if a unit reports active.
echo active >"$TEST_STATE"
for ws in a b; do echo '{"n":1,"state":"finished"}' >"$AGENT_RUNS/$ws/sessions/1.json"; done
echo '{"n":2,"state":"finished"}' >"$AGENT_RUNS/a/sessions/2.json"
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
# Corruption in any record must propagate, including before a valid record.
for corrupt in '{' '' 'null'; do
    printf '%s\n' "$corrupt" >"$AGENT_RUNS/a/sessions/1.json"
    code=0
    agent-status --held "$repo" >"$tmp/out" 2>"$tmp/error" || code=$?
    [ "$code" -eq 2 ]
    fails git -C "$repo" commit -q --allow-empty -m corrupt 2>"$tmp/error"
    grep -q 'cannot check repository holds' "$tmp/error"
done
echo '{"n":1,"state":"finished"}' >"$AGENT_RUNS/a/sessions/1.json"
# A PATH impostor cannot bypass the installed checkout's hold check.
printf '%s\n' '#!/bin/sh' 'exit 3' >"$tmp/bin/agent-status"
chmod +x "$tmp/bin/agent-status"
echo '{"n":1,"state":"running","read_only":false}' >"$AGENT_RUNS/a/sessions/1.json"
fails git -C "$repo" commit -q --allow-empty -m path-impostor 2>"$tmp/error"
grep -q 'repository held' "$tmp/error"
rm "$tmp/bin/agent-status"
echo '{"n":1,"state":"finished"}' >"$AGENT_RUNS/a/sessions/1.json"
# Host Git needs no sandbox commands on PATH.
PATH="${PATH#"$tmp/bin:$tool/bin:"}" git -C "$repo" commit -q --allow-empty -m no-tool-path
# A check error is not the no-hold exit code and the hook refuses it.
echo '{}' >"$AGENT_RUNS/a/manifest.json"
code=0
agent-status --held "$repo" >"$tmp/out" 2>"$tmp/error" || code=$?
[ "$code" -eq 2 ]
fails git -C "$repo" commit -q --allow-empty -m check-error 2>"$tmp/error"
grep -q 'cannot check repository holds' "$tmp/error"
# Upgrade the old byte-copy by its marker, not by matching its implementation.
# A forwarding stub observes later updates without reinstalling. Quote paths too.
installed="$tmp/tool's checkout"
mkdir -p "$installed/bin" "$installed/lib"
cp "$tool/bin/agent-doctor" "$installed/bin/agent-doctor"
cp "$tool/lib/agent-pre-commit.sh" "$repo/custom hooks/pre-commit"
printf '%s\n' 'exit 1' >"$installed/lib/agent-pre-commit.sh"
"$installed/bin/agent-doctor" --install-hooks "$repo"
grep -q 'exec sh' "$repo/custom hooks/pre-commit"
fails git -C "$repo" commit -q --allow-empty -m upgraded
printf '%s\n' 'exit 0' >"$installed/lib/agent-pre-commit.sh"
git -C "$repo" commit -q --allow-empty -m live-update
"$installed/bin/agent-doctor" --install-hooks "$repo"
git -C "$repo" commit -q --allow-empty -m repeat-upgrade
# Real implementation resolves its sibling bin, including quoted checkout paths.
cp "$tool/lib/agent-pre-commit.sh" "$installed/lib/agent-pre-commit.sh"
printf '%s\n' '#!/bin/sh' 'exit 3' >"$installed/bin/agent-status"
chmod +x "$installed/bin/agent-status"
git -C "$repo" commit -q --allow-empty -m sibling-status
# Unexpected exit 1 and a missing sibling both fail closed; no PATH fallback.
printf '%s\n' '#!/bin/sh' 'set -e' 'false' >"$installed/bin/agent-status"
fails git -C "$repo" commit -q --allow-empty -m aborted 2>"$tmp/error"
grep -q 'cannot check repository holds' "$tmp/error"
rm "$installed/bin/agent-status"
fails git -C "$repo" commit -q --allow-empty -m missing-status 2>"$tmp/error"
grep -q 'cannot check repository holds' "$tmp/error"
rm "$installed/lib/agent-pre-commit.sh"
fails git -C "$repo" commit -q --allow-empty -m missing-checkout 2>"$tmp/error"
# Even a symlink to a marked hook is not ours to replace.
mv "$repo/custom hooks/pre-commit" "$tmp/marked-hook"
ln -s "$tmp/marked-hook" "$repo/custom hooks/pre-commit"
fails agent-doctor --install-hooks "$repo" 2>"$tmp/error"
[ -L "$repo/custom hooks/pre-commit" ]
printf 'claim-guard tests passed\n'

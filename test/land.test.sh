#!/bin/sh
#
# Tests agent-land against a throwaway repo with one submodule: a red
# gate moves no real branch, a moved branch stops the landing before anything
# advances, a green gate lands the merge with the right pin and cleans up, and
# a repo without submodules lands too.
# systemctl is stubbed; gate dispatch runs locally, not in a host sandbox.
# Real image mounts and isolation must still be verified on the host.
set -eu

tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_RUNS="$tmp/runs" GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
export AGENT_BASE="$tmp/base" AGENT_LAYERS="$tmp/images" XDG_RUNTIME_DIR="$tmp/runtime"
mkdir -p "$AGENT_BASE" "$AGENT_LAYERS" "$tmp/bin"
touch "$AGENT_LAYERS/harness.raw" "$AGENT_LAYERS/fixture.raw" "$AGENT_LAYERS/plain.raw"
# Landing prepares the same unit identity records as a worker run.
printf '%s\n' '#!/bin/sh' \
    'case "$*" in' \
    '  "passwd agent") echo "agent:x:731:812:Agent:/home/agent:/usr/bin/nologin" ;;' \
    '  "group agents") echo "agents:x:812:" ;;' \
    '  *) exit 2 ;;' \
    'esac' >"$tmp/bin/getent"
chmod +x "$tmp/bin/getent"
printf '%s\n' '#!/bin/sh' \
    'case "$*" in' \
    '  *"-p ActiveState --value") echo inactive ;;' \
    '  "--no-ask-password start "*)' \
    '    for l in "$AGENT_LAYERS"/.build/*.lock; do' \
    '      if flock -n -x "$l" true; then echo "free $l"; else echo "held $l"; fi' \
    '    done >>"$LOCK_LOG"' \
    '    gl="$XDG_RUNTIME_DIR/agent-sandbox/${3#agent@}"; gl=${gl%.service}.lock' \
    '    if flock -n -x "$gl" true; then echo "free $gl"; else echo "held $gl"; fi >>"$GATE_LOG"' \
    '    ws=${3#agent@}; ws=${ws%.service}' \
    '    AGENT_JOB="$AGENT_RUNS/$ws"; export AGENT_JOB' \
    '    set -a; . "$AGENT_JOB/run.env"; set +a' \
    '    "$AGENT_JOB/agents/session" "$AGENT_SESSION" || true ;;' \
    '  *"-p Result"*)' \
    '    ws=${2#agent@}; ws=${ws%.service}' \
    '    status=$(cat "$AGENT_RUNS/$ws/gate.status")' \
    '    if [ "$status" = 0 ]; then result=success; else result=exit-code; fi' \
    '    printf "Result=%s\nExecMainCode=1\nExecMainStatus=%s\n" "$result" "$status" ;;' \
    '  *) exit 1 ;;' \
    'esac' >"$tmp/bin/systemctl"
chmod +x "$tmp/bin/systemctl"
# The candidate workspace lock must also be held while landing cleans up.
real_git=$(command -v git)
printf '%s\n' '#!/bin/sh' \
    'case "$*" in' \
    '  *"update-ref refs/agent/candidate/interrupted/base"*)' \
    '    if [ "${INTERRUPT_RECORDING:-false}" = true ]; then exit 1; fi ;;' \
    '  *"branch -q -d"*)' \
    '    gl="$XDG_RUNTIME_DIR/agent-sandbox/land-green.lock"' \
    '    if [ -f "$gl" ]; then' \
    '      if flock -n -x "$gl" true; then echo "free cleanup" >>"$GATE_LOG"; else echo "held cleanup" >>"$GATE_LOG"; fi' \
    '    fi ;;' \
    'esac' \
    "exec $real_git \"\$@\"" >"$tmp/bin/git"
chmod +x "$tmp/bin/git"
export PATH="$tmp/bin:$PATH"
# agent-layer is stubbed in a copy of the tool: the gate must never build real layers.
real=$tool tool=$tmp/tool
mkdir -p "$tool" && cp -R "$real/bin" "$real/lib" "$real/agents" "$tool/"
printf '%s\n' '#!/bin/sh' 'echo "$1 $2 $3 $(cat "$3/mkosi.conf" 2>/dev/null)" >>"$LAYER_LOG"' \
    'printf "{\"name\":\"%s\"}\n" "$2" >"$AGENT_LAYERS/$2.build.json"' >"$tool/bin/agent-layer"
chmod +x "$tool/bin/agent-layer"
export LAYER_LOG="$tmp/layer-log" LOCK_LOG="$tmp/lock-log" GATE_LOG="$tmp/gate-log"

commit() { # <repo> <file> <content>
    printf '%s\n' "$3" >"$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -q -m "$2: $3"
}
head_of() { git -C "$1" rev-parse HEAD; }
# set -e ignores a failing `! cmd`, so negative assertions go through this.
fails() {
    if "$@"; then
        echo "agent-land.test > expected to fail: $*" >&2
        exit 1
    fi
}

# The fixture: repo "fixture" with submodule "sub", its landing gate the default
# .sandbox/gate, which passes.
git init -q -b main "$tmp/sub-src"
commit "$tmp/sub-src" state start
root="$tmp/fixture"
git init -q -b main "$root"
git -C "$root" -c protocol.file.allow=always submodule -q add "$tmp/sub-src" sub
sandboxed() { # <repo>: setup exports a value consumed by the gate
    mkdir -p "$1/.sandbox"
    printf 'export SETUP_PROOF=yes\n' >"$1/.sandbox/setup"
    printf '#!/bin/sh\n[ "$SETUP_PROOF" = yes ]\n[ -d "$AGENT_JOB/cache" ]\n' >"$1/.sandbox/gate"
    chmod +x "$1/.sandbox/gate"
    git -C "$1" add -A
    git -C "$1" commit -q -m fixture
}
sandboxed "$root"
git -C "$root/sub" switch -q main

# A harvested workspace: branch agent/<id> in the root repo and the submodule.
workspace() { # <id>
    mkdir -p "$AGENT_RUNS/$1"
    printf '{"repo":"%s"}\n' "$root" >"$AGENT_RUNS/$1/manifest.json"
    git -C "$root/sub" switch -q -c "agent/$1"
    commit "$root/sub" state "$1"
    git -C "$root/sub" switch -q main
    git -C "$root" switch -q -c "agent/$1"
    commit "$root" note "$1"
    git -C "$root" switch -q main
}
# Run from inside the fixture; the manifest, not cwd, selects the repository.
land() { # <id> [gate]: agent-land's exit status
    (cd "$root" && AGENT_LAND_GATE=${2:-.sandbox/gate} "$tool/bin/agent-land" "$1") >"$tmp/land.stdout" 2>"$tmp/land.log"
}

# --- detached checkouts stop before cloning; a corrected rerun lands ----------

workspace detached
before_root=$(head_of "$root") before_sub=$(head_of "$root/sub")
git -C "$root" switch -q --detach
fails land detached
grep -q 'fixture is on a detached HEAD' "$tmp/land.log"
[ ! -e "$AGENT_RUNS/land-detached/work" ]
git -C "$root" switch -q main
git -C "$root/sub" switch -q --detach
fails land detached
grep -q 'sub is on a detached HEAD' "$tmp/land.log"
[ ! -e "$AGENT_RUNS/land-detached/work" ]
[ "$(head_of "$root")" = "$before_root" ]
[ "$(head_of "$root/sub")" = "$before_sub" ]
git -C "$root/sub" switch -q main
land detached
! grep -Eiq 'fatal:|error:' "$tmp/land.log"
[ "$(cat "$root/note")" = detached ]
[ "$(cat "$root/sub/state")" = detached ]
[ "$(git -C "$root" rev-parse HEAD:sub)" = "$(head_of "$root/sub")" ]
[ -z "$(git -C "$root" status --porcelain)" ]
[ ! -e "$AGENT_RUNS/land-detached/work" ]

# --- an interrupted build is not reused just because its directory exists ----

workspace incomplete
partial="$AGENT_RUNS/land-incomplete/work"
(. "$tool/lib/agent-runs.sh" && clone_local "$root" "$partial")
git -C "$partial" update-ref refs/agent/land-base HEAD
# Only the root was marked before the build stopped; no completion marker.
[ ! -f "$partial/.git/agent-land-built" ]
land incomplete
grep -q 'removing incomplete candidate' "$tmp/land.log"
! grep -Eiq 'fatal:|error:' "$tmp/land.log"
[ "$(cat "$root/note")" = incomplete ]
[ "$(cat "$root/sub/state")" = incomplete ]
[ "$(git -C "$root" rev-parse HEAD:sub)" = "$(head_of "$root/sub")" ]
[ ! -e "$partial" ]

# --- interrupted checkpoint recording is completed on a rerun ---------------

workspace interrupted
before_root=$(head_of "$root") before_sub=$(head_of "$root/sub")
fails env INTERRUPT_RECORDING=true "$tool/bin/agent-land" interrupted
[ "$(head_of "$root")" = "$before_root" ]
[ "$(head_of "$root/sub")" = "$before_sub" ]
# Interruption left only a submodule tip; the root was not recorded first.
git -C "$root/sub" rev-parse -q --verify refs/agent/candidate/interrupted/tip >/dev/null
fails git -C "$root/sub" rev-parse -q --verify refs/agent/candidate/interrupted/base >/dev/null
fails git -C "$root" rev-parse -q --verify refs/agent/candidate/interrupted/tip >/dev/null
# Also exercise the old root-first partial state: root has both, sub lacks base.
partial="$AGENT_RUNS/land-interrupted/work"
git -C "$root" fetch -q "$partial" +HEAD:refs/agent/candidate/interrupted/tip
git -C "$root" update-ref refs/agent/candidate/interrupted/base "$before_root"
land interrupted
[ "$(cat "$root/note")" = interrupted ]
[ "$(cat "$root/sub/state")" = interrupted ]
[ -z "$(git -C "$root" for-each-ref refs/agent/candidate/interrupted)" ]
[ -z "$(git -C "$root/sub" for-each-ref refs/agent/candidate/interrupted)" ]

# --- conflicting human edits stop landing without discarding them ------------

workspace dirty
before_root=$(head_of "$root") before_sub=$(head_of "$root/sub")
printf 'human edit\n' >"$root/sub/state"
fails land dirty
[ "$(cat "$root/sub/state")" = 'human edit' ]
[ "$(head_of "$root")" = "$before_root" ]
[ "$(head_of "$root/sub")" = "$before_sub" ]
git -C "$root/sub" restore state
land dirty
[ "$(cat "$root/sub/state")" = dirty ]

# --- a red gate moves no real branch ------------------------------------------

workspace red
before_root=$(head_of "$root") before_sub=$(head_of "$root/sub")
fails land red false
[ "$(head_of "$root")" = "$before_root" ]
[ "$(head_of "$root/sub")" = "$before_sub" ]
[ -d "$AGENT_RUNS/land-red/work" ] && [ -s "$AGENT_RUNS/red/gate.log" ]
git -C "$root" rev-parse -q --verify refs/heads/agent/red >/dev/null

# --- a branch that moved after the candidate was built stops everything -------

commit "$root" elsewhere moved
moved_root=$(head_of "$root")
fails land red true
grep -q "moved since the candidate was built" "$tmp/land.log"
[ "$(head_of "$root")" = "$moved_root" ]
[ "$(head_of "$root/sub")" = "$before_sub" ]

# --- a green gate lands, pins the merged submodule, and cleans up -------------

workspace green
# An agent holding either legacy lock cannot prevent host landing.
mkdir -p "$AGENT_RUNS/green" "$AGENT_RUNS/land-green"
exec 3>"$AGENT_RUNS/green/.lock"
exec 4>"$AGENT_RUNS/land-green/.lock"
flock 3
flock 4
: >"$LAYER_LOG"
: >"$LOCK_LOG"
: >"$GATE_LOG"
# An image without a build record is still mounted, so its lock is still held.
touch "$AGENT_LAYERS/$(basename "$root").raw"
land green
[ -f "$XDG_RUNTIME_DIR/agent-sandbox/green.lock" ]
[ -f "$XDG_RUNTIME_DIR/agent-sandbox/land-green.lock" ]
flock -u 3
flock -u 4
sub_head=$(head_of "$root/sub")
fails git -C "$root/sub" merge-base --is-ancestor agent/red HEAD
[ "$(cat "$root/sub/state")" = green ]
[ "$(git -C "$root" rev-parse HEAD:sub)" = "$sub_head" ]
[ "$(cat "$root/note")" = green ]
# No recipe at the base commit: harness only, and the gate records the builds it ran on.
[ "$(cat "$LAYER_LOG")" = "harness harness $tool/layers/harness " ]
# The layers' shared lock was held while the unit started, and is released after.
[ "$(sort "$LOCK_LOG")" = "held $AGENT_LAYERS/.build/$(basename "$root").lock
held $AGENT_LAYERS/.build/harness.lock" ]
flock -n -x "$AGENT_LAYERS/.build/harness.lock" true
flock -n -x "$AGENT_LAYERS/.build/$(basename "$root").lock" true
# The candidate's workspace lock stayed held through unit start and landing cleanup.
grep -qx "held $XDG_RUNTIME_DIR/agent-sandbox/land-green.lock" "$GATE_LOG"
grep -qx 'held cleanup' "$GATE_LOG"
! grep -q '^free' "$GATE_LOG"
[ -z "$(git -C "$root" status --porcelain)" ]
fails git -C "$root" rev-parse -q --verify refs/heads/agent/green >/dev/null
fails git -C "$root/sub" rev-parse -q --verify refs/heads/agent/green >/dev/null
[ ! -d "$AGENT_RUNS/land-green/work" ]

# --- a workspace clone: unharvested commits refuse, an untouched repo lands ---

# Only the root repo has commits, so harvest fetched nothing from sub and the
# real sub has no agent/root-only branch.
work="$AGENT_RUNS/root-only/work"
(. "$tool/lib/agent-runs.sh" && clone_local "$root" "$work")
git -C "$work" switch -q -c agent/root-only
git -C "$work/sub" switch -q -c agent/root-only
for p in . sub; do
    git -C "$work/$p" update-ref refs/agent/base HEAD
    git -C "$work/$p" update-ref refs/agent/session-1 HEAD
done
mkdir -p "$AGENT_RUNS/root-only/sessions"
printf '{"id":"root-only", "repo":"%s"}\n' "$root" >"$AGENT_RUNS/root-only/manifest.json"
echo '{"n":1,"read_only":false}' >"$AGENT_RUNS/root-only/sessions/1.json"
export_root_only() {
    AGENT_JOB="$AGENT_RUNS/root-only" AGENT_HARNESS=claude sh "$tool/agents/session" 1 --export
}
commit "$work" note root-only
git -C "$root" fetch -q "$work" agent/root-only:agent/root-only
commit "$work/sub" state unharvested
export_root_only
before_root=$(head_of "$root")
fails land root-only
grep -q "not harvested" "$tmp/land.log"
[ "$(head_of "$root")" = "$before_root" ]
git -C "$work/sub" reset -q --hard HEAD~1
export_root_only
land root-only
[ "$(cat "$root/note")" = root-only ]
[ ! -d "$work" ]

# --- failed review advisories warn without changing a successful landing ------

workspace advisory
mkdir -p "$AGENT_RUNS/advisory" "$tmp/bin"
jq -n --arg repo "$root" '{repo: $repo}' >"$AGENT_RUNS/advisory/manifest.json"
real_jq=$(command -v jq)
export real_jq
# Fail only the advisory expressions; workspace loading and manifest updates
# still use the real jq, as does every non-advisory operation.
printf '%s\n' '#!/bin/sh' \
    'for arg do' \
    '    case "$arg" in' \
    '        *blocking_review_lines*|*select\(.human_verdict*) exit 1 ;;' \
    '    esac' \
    'done' \
    'exec "$real_jq" "$@"' >"$tmp/bin/jq"
chmod +x "$tmp/bin/jq"
# The manifest names the repo, so this lands from outside any checkout.
(cd "$tmp" && PATH="$tmp/bin:$PATH" "$tool/bin/agent-land" advisory) >"$tmp/land.log" 2>&1
grep -q 'warning: could not display blocking review findings' "$tmp/land.log"
grep -q 'warning: could not display the human verdict reminder' "$tmp/land.log"
[ "$(cat "$root/note")" = advisory ]
[ "$(cat "$root/sub/state")" = advisory ]
[ "$(git -C "$root" rev-parse HEAD:sub)" = "$(head_of "$root/sub")" ]
[ ! -d "$AGENT_RUNS/land-advisory/work" ]
jq -e '.landed != null and .gate.ok == true
    and .gate.layers == {harness: {name: "harness"}, project: null}' "$AGENT_RUNS/advisory/manifest.json" >/dev/null

# --- a repo without submodules lands the same way -----------------------------

plain="$tmp/plain"
git init -q -b main "$plain"
sandboxed "$plain"
mkdir -p "$plain/.sandbox/layer"
echo plainrecipe >"$plain/.sandbox/layer/mkosi.conf"
git -C "$plain" add -A
git -C "$plain" commit -q -m recipe
git -C "$plain" switch -q -c agent/plain
commit "$plain" note plain
git -C "$plain" switch -q main
: >"$LAYER_LOG"
# Non-conflicting tracked human edits survive a successful fast-forward.
printf '# human edit\n' >>"$plain/.sandbox/setup"
cp "$plain/.sandbox/setup" "$tmp/human-setup"
mkdir -p "$AGENT_RUNS/plain"
printf '{"repo":"%s"}\n' "$plain" >"$AGENT_RUNS/plain/manifest.json"
(cd "$plain" && "$tool/bin/agent-land" plain) >"$tmp/land.log" 2>&1
[ "$(sed -n 1p "$LAYER_LOG")" = "harness harness $tool/layers/harness " ]
sed -n 2p "$LAYER_LOG" | grep -q '^project plain /.*/\.sandbox/layer plainrecipe$'
[ "$(cat "$plain/note")" = plain ]
cmp "$plain/.sandbox/setup" "$tmp/human-setup"
git -C "$plain" restore .sandbox/setup
[ -z "$(git -C "$plain" status --porcelain)" ]
fails git -C "$plain" rev-parse -q --verify refs/heads/agent/plain >/dev/null

echo "agent-land.test > ok"

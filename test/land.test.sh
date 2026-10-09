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
export AGENT_BASE="$tmp/base" AGENT_LAYERS="$tmp/images"
mkdir -p "$AGENT_BASE" "$AGENT_LAYERS" "$tmp/bin"
touch "$AGENT_LAYERS/harness.raw" "$AGENT_LAYERS/fixture.raw" "$AGENT_LAYERS/plain.raw"
printf '%s\n' '#!/bin/sh' \
    'case "$*" in' \
    '  *"-p ActiveState --value") echo inactive ;;' \
    '  "--no-ask-password start "*)' \
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
export PATH="$tmp/bin:$PATH"

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
    git -C "$root/sub" switch -q -c "agent/$1"
    commit "$root/sub" state "$1"
    git -C "$root/sub" switch -q main
    git -C "$root" switch -q -c "agent/$1"
    commit "$root" note "$1"
    git -C "$root" switch -q main
}
# Run from inside the fixture: a workspace without a manifest naming its repo
# lands into the caller's checkout.
land() { # <id> [gate]: agent-land's exit status
    (cd "$root" && AGENT_LAND_GATE=${2:-.sandbox/gate} "$tool/bin/agent-land" "$1") >"$tmp/land.log" 2>&1
}

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
land green
sub_head=$(head_of "$root/sub")
fails git -C "$root/sub" merge-base --is-ancestor agent/red HEAD
[ "$(cat "$root/sub/state")" = green ]
[ "$(git -C "$root" rev-parse HEAD:sub)" = "$sub_head" ]
[ "$(cat "$root/note")" = green ]
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
commit "$work" note root-only
git -C "$root" fetch -q "$work" agent/root-only:agent/root-only
commit "$work/sub" state unharvested
before_root=$(head_of "$root")
fails land root-only
grep -q "not harvested" "$tmp/land.log"
[ "$(head_of "$root")" = "$before_root" ]
git -C "$work/sub" reset -q --hard HEAD~1
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
jq -e '.landed != null and .gate.ok == true' "$AGENT_RUNS/advisory/manifest.json" >/dev/null

# --- a repo without submodules lands the same way -----------------------------

plain="$tmp/plain"
git init -q -b main "$plain"
sandboxed "$plain"
git -C "$plain" switch -q -c agent/plain
commit "$plain" note plain
git -C "$plain" switch -q main
(cd "$plain" && "$tool/bin/agent-land" plain) >"$tmp/land.log" 2>&1
[ "$(cat "$plain/note")" = plain ]
[ -z "$(git -C "$plain" status --porcelain)" ]
fails git -C "$plain" rev-parse -q --verify refs/heads/agent/plain >/dev/null

echo "agent-land.test > ok"

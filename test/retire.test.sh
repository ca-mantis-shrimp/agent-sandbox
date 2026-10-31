#!/bin/sh
# Retiring a workspace discards only empty work, refuses live or committed work,
# and keeps the session record needed to explain why it stopped.
set -eu
for v in $(env | sed -n 's/^\(AGENT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_RUNS="$tmp/runs" XDG_RUNTIME_DIR="$tmp/runtime" \
    GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
mkdir -p "$AGENT_RUNS" "$tmp/bin"
printf '%s\n' '#!/bin/sh' \
    'case "$*" in' \
    '  *"-p ActiveState --value"*) printf "%s\\n" "${UNIT_STATE:-inactive}" ;;' \
    '  *) exit 1 ;;' \
    'esac' >"$tmp/bin/systemctl"
chmod +x "$tmp/bin/systemctl"
PATH="$tmp/bin:$PATH"
export PATH

commit() { # repo, file, content, subject
    printf '%s\n' "$3" >"$1/$2"
    git -C "$1" add "$2"
    git -C "$1" commit -q -m "$4"
}
fails() {
    if "$@"; then echo "retire.test > expected failure: $*" >&2; exit 1; fi
}
fails_with_path() { # expected path, command and args
    expected=$1
    shift
    if "$@" >"$tmp/stdout" 2>"$tmp/stderr"; then
        echo "retire.test > expected failure: $*" >&2
        exit 1
    fi
    if ! grep -F "$expected" "$tmp/stderr" >/dev/null; then
        echo "retire.test > expected refusal to name $expected: $(cat "$tmp/stderr")" >&2
        exit 1
    fi
}

# Root plus submodule ensure every repo is checked against its own base ref.
git init -q -b main "$tmp/sub-source"
commit "$tmp/sub-source" state start start
git init -q -b main "$tmp/origin"
printf 'root start\n' >"$tmp/origin/root-file"
git -C "$tmp/origin" add root-file
git -C "$tmp/origin" commit -q -m 'root start'
git -C "$tmp/origin" -c protocol.file.allow=always submodule -q add "$tmp/sub-source" sub
git -C "$tmp/origin" commit -q -m initial

make_workspace() { # id: a ready clone and session evidence
    id=$1
    mkdir -p "$AGENT_RUNS/$id/sessions" "$AGENT_RUNS/$id/prompts" "$AGENT_RUNS/$id/transcripts"
    printf '{"id":"%s","repo":"%s","state":"ready","started":"%s"}\n' \
        "$id" "$tmp/origin" "$(date -Iseconds)" >"$AGENT_RUNS/$id/manifest.json"
    git -c protocol.file.allow=always clone -q "$tmp/origin" "$AGENT_RUNS/$id/work"
    git -C "$AGENT_RUNS/$id/work" -c protocol.file.allow=always submodule update -q --init --recursive
    git -C "$AGENT_RUNS/$id/work" switch -q -c "agent/$id"
    git -C "$AGENT_RUNS/$id/work" update-ref refs/agent/base HEAD
    git -C "$AGENT_RUNS/$id/work/sub" update-ref refs/agent/base HEAD
    printf '{"n":1,"state":"failed:startup","read_only":false}\n' >"$AGENT_RUNS/$id/sessions/1.json"
    printf 'prompt\n' >"$AGENT_RUNS/$id/prompts/1.md"
    printf '{}\n' >"$AGENT_RUNS/$id/transcripts/1.jsonl"
    mkdir -p "$AGENT_RUNS/land-$id/work"
    printf 'candidate\n' >"$AGENT_RUNS/land-$id/work/marker"
}

make_workspace running
UNIT_STATE=active fails "$tool/bin/agent-retire" running
[ -d "$AGENT_RUNS/running/work" ]
[ -d "$AGENT_RUNS/land-running/work" ]

make_workspace root-work
commit "$AGENT_RUNS/root-work/work" changed committed 'work made'
fails "$tool/bin/agent-retire" root-work
[ -d "$AGENT_RUNS/root-work/work" ]
[ -d "$AGENT_RUNS/land-root-work/work" ]

make_workspace sub-work
commit "$AGENT_RUNS/sub-work/work/sub" changed committed 'submodule work made'
fails "$tool/bin/agent-retire" sub-work
[ -d "$AGENT_RUNS/sub-work/work" ]

# Refuse dirty changes in each repository, both tracked and untracked, and name its path.
make_workspace root-dirty
printf 'root changed\n' >"$AGENT_RUNS/root-dirty/work/root-file"
fails_with_path '.' "$tool/bin/agent-retire" root-dirty
[ -d "$AGENT_RUNS/root-dirty/work" ]

make_workspace root-untracked
printf 'untracked\n' >"$AGENT_RUNS/root-untracked/work/untracked-file"
fails_with_path '.' "$tool/bin/agent-retire" root-untracked
[ -d "$AGENT_RUNS/root-untracked/work" ]

make_workspace sub-dirty
printf 'sub changed\n' >"$AGENT_RUNS/sub-dirty/work/sub/state"
fails_with_path 'sub' "$tool/bin/agent-retire" sub-dirty
[ -d "$AGENT_RUNS/sub-dirty/work" ]

make_workspace sub-untracked
printf 'untracked\n' >"$AGENT_RUNS/sub-untracked/work/sub/untracked-file"
fails_with_path 'sub' "$tool/bin/agent-retire" sub-untracked
[ -d "$AGENT_RUNS/sub-untracked/work" ]

make_workspace empty
"$tool/bin/agent-retire" empty
[ ! -e "$AGENT_RUNS/empty/work" ]
[ ! -e "$AGENT_RUNS/land-empty" ]
[ -f "$AGENT_RUNS/empty/sessions/1.json" ]
[ -f "$AGENT_RUNS/empty/prompts/1.md" ]
[ -f "$AGENT_RUNS/empty/transcripts/1.jsonl" ]
jq -e '.retired and .state == "retired"' "$AGENT_RUNS/empty/manifest.json" >/dev/null
status_output=$("$tool/bin/agent-status")
if printf '%s\n' "$status_output" | grep -q '^empty '; then
    echo 'retired workspace still appears in agent-status' >&2; exit 1
fi

# A running record is a refusal even if the manager has stopped: reconcile first.
make_workspace recorded-running
printf '{"n":2,"state":"running","read_only":false}\n' >"$AGENT_RUNS/recorded-running/sessions/2.json"
fails "$tool/bin/agent-retire" recorded-running
[ -d "$AGENT_RUNS/recorded-running/work" ]

make_workspace corrupt-record
printf '{invalid json\n' >"$AGENT_RUNS/corrupt-record/sessions/2.json"
fails "$tool/bin/agent-retire" corrupt-record
[ -d "$AGENT_RUNS/corrupt-record/work" ]

echo 'retire.test > ok'

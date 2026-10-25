#!/bin/sh
# Exercise the entry point with fake harnesses, never host units or models.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_JOB="$tmp/srv/job/workspace" AGENT_HARNESS=claude AGENT_MODEL=test
export PI_CODING_AGENT_DIR="$AGENT_JOB/pi"
mkdir -p "$AGENT_JOB/work/.sandbox" "$AGENT_JOB/sessions" "$AGENT_JOB/prompts" "$AGENT_JOB/transcripts" "$tmp/bin" "$tmp/credentials"
printf '{"prompt":"prompts/1.md"}\n' >"$AGENT_JOB/sessions/1.json"
echo prompt >"$AGENT_JOB/prompts/1.md"
git -C "$AGENT_JOB/work" init -q -b agent/workspace
git -C "$AGENT_JOB/work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$AGENT_JOB/work" update-ref refs/agent/base HEAD
echo '{"id":"workspace"}' >"$AGENT_JOB/manifest.json"
printf '%s\n' '#!/bin/sh' \
    'printf "%s" "${CLAUDE_CODE_OAUTH_TOKEN:-missing}" >"$AGENT_JOB/token-seen"' \
    'printf "%s" "$2" >"$AGENT_JOB/seen-prompt"' \
    'echo '\''{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0}'\''' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH" CREDENTIALS_DIRECTORY="$tmp/credentials"
echo credential-token >"$CREDENTIALS_DIRECTORY/agent.claude_token"
"$tool/agents/session" 1
[ "$(cat "$AGENT_JOB/token-seen")" = credential-token ]
jq -e '.ok and .closing == "done"' "$AGENT_JOB/sessions/1.json" >/dev/null
jq -e --arg head "$(git -C "$AGENT_JOB/work" rev-parse HEAD)" '.head_at_start["."] == $head' "$AGENT_JOB/sessions/1.json" >/dev/null

# Fixers use conventional test-first subjects and keep Tests: as a legacy form.
grep -Fq 'Commit tests first, with a subject starting `test:` or `test(<scope>):`;' "$tool/agents/run-kinds/fix.md"
grep -Fq '`Tests:` is supported for legacy commits.' "$tool/agents/run-kinds/fix.md"
grep -Fq 'later non-test commits must not touch files an earlier test commit touched.' "$tool/agents/run-kinds/fix.md"

# A recognized kind contract comes from the agents snapshot and precedes both
# the writable project's standing prompt and the caller's prompt.
printf 'project guidance\n' >"$AGENT_JOB/work/.sandbox/prompt.md"
printf 'Run kind: work\nDo the task\n' >"$AGENT_JOB/prompts/1.md"
"$tool/agents/session" 1
{
    cat "$tool/agents/run-kinds/work.md"
    printf '\nproject guidance\n\nRun kind: work\nDo the task\n'
} >"$tmp/expected-prompt"
[ "$(cat "$tmp/expected-prompt")" = "$(cat "$AGENT_JOB/seen-prompt")" ]

# The documented one-line form uses only the first plain-word token as kind.
printf 'Run kind: review. Target: this workspace branch.\n' >"$AGENT_JOB/prompts/1.md"
"$tool/agents/session" 1
{
    cat "$tool/agents/run-kinds/review.md"
    printf '\nproject guidance\n\nRun kind: review. Target: this workspace branch.\n'
} >"$tmp/expected-prompt"
[ "$(cat "$tmp/expected-prompt")" = "$(cat "$AGENT_JOB/seen-prompt")" ]

# CR and trailing whitespace do not invalidate an otherwise plain-word kind.
printf 'Run kind: work \r\nDo the task\n' >"$AGENT_JOB/prompts/1.md"
"$tool/agents/session" 1
{
    cat "$tool/agents/run-kinds/work.md"
    printf '\nproject guidance\n\nRun kind: work \r\nDo the task\n'
} >"$tmp/expected-prompt"
[ "$(cat "$tmp/expected-prompt")" = "$(cat "$AGENT_JOB/seen-prompt")" ]

# Non-kind prompts retain the old project-prompt then task-prompt composition.
printf 'ordinary task\n' >"$AGENT_JOB/prompts/1.md"
"$tool/agents/session" 1
[ "$(cat "$AGENT_JOB/seen-prompt")" = 'project guidance

ordinary task' ]

# Empty, malformed and unknown kinds do not abort the session or select a path;
# unmatched contracts produce one diagnostic and leave the prompt intact.
for header in 'Run kind: ' 'Run kind: ../work' 'Run kind: mystery'; do
    printf '%s\nDo the task\n' "$header" >"$AGENT_JOB/prompts/1.md"
    "$tool/agents/session" 1 >"$tmp/no-contract.log" 2>&1
    [ "$(grep -c '^session > no run-kind contract for ' "$tmp/no-contract.log")" = 1 ]
    case "$header" in
        'Run kind: mystery') expected_kind=mystery ;;
        *) expected_kind= ;;
    esac
    grep -qx "session > no run-kind contract for $expected_kind" "$tmp/no-contract.log"
    {
        printf 'project guidance\n\n%s\nDo the task\n' "$header"
    } >"$tmp/expected-prompt"
    [ "$(cat "$tmp/expected-prompt")" = "$(cat "$AGENT_JOB/seen-prompt")" ]
done
rm "$AGENT_JOB/work/.sandbox/prompt.md"
printf 'prompt\n' >"$AGENT_JOB/prompts/1.md"
rm "$CREDENTIALS_DIRECTORY/agent.claude_token"
unset CLAUDE_CODE_OAUTH_TOKEN
"$tool/agents/session" 1
[ "$(cat "$AGENT_JOB/token-seen")" = missing ]

# Pi uses the unit's run-specific directory, not its default home directory.
mkdir -p "$PI_CODING_AGENT_DIR"
printf '%s\n' '#!/bin/sh' \
    '[ "$PI_CODING_AGENT_DIR" = "$AGENT_JOB/pi" ] || exit 1' \
    'printf "%s\n" "$@" >"$AGENT_JOB/pi-args"' \
    'echo '\''{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"pi done"}],"stopReason":"stop","usage":{"cost":{"total":0}}}}'\''' >"$tmp/bin/pi"
chmod +x "$tmp/bin/pi"
export AGENT_HARNESS=pi AGENT_PI_PROVIDER=test-provider
"$tool/agents/session" 1
jq -e '.ok and .closing == "pi done"' "$AGENT_JOB/sessions/1.json" >/dev/null
[ "$(awk '/^--provider$/ {getline; print}' "$AGENT_JOB/pi-args")" = test-provider ]
[ "$(awk '/^--model$/ {getline; print}' "$AGENT_JOB/pi-args")" = test ]

# A writer that fails in setup still exports its committed work on EXIT.
rm -rf "$AGENT_JOB/exports"
printf '%s\n' \
    'echo failed > committed' \
    'git add committed' \
    'git -c user.name=t -c user.email=t@t commit -q -m failed' \
    'exit 7' >"$AGENT_JOB/work/.sandbox/setup"
status=0
"$tool/agents/session" 1 || status=$?
[ "$status" = 7 ]
tip=$(git -C "$AGENT_JOB/work" rev-parse HEAD)
jq -e --arg tip "$tip" '.["."].session == [$tip]' "$AGENT_JOB/exports/1.json" >/dev/null
[ -s "$AGENT_JOB/exports/1/root.bundle" ]
rm "$AGENT_JOB/work/.sandbox/setup"

# TERM also ends through EXIT, exporting commits rather than losing them.
export AGENT_HARNESS=claude
rm -rf "$AGENT_JOB/exports"
printf '%s\n' '#!/bin/sh' \
    'echo stopped > committed' \
    'git add committed' \
    'git -c user.name=t -c user.email=t@t commit -q -m stopped' \
    'kill -TERM "$PPID"' >"$tmp/bin/claude"
status=0
"$tool/agents/session" 1 || status=$?
[ "$status" = 143 ]
tip=$(git -C "$AGENT_JOB/work" rev-parse HEAD)
jq -e --arg tip "$tip" '.["."].session == [$tip]' "$AGENT_JOB/exports/1.json" >/dev/null
[ -s "$AGENT_JOB/exports/1/root.bundle" ]

# A failed export is logged but does not spoil a normal result or its record.
rm -rf "$AGENT_JOB/exports"
touch "$AGENT_JOB/exports"
export AGENT_HARNESS=pi
"$tool/agents/session" 1 >"$tmp/export.log" 2>&1
grep -qx 'session > export failed' "$tmp/export.log"
jq -e '.ok and .closing == "pi done"' "$AGENT_JOB/sessions/1.json" >/dev/null
rm "$AGENT_JOB/exports"
# A Git failure inside the per-repo export loop must not be hidden by jq.
git -C "$AGENT_JOB/work" update-ref -d refs/agent/base
"$tool/agents/session" 1 >"$tmp/export.log" 2>&1
grep -qx 'session > export failed' "$tmp/export.log"
jq -e '.ok and .closing == "pi done"' "$AGENT_JOB/sessions/1.json" >/dev/null
[ ! -e "$AGENT_JOB/exports/1.json" ]
git -C "$AGENT_JOB/work" update-ref refs/agent/base HEAD

# Readers and gates export nothing, and readers create no start marker.
rm -rf "$AGENT_JOB/exports"
jq '.read_only=true' "$AGENT_JOB/sessions/1.json" >"$tmp/record"
mv "$tmp/record" "$AGENT_JOB/sessions/1.json"
git -C "$AGENT_JOB/work" update-ref -d refs/agent/session-1
"$tool/agents/session" 1
[ ! -e "$AGENT_JOB/exports" ]
if git -C "$AGENT_JOB/work" rev-parse -q --verify refs/agent/session-1; then exit 1; fi
# Head metadata is advisory: Git errors, invalid hashes, and jq reduction
# failures all yield null without stopping a reader or a writer's export.
real_git=$(command -v git)
real_jq=$(command -v jq)
printf '%s\n' '#!/bin/sh' \
    'case "${HEAD_FAILURE:-}:$*" in' \
    ' git:*rev-parse*HEAD*) exit 1 ;;' \
    ' submodule:submodule*rev-parse*) exit 1 ;;' \
    ' invalid:*rev-parse*HEAD*) echo HEAD; exit 0 ;;' \
    'esac' \
    "exec $real_git \"\$@\"" >"$tmp/bin/git"
printf '%s\n' '#!/bin/sh' \
    'if [ "${HEAD_FAILURE:-}" = jq ] && [ "$1" = -s ] && [ "${2:-}" = add ]; then exit 1; fi' \
    "exec $real_jq \"\$@\"" >"$tmp/bin/jq"
chmod +x "$tmp/bin/git" "$tmp/bin/jq"
for failure in git submodule invalid jq; do
 HEAD_FAILURE=$failure "$tool/agents/session" 1
 jq -e '.ok and .head_at_start == null' "$AGENT_JOB/sessions/1.json" >/dev/null
done
# A genuine unborn repository must not silently store the string HEAD.
mv "$AGENT_JOB/work/.git" "$tmp/saved-git"
git -C "$AGENT_JOB/work" init -q
"$tool/agents/session" 1
jq -e '.ok and .head_at_start == null' "$AGENT_JOB/sessions/1.json" >/dev/null
rm -rf "$AGENT_JOB/work/.git"
mv "$tmp/saved-git" "$AGENT_JOB/work/.git"
# Writers still reach the export trap after failed advisory capture.
jq '.read_only=false' "$AGENT_JOB/sessions/1.json" >"$tmp/record"
mv "$tmp/record" "$AGENT_JOB/sessions/1.json"
HEAD_FAILURE=submodule "$tool/agents/session" 1
jq -e '.ok and .head_at_start == null' "$AGENT_JOB/sessions/1.json" >/dev/null
[ -f "$AGENT_JOB/exports/1.json" ]
rm -rf "$AGENT_JOB/exports"
rm "$tmp/bin/git" "$tmp/bin/jq"
export AGENT_HARNESS=gate
unset AGENT_MODEL
printf 'export SETUP_PROOF=yes\n' >"$AGENT_JOB/work/.sandbox/setup"
printf '#!/bin/sh\n[ "$SETUP_PROOF" = yes ]\n' >"$AGENT_JOB/work/.sandbox/gate"
chmod +x "$AGENT_JOB/work/.sandbox/gate"
"$tool/agents/session" 0
[ "$(cat "$AGENT_JOB/gate.status")" = 0 ]
[ ! -e "$AGENT_JOB/exports" ]
AGENT_LAND_GATE=false "$tool/agents/session" 0 && exit 1
[ "$(cat "$AGENT_JOB/gate.status")" = 1 ]
printf 'exit 7\n' >"$AGENT_JOB/work/.sandbox/setup"
"$tool/agents/session" 0 && exit 1
[ "$(cat "$AGENT_JOB/gate.status")" = 7 ]
echo 'session tests passed'

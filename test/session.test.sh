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
    'echo '\''{"type":"result","subtype":"success","is_error":false,"result":"done","total_cost_usd":0}'\''' >"$tmp/bin/claude"
chmod +x "$tmp/bin/claude"
export PATH="$tmp/bin:$PATH" CREDENTIALS_DIRECTORY="$tmp/credentials"
echo credential-token >"$CREDENTIALS_DIRECTORY/agent.claude_token"
"$tool/agents/session" 1
[ "$(cat "$AGENT_JOB/token-seen")" = credential-token ]
jq -e '.ok and .closing == "done"' "$AGENT_JOB/sessions/1.json" >/dev/null
rm "$CREDENTIALS_DIRECTORY/agent.claude_token"
unset CLAUDE_CODE_OAUTH_TOKEN
"$tool/agents/session" 1
[ "$(cat "$AGENT_JOB/token-seen")" = missing ]

# Pi uses the unit's run-specific directory, not its default home directory.
mkdir -p "$PI_CODING_AGENT_DIR"
printf '%s\n' '#!/bin/sh' \
    '[ "$PI_CODING_AGENT_DIR" = "$AGENT_JOB/pi" ] || exit 1' \
    'echo '\''{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"pi done"}],"stopReason":"stop","usage":{"cost":{"total":0}}}}'\''' >"$tmp/bin/pi"
chmod +x "$tmp/bin/pi"
export AGENT_HARNESS=pi
"$tool/agents/session" 1
jq -e '.ok and .closing == "pi done"' "$AGENT_JOB/sessions/1.json" >/dev/null

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

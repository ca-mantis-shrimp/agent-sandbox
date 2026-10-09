#!/bin/sh
# Exercise the entry point with fake harnesses, never host units or models.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_JOB="$tmp/job" AGENT_HARNESS=claude AGENT_MODEL=test
mkdir -p "$AGENT_JOB/work/.sandbox" "$AGENT_JOB/sessions" "$AGENT_JOB/prompts" "$AGENT_JOB/transcripts" "$tmp/bin" "$tmp/credentials"
printf '{"prompt":"prompts/1.md"}\n' >"$AGENT_JOB/sessions/1.json"
echo prompt >"$AGENT_JOB/prompts/1.md"
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

export AGENT_HARNESS=gate
unset AGENT_MODEL
printf 'export SETUP_PROOF=yes\n' >"$AGENT_JOB/work/.sandbox/setup"
printf '#!/bin/sh\n[ "$SETUP_PROOF" = yes ]\n' >"$AGENT_JOB/work/.sandbox/gate"
chmod +x "$AGENT_JOB/work/.sandbox/gate"
"$tool/agents/session" 0
[ "$(cat "$AGENT_JOB/gate.status")" = 0 ]
AGENT_LAND_GATE=false "$tool/agents/session" 0 && exit 1
[ "$(cat "$AGENT_JOB/gate.status")" = 1 ]
printf 'exit 7\n' >"$AGENT_JOB/work/.sandbox/setup"
"$tool/agents/session" 0 && exit 1
[ "$(cat "$AGENT_JOB/gate.status")" = 7 ]
echo 'session tests passed'

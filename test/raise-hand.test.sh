#!/bin/sh
# Question files are an untrusted, plain-text handoff; exercise host and session sides.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_RUNS="$tmp/runs" AGENT_QUESTION_TIMEOUT_SECS=1
export AGENT_JOB="$AGENT_RUNS/ws"
mkdir -p "$AGENT_JOB/questions" "$AGENT_JOB/sessions" "$AGENT_JOB/transcripts" "$AGENT_JOB/work" "$tmp/bin"
printf '%s\n' '{"id":"ws","state":"ready","started":"2026-10-31T00:00:00Z"}' >"$AGENT_JOB/manifest.json"
printf '%s\n' '{"n":1,"state":"running","read_only":true}' >"$AGENT_JOB/sessions/1.json"
printf '%s\n' '#!/bin/sh' 'case "$*" in *"-p ActiveState --value") echo active ;; *) exit 2 ;; esac' >"$tmp/bin/systemctl"
chmod +x "$tmp/bin/systemctl"
export PATH="$tmp/bin:$tool/bin:$PATH"

# Ask creates a question outside work, waits, and returns the answer as text.
question=$(printf 'Where is it?\033[31m')
AGENT_SESSION=1 "$tool/agents/agent-ask" "$question" >"$tmp/answer-out" 2>"$tmp/ask-log" &
ask_pid=$!
i=0
while [ ! -f "$AGENT_JOB/questions/1.md" ]; do
    i=$((i + 1)); [ "$i" -lt 50 ] || { echo 'question was not created' >&2; exit 1; }
    sleep 0.1
done
[ "$(cat "$AGENT_JOB/questions/1.session")" = 1 ]
[ "$(cat "$AGENT_JOB/questions/1.md")" = "$question" ]
status=$(agent-status ws)
printf '%s\n' "$status" | grep -q 'ws waiting questions: 1'
printf '%s\n' "$status" | grep -q 'ws/1  Where is it?'
# The raw escape byte is not allowed into terminal output.
if printf '%s' "$status" | grep "$(printf '\033')" >/dev/null; then exit 1; fi
agent-answer ws/1 '42 and text only'
wait "$ask_pid"
[ "$(cat "$tmp/answer-out")" = '42 and text only' ]
if agent-answer ws/1 second >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
grep -q 'answer already exists or is unsafe' "$tmp/error"

# A timeout is non-zero and names the ordinary decision stop.
AGENT_SESSION=1 "$tool/agents/agent-ask" 'Need a decision' >"$tmp/timeout-out" 2>"$tmp/timeout-log" &
timeout_pid=$!
code=0
wait "$timeout_pid" || code=$?
[ "$code" -ne 0 ]
grep -q 'timed out; take the NEEDS DECISION stop' "$tmp/timeout-log"

# A planted answer symlink cannot write through to a host file.
printf '%s\n' 'planted question' >"$AGENT_JOB/questions/3.md"
printf '%s\n' 1 >"$AGENT_JOB/questions/3.session"
printf '%s\n' untouched >"$tmp/victim"
ln -s "$tmp/victim" "$AGENT_JOB/questions/3.answer"
if agent-answer ws/3 bad >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
[ "$(cat "$tmp/victim")" = untouched ]
grep -q 'answer already exists or is unsafe' "$tmp/error"
rm "$AGENT_JOB/questions/3.answer"
# Question symlinks and special files are never read by the host.
rm "$AGENT_JOB/questions/3.md"
ln -s "$tmp/victim" "$AGENT_JOB/questions/3.md"
if agent-answer ws/3 bad >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
grep -q 'refusing unsafe question' "$tmp/error"
rm "$AGENT_JOB/questions/3.md"
mkfifo "$AGENT_JOB/questions/3.md"
if agent-answer ws/3 bad >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
grep -q 'refusing unsafe question' "$tmp/error"
rm "$AGENT_JOB/questions/3.md"
# Oversized question and answer payloads are refused before content is read/written.
head -c 65537 /dev/zero | tr '\000' x >"$AGENT_JOB/questions/5.md"
printf '%s\n' 1 >"$AGENT_JOB/questions/5.session"
if agent-answer ws/5 bad >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
grep -q 'refusing unsafe question' "$tmp/error"
printf '%s\n' short >"$AGENT_JOB/questions/6.md"
printf '%s\n' 1 >"$AGENT_JOB/questions/6.session"
head -c 65537 /dev/zero | tr '\000' x >"$tmp/too-large"
if agent-answer ws/6 "$tmp/too-large" >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
grep -q 'answer exceeds 65536 bytes' "$tmp/error"
printf '%s\n' 1 >"$AGENT_JOB/sessions/1.json" # malformed record cannot make it a running question

# The host-side waiter wakes on a question from a running reader session.
printf '%s\n' '{"n":1,"state":"finished","read_only":true}' >"$AGENT_JOB/sessions/1.json"
printf '%s\n' '{"n":2,"state":"running","read_only":true}' >"$AGENT_JOB/sessions/2.json"
AGENT_QUESTION_POLL_SECS=1 agent-status --wait-question >"$tmp/wait-status" 2>&1 &
wait_pid=$!
sleep 0.2
printf '%s\n' 'Read-only review needs context' >"$AGENT_JOB/questions/4.md"
printf '%s\n' 2 >"$AGENT_JOB/questions/4.session"
wait "$wait_pid"
grep -q 'ws waiting questions: 1' "$tmp/wait-status"
grep -q 'ws/4  Read-only review needs context' "$tmp/wait-status"

# Ended sessions are no longer waiting, and malformed names are rejected.
printf '%s\n' '{"n":2,"state":"finished","read_only":true}' >"$AGENT_JOB/sessions/2.json"
if agent-answer ws/4 late >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
grep -q 'not from a running session' "$tmp/error"
if agent-answer '../ws/4' bad >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
if agent-answer 'ws/04' bad >"$tmp/out" 2>"$tmp/error"; then exit 1; fi

echo 'raise-hand tests passed'

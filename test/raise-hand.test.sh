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
cat >"$tmp/bin/dd" <<'EOF'
#!/bin/sh
for arg do
    case "$arg" in
        "if=${SWAP_QUESTION_FILE:-}")
            if [ -n "${SWAP_QUESTION_FILE:-}" ]; then
                rm -f -- "$SWAP_QUESTION_FILE"
                ln -s "$SWAP_VICTIM" "$SWAP_QUESTION_FILE"
            fi
            ;;
        */8.md|if=8.md)
            if [ -n "${SWAP_QUESTION_DIR:-}" ]; then
                mv "$AGENT_JOB/questions" "$SWAP_QUESTION_DIR"
                ln -s "$SWAP_QUESTION_TARGET" "$AGENT_JOB/questions"
                unset SWAP_QUESTION_DIR
            fi
            ;;
        */1.json|if=1.json)
            if [ -n "${SWAP_SESSION_DIR:-}" ]; then
                mv "$AGENT_JOB/sessions" "$SWAP_SESSION_DIR"
                ln -s "$SWAP_SESSION_TARGET" "$AGENT_JOB/sessions"
                unset SWAP_SESSION_DIR
            fi
            ;;
    esac
done
exec /usr/bin/dd "$@"
EOF
cat >"$tmp/bin/cat" <<'EOF'
#!/bin/sh
if [ -n "${SWAP_ANSWER_INPUT:-}" ] && [ "$1" = "$SWAP_ANSWER_INPUT" ]; then
    mv "$AGENT_JOB/questions" "$SWAP_QUESTION_DIR"
    ln -s "$SWAP_QUESTION_TARGET" "$AGENT_JOB/questions"
    unset SWAP_ANSWER_INPUT
fi
exec /bin/cat "$@"
EOF
chmod +x "$tmp/bin/dd" "$tmp/bin/cat"
export PATH="$tmp/bin:$tool/bin:$PATH"
. "$tool/lib/agent-questions.sh"
agent_unit_active() { return 0; }

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
[ -f "$AGENT_JOB/questions/2.timeout" ]
status=$(agent-status ws)
if printf '%s\n' "$status" | grep -q 'ws/2 '; then exit 1; fi
if agent-answer ws/2 late >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
grep -q 'timed out' "$tmp/error"

# The launcher rejects waits close enough to the unit deadline to risk a kill.
if AGENT_QUESTION_TIMEOUT_SECS=3601 AGENT_SESSION=1 \
    "$tool/agents/agent-ask" invalid >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
grep -q 'must not exceed 3600' "$tmp/error"

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
# Replace a checked regular file with a symlink precisely before dd opens it.
printf '%s\n' 'HOST_ONLY_SECRET' >"$tmp/victim"
printf '%s\n' 'ordinary question' >"$AGENT_JOB/questions/8.md"
printf '%s\n' 1 >"$AGENT_JOB/questions/8.session"
export SWAP_QUESTION_FILE="$AGENT_JOB/questions/8.md" SWAP_VICTIM="$tmp/victim"
waiting=$(waiting_questions "$AGENT_JOB" ws 2>"$tmp/error")
unset SWAP_QUESTION_FILE SWAP_VICTIM
if printf '%s\n' "$waiting" | grep -q 'HOST_ONLY_SECRET'; then exit 1; fi
grep -q 'refusing unsafe question' "$tmp/error"
rm "$AGENT_JOB/questions/8.md"
# The session record is likewise swapped after its regular-file check.
printf '%s\n' 'HOST_ONLY_SECRET_SESSION' >"$tmp/victim"
printf '%s\n' 'ordinary question' >"$AGENT_JOB/questions/9.md"
printf '%s\n' 1 >"$AGENT_JOB/questions/9.session"
export SWAP_QUESTION_FILE="$AGENT_JOB/sessions/1.json" SWAP_VICTIM="$tmp/victim"
waiting=$(waiting_questions "$AGENT_JOB" ws 2>"$tmp/error")
unset SWAP_QUESTION_FILE SWAP_VICTIM
if printf '%s\n' "$waiting" | grep -q 'HOST_ONLY_SECRET'; then exit 1; fi
grep -q 'refusing unsafe session record' "$tmp/error"
rm "$AGENT_JOB/sessions/1.json"
printf '%s\n' '{"n":1,"state":"running","read_only":true}' >"$AGENT_JOB/sessions/1.json"
rm "$AGENT_JOB/questions/9.md"

# Pinning questions/ must survive swapping the directory after the safety check.
mkdir "$tmp/attacker-questions"
printf '%s\n' 'HOST_ONLY_DIRECTORY_SECRET' >"$tmp/attacker-questions/8.md"
printf '%s\n' 1 >"$tmp/attacker-questions/8.session"
printf '%s\n' '{"n":1,"state":"running","read_only":true}' >"$tmp/attacker-questions/1.json"
printf '%s\n' 'ordinary question' >"$AGENT_JOB/questions/8.md"
printf '%s\n' 1 >"$AGENT_JOB/questions/8.session"
export SWAP_QUESTION_DIR="$tmp/questions-pinned" SWAP_QUESTION_TARGET="$tmp/attacker-questions"
waiting=$(waiting_questions "$AGENT_JOB" ws 2>"$tmp/error")
if printf '%s\n' "$waiting" | grep -q 'HOST_ONLY_DIRECTORY_SECRET'; then exit 1; fi
rm "$AGENT_JOB/questions"
mv "$tmp/questions-pinned" "$AGENT_JOB/questions"
unset SWAP_QUESTION_DIR SWAP_QUESTION_TARGET

# Pinning sessions/ must not let an attacker substitute a running record.
mkdir "$tmp/attacker-sessions"
printf '%s\n' '{"n":1,"state":"running","read_only":true}' >"$tmp/attacker-sessions/1.json"
printf '%s\n' 'ordinary question' >"$AGENT_JOB/questions/10.md"
printf '%s\n' 1 >"$AGENT_JOB/questions/10.session"
printf '%s\n' '{"n":1,"state":"finished","read_only":true}' >"$AGENT_JOB/sessions/1.json"
export SWAP_SESSION_DIR="$tmp/sessions-pinned" SWAP_SESSION_TARGET="$tmp/attacker-sessions"
if agent-answer ws/10 bad >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
rm "$AGENT_JOB/sessions"
mv "$tmp/sessions-pinned" "$AGENT_JOB/sessions"
unset SWAP_SESSION_DIR SWAP_SESSION_TARGET
printf '%s\n' '{"n":1,"state":"running","read_only":true}' >"$AGENT_JOB/sessions/1.json"

# The answer is created in the pinned questions directory, not a swapped target.
mkdir "$tmp/answer-target"
printf '%s\n' 'ordinary question' >"$AGENT_JOB/questions/11.md"
printf '%s\n' 1 >"$AGENT_JOB/questions/11.session"
printf '%s\n' answer >"$tmp/answer-input"
export SWAP_ANSWER_INPUT="$tmp/answer-input" SWAP_QUESTION_DIR="$tmp/questions-answer-pinned" SWAP_QUESTION_TARGET="$tmp/answer-target"
agent-answer ws/11 "$tmp/answer-input"
if [ -e "$tmp/answer-target/11.answer" ]; then exit 1; fi
[ "$(cat "$tmp/questions-answer-pinned/11.answer")" = answer ]
rm "$AGENT_JOB/questions"
mv "$tmp/questions-answer-pinned" "$AGENT_JOB/questions"
unset SWAP_ANSWER_INPUT SWAP_QUESTION_DIR SWAP_QUESTION_TARGET
mkfifo "$AGENT_JOB/questions/3.md"
if agent-answer ws/3 bad >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
grep -q 'refusing unsafe question' "$tmp/error"
# The host waiter must also refuse a FIFO without blocking on its open.
started=$(date +%s)
status=$(agent-status ws)
[ $(( $(date +%s) - started )) -lt 5 ]
if printf '%s\n' "$status" | grep -q 'ws/3 '; then exit 1; fi
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
# A FIFO session record must not block either question-side reader.
printf '%s\n' 'planted question' >"$AGENT_JOB/questions/7.md"
printf '%s\n' 1 >"$AGENT_JOB/questions/7.session"
rm "$AGENT_JOB/sessions/1.json"
mkfifo "$AGENT_JOB/sessions/1.json"
started=$(date +%s)
if agent-answer ws/7 bad >"$tmp/out" 2>"$tmp/error"; then exit 1; fi
[ $(( $(date +%s) - started )) -lt 5 ]
waiting=$(waiting_questions "$AGENT_JOB" ws)
[ -z "$waiting" ]
[ $(( $(date +%s) - started )) -lt 5 ]
rm "$AGENT_JOB/sessions/1.json"
printf '%s\n' '{"n":1,"state":"running","read_only":true}' >"$AGENT_JOB/sessions/1.json"

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

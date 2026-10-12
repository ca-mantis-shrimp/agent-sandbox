#!/bin/sh
# agent-usage on synthetic run directories only: no model, host unit or real transcript.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_RUNS="$tmp/runs"
run="$AGENT_RUNS/ws"
mkdir -p "$run/sessions" "$run/transcripts"
echo '{"repo":"/nowhere"}' >"$run/manifest.json"
# run.env must never be consulted: plant a misleading one.
echo 'AGENT_PI_PROVIDER=planted-provider' >"$run/run.env"
usage() { sh "$tool/bin/agent-usage" "$@"; }
check() { # <json> <jq-expr>
    printf '%s' "$1" | jq -e "$2" >/dev/null || { echo "FAILED: $2" >&2; printf '%s\n' "$1" >&2; exit 1; }
}
rec() { # <n> <json fields>
    printf '{"n":%s,%s}\n' "$1" "$2" >"$run/sessions/$1.json"
}

# 1: Claude. Preliminary assistant counters sum to 91; the final result says 8995.
rec 1 '"harness":"claude","model":"opus","state":"finished","outcome":"finished","ok":true'
cat >"$run/transcripts/1.jsonl" <<'J'
{"type":"system","subtype":"init","model":"claude-synth-1"}
{"type":"assistant","message":{"usage":{"input_tokens":3,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":40}}}
{"type":"assistant","message":{"usage":{"input_tokens":3,"cache_creation_input_tokens":10,"cache_read_input_tokens":20,"output_tokens":51}}}
{"type":"result","subtype":"success","is_error":false,"usage":{"input_tokens":12,"cache_creation_input_tokens":300,"cache_read_input_tokens":4000,"output_tokens":8995}}
J
out=$(usage ws/1)
check "$out" '.status == "reported" and .usage == {input_tokens:12, cache_creation_input_tokens:300,
    cache_read_input_tokens:4000, output_tokens:8995} and .source.ignored_assistant_events == 2
    and .observed_models == ["claude-synth-1"] and .harness == "claude" and .workspace == "ws" and .session == 1'
# Claude's route is not evidenced in its stream, so it stays unknown whatever run.env says.
check "$out" '.observed_providers == [] and .provider_evidence == null'

# 2: explicit zero counters are zero; an absent counter is null.
rec 2 '"harness":"claude","state":"finished"'
echo '{"type":"result","usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}}' >"$run/transcripts/2.jsonl"
out=$(usage ws/2)
check "$out" '.status == "reported" and .usage.input_tokens == 0 and .usage.output_tokens == 0
    and .usage.cache_read_input_tokens == 0 and .usage.cache_creation_input_tokens == null'

# 3: Claude without a result (killed): assistant counters are not used.
rec 3 '"harness":"claude","state":"failed","outcome":"stopped"'
echo '{"type":"assistant","message":{"usage":{"input_tokens":5,"output_tokens":9}}}' >"$run/transcripts/3.jsonl"
out=$(usage ws/3)
check "$out" '.status == "missing" and .reason == "no_result_event" and (.usage | all(. == null)) and .model_invoked == null'

# 4: multiple results are ambiguous, never summed or picked.
rec 4 '"harness":"claude","state":"finished"'
printf '%s\n%s\n' '{"type":"result","usage":{"output_tokens":1}}' '{"type":"result","usage":{"output_tokens":2}}' >"$run/transcripts/4.jsonl"
check "$(usage ws/4)" '.status == "ambiguous" and (.usage | all(. == null))'

# 5: truncated final line and a result without counters.
rec 5 '"harness":"claude","state":"failed","outcome":"failed:exit:1"'
printf '%s\n%s' '{"type":"assistant","message":{}}' '{"type":"result","usage":{"output_tok' >"$run/transcripts/5.jsonl"
check "$(usage ws/5)" '.status == "missing" and .malformed_lines == 1 and (.usage | all(. == null))'
rec 6 '"harness":"claude","state":"finished"'
echo '{"type":"result","subtype":"success","result":"x"}' >"$run/transcripts/6.jsonl"
check "$(usage ws/6)" '.status == "missing" and .reason == "result_without_usage"'
# Garbage that is valid JSON but not an object is malformed, not usage.
rec 14 '"harness":"claude","state":"finished"'
printf '%s\n' '42' 'not json' >"$run/transcripts/14.jsonl"
check "$(usage ws/14)" '.status == "missing" and .malformed_lines == 2'

# 7: pi, completed messages summed with the four counters kept apart; the
# partial delta events and a message_update's usage are ignored.
rec 7 '"harness":"pi","model":"m-req","state":"finished","outcome":"finished","ok":true'
cat >"$run/transcripts/7.jsonl" <<'J'
{"type":"message_update","message":{"role":"assistant","usage":{"input":999,"output":999,"cacheRead":999,"cacheWrite":999}}}
{"type":"message_end","message":{"role":"assistant","provider":"synth-route","model":"m-1","stopReason":"toolUse","usage":{"input":10,"output":20,"cacheRead":300,"cacheWrite":4,"totalTokens":334}}}
{"type":"message_end","message":{"role":"user","usage":{"input":777,"output":777,"cacheRead":0,"cacheWrite":0}}}
{"type":"message_end","message":{"role":"assistant","provider":"synth-route","model":"m-1","stopReason":"stop","usage":{"input":1,"output":2,"cacheRead":0,"cacheWrite":0}}}
J
out=$(usage ws/7)
check "$out" '.status == "reported" and .usage == {input_tokens:11, cache_creation_input_tokens:4,
    cache_read_input_tokens:300, output_tokens:22} and .record_model == "m-req"
    and .observed_providers == ["synth-route"] and .observed_models == ["m-1"]
    and (.provider_evidence | test("not account")) and .source.counted_messages == 2'
check "$out" '(.observed_providers | index("planted-provider")) == null'

# 8: pi with an aborted message and an unfinished session is partial, a lower bound.
rec 8 '"harness":"pi","state":"failed","outcome":"stopped"'
cat >"$run/transcripts/8.jsonl" <<'J'
{"type":"message_end","message":{"role":"assistant","stopReason":"stop","usage":{"input":5,"output":6,"cacheRead":0,"cacheWrite":0}}}
{"type":"message_end","message":{"role":"assistant","stopReason":"aborted","usage":{"input":50,"output":60,"cacheRead":0,"cacheWrite":0}}}
J
out=$(usage ws/8)
check "$out" '.status == "partial" and .usage.input_tokens == 5 and .source.excluded_error_or_aborted_messages == 1
    and (.reason | test("session_not_finished")) and .observed_providers == []'

# 9: pi with no completed assistant message, or messages lacking counters.
rec 9 '"harness":"pi","state":"finished"'
echo '{"type":"agent_start"}' >"$run/transcripts/9.jsonl"
check "$(usage ws/9)" '.status == "missing" and .reason == "no_assistant_message_end"'
rec 10 '"harness":"pi","state":"finished"'
echo '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","provider":"p","usage":{"input":1}}}' >"$run/transcripts/10.jsonl"
check "$(usage ws/10)" '.status == "missing" and .reason == "no_completed_message_with_counters" and .observed_providers == ["p"]'

# 11: start failure is explicit no-model evidence; zero is not fabricated;
# a running session is incomplete; a missing transcript is missing, not zero.
rec 11 '"harness":"claude","state":"failed","outcome":"failed:start"'
check "$(usage ws/11)" '.status == "no_model_invocation" and .model_invoked == false and (.usage | all(. == null))'
rec 12 '"harness":"pi","state":"running"'
check "$(usage ws/12)" '.status == "incomplete" and .model_invoked == null'
rec 13 '"harness":"claude","state":"failed","outcome":"failed:exit:1","transcript":"transcripts/gone.jsonl"'
check "$(usage ws/13)" '.status == "missing" and .reason == "transcript_unavailable" and .model_invoked == null'
# A record transcript path may not escape the run directory.
echo '{"type":"result","usage":{"output_tokens":1}}' >"$tmp/outside.jsonl"
rec 15 '"harness":"claude","state":"finished","transcript":"../../outside.jsonl"'
check "$(usage ws/15)" '.status == "missing"'
printf 'not json\n' >"$run/sessions/16.json"
check "$(usage ws/16)" '.status == "unreadable" and .usage == null'

# Mixed workspace: JSON valid, numeric session order, aggregate counts honest.
out=$(usage ws)
check "$out" '.workspace == "ws" and ([.sessions[].session] == [range(1;17)])'
check "$out" '.aggregate.sessions == 16 and .aggregate.reported == 3 and .aggregate.partial == 1
    and .aggregate.ambiguous == 1 and .aggregate.incomplete == 1 and .aggregate.no_model_invocation == 1
    and .aggregate.unreadable == 1 and .aggregate.missing == 8 and .aggregate.complete == false'
# Reported sessions are 1, 2 and 7; 2 states no cache_creation counter.
check "$out" '.aggregate.totals.output_tokens == {sum: 8995 + 0 + 22, observed_sessions: 3, missing_sessions: 0}
    and .aggregate.totals.cache_creation_input_tokens == {sum: 304, observed_sessions: 2, missing_sessions: 1}
    and .aggregate.totals.input_tokens.sum == 23'

# A fully reported workspace is complete; an empty one has no totals and is not complete.
mkdir -p "$AGENT_RUNS/ok/sessions" "$AGENT_RUNS/ok/transcripts" "$AGENT_RUNS/empty/sessions"
echo '{"repo":"/nowhere"}' | tee "$AGENT_RUNS/ok/manifest.json" >"$AGENT_RUNS/empty/manifest.json"
cp "$run/sessions/1.json" "$AGENT_RUNS/ok/sessions/1.json"
cp "$run/transcripts/1.jsonl" "$AGENT_RUNS/ok/transcripts/1.jsonl"
check "$(usage ok)" '.aggregate.complete == true and .aggregate.totals.output_tokens.sum == 8995'
check "$(usage empty)" '.aggregate.complete == false and .aggregate.sessions == 0 and .aggregate.totals.output_tokens.sum == null'

# Refusals print nothing on stdout.
for bad in nosuch ws/99 ws/x ../ws ws/1/2; do
    if usage "$bad" >"$tmp/o" 2>"$tmp/e"; then echo "unexpected success: $bad" >&2; exit 1; fi
    [ ! -s "$tmp/o" ] && [ -s "$tmp/e" ]
done
echo "usage tests passed"

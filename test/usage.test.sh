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
check "$out" '.status == "partial" and .usage.input_tokens == 55 and .source.error_or_aborted_messages == 1
    and (.reason | test("session_not_finished")) and .observed_providers == []'

# 9: pi with no completed assistant message, or messages lacking counters.
rec 9 '"harness":"pi","state":"finished"'
echo '{"type":"agent_start"}' >"$run/transcripts/9.jsonl"
check "$(usage ws/9)" '.status == "missing" and .reason == "no_assistant_message_end"'
rec 10 '"harness":"pi","state":"finished"'
echo '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","provider":"p","usage":{"input":1}}}' >"$run/transcripts/10.jsonl"
check "$(usage ws/10)" '.status == "partial" and .reason == "message_without_counters" and .usage.input_tokens == 1
    and .usage.output_tokens == null and .counters_complete == false and .observed_providers == ["p"]'

# 11: start failure is explicit no-model evidence; zero is not fabricated;
# a running session is incomplete; a missing transcript is missing, not zero.
rec 11 '"harness":"claude","state":"failed","outcome":"failed:start"'
check "$(usage ws/11)" '.status == "missing" and .start_failed == true and .model_invoked == null and (.usage | all(. == null))'
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
check "$out" '.aggregate.sessions == 16 and .aggregate.reported == 3
    and .aggregate.ambiguous == 1 and .aggregate.incomplete == 1 and .aggregate.partial == 2
    and .aggregate.unreadable == 1 and .aggregate.missing == 8 and .aggregate.complete == false'
# Reported sessions are 1, 2 and 7; 2 states no cache_creation counter.
check "$out" '(.aggregate.totals.output_tokens | .sum == 8995 + 0 + 22 and .observed_sessions == 3 and .missing_sessions == 0)
    and (.aggregate.totals.cache_creation_input_tokens | .sum == 304 and .observed_sessions == 2 and .missing_sessions == 1)
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

# --- review regressions, in their own workspace ---
neg="$AGENT_RUNS/neg"
mkdir -p "$neg/sessions" "$neg/transcripts"
echo '{"repo":"/nowhere"}' >"$neg/manifest.json"
nrec() { printf '{"n":%s,%s}\n' "$1" "$2" >"$neg/sessions/$1.json"; }
nusage() { sh "$tool/bin/agent-usage" "$@"; }

# failed:start with transcript consumption is reported, never "no model".
nrec 1 '"harness":"claude","state":"failed","outcome":"failed:start"'
echo '{"type":"result","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}' >"$neg/transcripts/1.jsonl"
check "$(nusage neg/1)" '.status == "reported" and .start_failed == true and .model_invoked == true and .usage.output_tokens == 4'

# An aborted-only pi session keeps its stated consumption as partial.
nrec 2 '"harness":"pi","state":"failed","outcome":"stopped"'
echo '{"type":"message_end","message":{"role":"assistant","stopReason":"aborted","usage":{"input":50,"output":60,"cacheRead":0,"cacheWrite":0}}}' >"$neg/transcripts/2.jsonl"
check "$(nusage neg/2)" '.status == "partial" and .usage.input_tokens == 50 and .usage.output_tokens == 60 and (.reason | test("error_or_aborted"))'

# Hostile valid JSON: the row stays, later sessions survive, exit is 0.
nrec 3 '"harness":"pi","state":"finished"'
printf '%s\n' '{"type":"message_end","message":"hostile"}' '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","usage":"x"}}' >"$neg/transcripts/3.jsonl"
check "$(nusage neg/3)" '.status == "missing" and .source.malformed_message_ends == 1'
nrec 4 '"harness":"claude","state":"finished"'
echo '{"type":"result","usage":{"input_tokens":-1,"cache_creation_input_tokens":1.5,"cache_read_input_tokens":"7","output_tokens":null}}' >"$neg/transcripts/4.jsonl"
check "$(nusage neg/4)" '.status == "missing" and .reason == "result_counters_invalid" and (.usage | all(. == null))'
nrec 5 '"harness":["pi"],"state":{"x":1},"model":3,"ok":"yes"'
check "$(nusage neg/5)" '.harness == null and .state == null and .record_model == null and .ok == null and .status == "missing"'
printf '{"n":6}\n{"n":6}\n' >"$neg/sessions/6.json"
check "$(nusage neg/6)" '.status == "unreadable" and .reason == "record_unreadable"'
nrec 7 '"harness":"claude","state":"finished"'
echo '{"type":"result","usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1,"output_tokens":1}}' >"$neg/transcripts/7.jsonl"
out=$(nusage neg) || { echo "workspace read failed" >&2; exit 1; }
check "$out" '[.sessions[].session] == [1,2,3,4,5,6,7] and .aggregate.sessions == 7 and .aggregate.complete == false'

# Reported with unknown counters is not complete; a truncated extra line next to a result is not complete.
mkdir -p "$AGENT_RUNS/cx/sessions" "$AGENT_RUNS/cx/transcripts"
echo '{"repo":"/nowhere"}' >"$AGENT_RUNS/cx/manifest.json"
printf '{"n":1,"harness":"claude","state":"finished"}\n' >"$AGENT_RUNS/cx/sessions/1.json"
echo '{"type":"result","usage":{"output_tokens":0}}' >"$AGENT_RUNS/cx/transcripts/1.jsonl"
out=$(usage cx)
check "$out" '.sessions[0].status == "reported" and .sessions[0].counters_complete == false and .aggregate.complete == false
    and .aggregate.totals.input_tokens.unobserved_sessions == 1 and .aggregate.totals.input_tokens.missing_sessions == 1'
cp "$run/transcripts/1.jsonl" "$AGENT_RUNS/cx/transcripts/1.jsonl"
printf '%s' '{"type":"result","usage":{"input_tok' >>"$AGENT_RUNS/cx/transcripts/1.jsonl"
check "$(usage cx/1)" '.status == "partial" and (.reason | test("malformed_lines")) and .usage.output_tokens == 8995'
check "$(usage cx)" '.aggregate.complete == false and .aggregate.totals.output_tokens.sum == null and .aggregate.totals.output_tokens.lower_bound_sum == 8995'

# pi duplicates: identified repeats count once (partial); unidentified repeats are ambiguous;
# distinct calls with equal usage are both counted; pending/absent stopReason is partial.
u='"usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4}'
mkdir -p "$AGENT_RUNS/dp/sessions" "$AGENT_RUNS/dp/transcripts"
echo '{"repo":"/nowhere"}' >"$AGENT_RUNS/dp/manifest.json"
for i in 1 2 3 4; do printf '{"n":%s,"harness":"pi","state":"finished"}\n' $i >"$AGENT_RUNS/dp/sessions/$i.json"; done
m1='{"type":"message_end","message":{"role":"assistant","stopReason":"stop","timestamp":1,'"$u"'}}'
m2='{"type":"message_end","message":{"role":"assistant","stopReason":"stop","timestamp":2,'"$u"'}}'
mn='{"type":"message_end","message":{"role":"assistant","stopReason":"stop",'"$u"'}}'
printf '%s\n%s\n' "$m1" "$m1" >"$AGENT_RUNS/dp/transcripts/1.jsonl"
check "$(usage dp/1)" '.status == "partial" and .usage.input_tokens == 1 and .source.duplicate_messages_dropped == 1'
printf '%s\n%s\n' "$mn" "$mn" >"$AGENT_RUNS/dp/transcripts/2.jsonl"
check "$(usage dp/2)" '.status == "ambiguous" and (.usage | all(. == null))'
printf '%s\n%s\n' "$m1" "$m2" >"$AGENT_RUNS/dp/transcripts/3.jsonl"
check "$(usage dp/3)" '.status == "reported" and .usage.input_tokens == 2 and .usage.output_tokens == 4'
echo '{"type":"message_end","message":{"role":"assistant","timestamp":1,'"$u"'}}' >"$AGENT_RUNS/dp/transcripts/4.jsonl"
check "$(usage dp/4)" '.status == "partial" and (.reason | test("message_not_terminal")) and .usage.input_tokens == 1'

# Reads stay inside transcripts/: file and directory symlinks and other run files are refused.
# Synthetic outside data only.
mkdir -p "$AGENT_RUNS/sy/sessions" "$AGENT_RUNS/sy/transcripts" "$tmp/outdir" "$AGENT_RUNS/sy/pi"
echo '{"repo":"/nowhere"}' >"$AGENT_RUNS/sy/manifest.json"
good='{"type":"result","usage":{"input_tokens":9,"cache_creation_input_tokens":9,"cache_read_input_tokens":9,"output_tokens":9}}'
echo "$good" >"$tmp/outdir/1.jsonl"
echo "$good" >"$AGENT_RUNS/sy/pi/shared.json"
ln -s "$tmp/outdir/1.jsonl" "$AGENT_RUNS/sy/transcripts/1.jsonl"
ln -s "$tmp/outdir" "$AGENT_RUNS/sy/transcripts/d"
printf '{"n":1,"harness":"claude","state":"finished"}\n' >"$AGENT_RUNS/sy/sessions/1.json"
printf '{"n":2,"harness":"claude","state":"finished","transcript":"transcripts/d/1.jsonl"}\n' >"$AGENT_RUNS/sy/sessions/2.json"
printf '{"n":3,"harness":"claude","state":"finished","transcript":"pi/shared.json"}\n' >"$AGENT_RUNS/sy/sessions/3.json"
for i in 1 2 3; do check "$(usage sy/$i)" '.status == "missing" and .reason == "transcript_unavailable" and (.usage | all(. == null))'; done
mkdir -p "$tmp/real"; rm -rf "$AGENT_RUNS/sy/transcripts"; ln -s "$tmp/real" "$AGENT_RUNS/sy/transcripts"
printf '{"n":4,"harness":"claude","state":"finished"}\n' >"$AGENT_RUNS/sy/sessions/4.json"
echo "$good" >"$tmp/real/4.jsonl"
check "$(usage sy/4)" '.status == "missing" and .reason == "transcript_unavailable"'
# A session record that is a symlink out of sessions/ is unreadable.
ln -s "$tmp/real/4.jsonl" "$AGENT_RUNS/sy/sessions/5.json"
check "$(usage sy/5)" '.status == "unreadable"'

# A transcript that cannot be read still yields a row, and the workspace exits 0.
if [ "$(id -u)" != 0 ]; then
    printf '{"n":1,"harness":"claude","state":"finished"}\n' >"$AGENT_RUNS/cx/sessions/1.json"
    chmod 000 "$AGENT_RUNS/cx/transcripts/1.jsonl"
    out=$(usage cx) && check "$out" '.sessions[0].status == "missing" and .aggregate.sessions == 1'
    chmod 600 "$AGENT_RUNS/cx/transcripts/1.jsonl"
fi

# Sibling alias directories: sessions/ or transcripts/ symlinked to another run directory is refused.
mkdir -p "$AGENT_RUNS/al/pi" "$AGENT_RUNS/al/sessions" "$AGENT_RUNS/al2/pi"
echo '{"repo":"/nowhere"}' >"$AGENT_RUNS/al/manifest.json"
cp "$AGENT_RUNS/al/manifest.json" "$AGENT_RUNS/al2/manifest.json"
echo "$good" >"$AGENT_RUNS/al/pi/shared.json"
ln -s pi "$AGENT_RUNS/al/transcripts"
printf '{"n":1,"harness":"claude","state":"finished","transcript":"transcripts/shared.json"}\n' >"$AGENT_RUNS/al/sessions/1.json"
check "$(usage al/1)" '.status == "missing" and .reason == "transcript_unavailable" and (.usage | all(. == null))'
printf '{"n":1,"harness":"claude","state":"finished"}\n' >"$AGENT_RUNS/al2/pi/1.json"
ln -s pi "$AGENT_RUNS/al2/sessions"
check "$(usage al2/1)" '.status == "unreadable"'
if out=$(usage al2 2>/dev/null); then echo "FAIL aliased sessions enumerated"; exit 1; fi
[ -z "$out" ] || { echo "FAIL aliased sessions printed output"; exit 1; }

# An unenumerable sessions directory fails without stdout; it is not an empty workspace.
if [ "$(id -u)" != 0 ]; then
    mkdir -p "$AGENT_RUNS/ud/sessions"
    echo '{"repo":"/nowhere"}' >"$AGENT_RUNS/ud/manifest.json"
    printf '{"n":1,"harness":"claude","state":"finished"}\n' >"$AGENT_RUNS/ud/sessions/1.json"
    for mode in 000 100 300; do
        chmod $mode "$AGENT_RUNS/ud/sessions"
        if out=$(usage ud 2>/dev/null); then chmod 700 "$AGENT_RUNS/ud/sessions"; echo "FAIL chmod $mode enumerated"; exit 1; fi
        [ -z "$out" ] || { chmod 700 "$AGENT_RUNS/ud/sessions"; echo "FAIL chmod $mode printed output"; exit 1; }
    done
    chmod 700 "$AGENT_RUNS/ud/sessions"
    check "$(usage ud)" '.aggregate.sessions == 1'
fi
# Session identifiers are canonical positive decimals of at most 15 digits; aliases are refused, never counted twice.
reject() { # <args...>: nonzero, no stdout
    if out=$(usage "$@" 2>/dev/null); then echo "FAIL accepted: $*"; exit 1; fi
    [ -z "$out" ] || { echo "FAIL printed output: $*"; exit 1; }
}
mkid() { # <workspace>
    mkdir -p "$AGENT_RUNS/$1/sessions" "$AGENT_RUNS/$1/transcripts"
    echo '{"repo":"/nowhere"}' >"$AGENT_RUNS/$1/manifest.json"
}
idrec='{"n":1,"harness":"claude","state":"finished"}'
idtr='{"type":"result","usage":{"input_tokens":1,"cache_creation_input_tokens":1,"cache_read_input_tokens":1,"output_tokens":1}}'
mkid id1; printf '%s\n' "$idrec" >"$AGENT_RUNS/id1/sessions/1.json"; printf '%s\n' "$idrec" >"$AGENT_RUNS/id1/sessions/01.json"
echo "$idtr" >"$AGENT_RUNS/id1/transcripts/1.jsonl"
reject id1
mkid id2; printf '%s\n' "$idrec" >"$AGENT_RUNS/id2/sessions/01.json"
reject id2
reject id1/01
reject id2/01
for bad in 0 00 001 9007199254740993 1000000000000000; do
    mkid id3; printf '%s\n' "$idrec" >"$AGENT_RUNS/id3/sessions/$bad.json"
    reject id3/$bad
    reject id3
    rm "$AGENT_RUNS/id3/sessions/$bad.json"
done
# Distinct canonical sessions still count once each, including the largest safe width.
mkid id4
for i in 1 10 999999999999999; do
    printf '{"n":%s,"harness":"claude","state":"finished"}\n' "$i" >"$AGENT_RUNS/id4/sessions/$i.json"
    echo "$idtr" >"$AGENT_RUNS/id4/transcripts/$i.jsonl"
done
out=$(usage id4)
check "$out" '[.sessions[].session] == [1, 10, 999999999999999] and .aggregate.sessions == 3
    and .aggregate.totals.output_tokens.sum == 3'
check "$(usage id4/999999999999999)" '.session == 999999999999999 and .status == "reported"'
echo "usage tests passed"

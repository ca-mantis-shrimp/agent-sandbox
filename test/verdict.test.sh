#!/bin/sh
# Manifest fixtures only: no model or host units required.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$tool/lib/agent-runs.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_RUNS="$tmp/runs"
mkdir -p "$AGENT_RUNS/ws/sessions"
manifest="$AGENT_RUNS/ws/manifest.json"
printf '{"state":"ready","landed":"yesterday","keep":{"value":1}}\n' >"$manifest"
verdict="$tool/bin/agent-verdict"
sh "$verdict" ws --agree --overrule 'false "alarm"' --overrule 'second' \
    --missed 'first miss' --missed 'second
line' --note 'Human said: keep $behavior.' >"$tmp/out" 2>"$tmp/err"
[ ! -s "$tmp/out" ]
jq -e '.keep.value == 1 and .landed == "yesterday" and .human_verdict == {
    agrees_with_review:true, overruled:["false \"alarm\"","second"],
    missed:["first miss","second\nline"], note:"Human said: keep $behavior.",
    at:.human_verdict.at} and (.human_verdict.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' "$manifest" >/dev/null
# Re-recording replaces one verdict, not a history or concatenated arrays.
sh "$verdict" ws >/dev/null 2>&1
jq -e '.human_verdict.agrees_with_review == false and
    .human_verdict.overruled == [] and .human_verdict.missed == [] and
    .human_verdict.note == "" and .keep.value == 1' "$manifest" >/dev/null
# A facilitator verdict is independent: it leaves the human's field unchanged
# and does not silence the reminder.
jq -c '.human_verdict' "$manifest" >"$tmp/human-before"
sh "$verdict" ws --by facilitator --agree --missed 'facilitator miss' >/dev/null 2>"$tmp/err"
jq -c -e '.facilitator_verdict.agrees_with_review == true and
    .facilitator_verdict.missed == ["facilitator miss"] and
    (.facilitator_verdict.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' "$manifest" >/dev/null
jq -c '.human_verdict' "$manifest" >"$tmp/human-after"
cmp "$tmp/human-before" "$tmp/human-after"
cp "$manifest" "$tmp/before"
if sh "$verdict" ws --by oracle --agree >"$tmp/out" 2>"$tmp/err"; then
    echo 'unknown judge unexpectedly succeeded' >&2; exit 1
else
    status=$?
fi
[ "$status" -eq 2 ] && [ ! -s "$tmp/out" ] && [ -s "$tmp/err" ]
cmp "$tmp/before" "$manifest"
refuse() {
    if sh "$verdict" "$@" >"$tmp/out" 2>"$tmp/err"; then
        echo "unexpected success: $*" >&2; exit 1
    fi
    [ ! -s "$tmp/out" ] && [ -s "$tmp/err" ]
    jq -n -e --rawfile after "$manifest" --rawfile before "$tmp/before" '$after == $before' >/dev/null
}
refuse unknown
refuse ../ws
refuse ws/1
refuse ws --unknown
refuse ws --overrule
refuse ws --missed
refuse ws --note
# Invalid JSON never replaces the original, and the temporary file is removed.
printf 'invalid json\n' >"$manifest"
cp "$manifest" "$tmp/before"
refuse ws --agree
[ "$(find "$AGENT_RUNS/ws" -name 'manifest.verdict.*' | wc -l)" -eq 0 ]
# Reminder uses the shared enriched reader, including separate and old records.
printf '{"state":"ready"}\n' >"$manifest"
human_verdict_reminder ws "$(workspace_json "$AGENT_RUNS/ws")" 2>"$tmp/reminder"
[ ! -s "$tmp/reminder" ]
printf '{"n":1,"read_only":true,"review":{"verdict":"land"}}\n' >"$AGENT_RUNS/ws/sessions/1.json"
human_verdict_reminder ws "$(workspace_json "$AGENT_RUNS/ws")" 2>"$tmp/reminder"
grep -qF 'agent-verdict ws' "$tmp/reminder"
sh "$verdict" ws --agree >/dev/null 2>&1
human_verdict_reminder ws "$(workspace_json "$AGENT_RUNS/ws")" 2>"$tmp/reminder"
[ ! -s "$tmp/reminder" ]
# A facilitator verdict does not silence the human's landing reminder.
jq 'del(.human_verdict)' "$manifest" >"$tmp/manifest"
mv "$tmp/manifest" "$manifest"
sh "$verdict" ws --by facilitator >/dev/null 2>&1
human_verdict_reminder ws "$(workspace_json "$AGENT_RUNS/ws")" 2>"$tmp/reminder"
grep -qF 'agent-verdict ws' "$tmp/reminder"
rm "$AGENT_RUNS/ws/sessions/1.json"
printf '{"sessions":[{"review":{"unparsed":true}}]}\n' >"$manifest"
human_verdict_reminder ws "$(workspace_json "$AGENT_RUNS/ws")" 2>"$tmp/reminder"
grep -qF 'agent-verdict ws' "$tmp/reminder"
echo 'agent-verdict.test > ok'

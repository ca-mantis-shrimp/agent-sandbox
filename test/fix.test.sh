#!/bin/sh
# Fixture records and a stub launcher: no podman, systemd or model required.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tool/scripts/lib" "$tmp/runs/ws/sessions"
cp "$root/scripts/agent-fix" "$tmp/tool/scripts/"
cp "$root/scripts/lib/agent-runs.sh" "$root/scripts/lib/agent-review.jq" "$tmp/tool/scripts/lib/"
export AGENT_RUNS="$tmp/runs" CAPTURE="$tmp/capture"
cat >"$tmp/tool/scripts/agent-run" <<'SH'
#!/bin/sh
set -eu
jq -n --args '$ARGS.positional' -- "$@" >"$CAPTURE"
printf 'ws/12\n'
exit "${LAUNCH_STATUS:-0}"
SH
chmod +x "$tmp/tool/scripts/agent-run"
fix="$tmp/tool/scripts/agent-fix"
printf '{"state":"ready"}\n' >"$AGENT_RUNS/ws/manifest.json"
report='{"coverage":[],"findings":[{"severity":"blocking","file":"a","line":1,"what":"bug with \"quotes\"","why":"breaks","reconciled":true},{"severity":"should-fix","file":null,"line":null,"what":"simplify","why":"duplication"},{"severity":"nit","what":"style","why":"readability"}],"for_human":["choose a policy"],"verdict":"land after fixes"}'
record() { # n read-only report (JSON), stored directly
    jq -n --argjson n "$1" --argjson ro "$2" --argjson report "$3" \
        '{n:$n,read_only:$ro,state:"finished",review:$report}' >"$AGENT_RUNS/ws/sessions/$1.json"
}
record 2 true "$report"
record 10 true "$report"
record 11 true '{"unparsed":true}'
record 12 true null
record 13 false "$report"
# Numeric latest parsed reader, not the newest record or lexicographic last.
[ "$(sh "$fix" ws --harness pi --model 'model id' --wait)" = ws/12 ]
jq -e '.[0:2] == ["--in","ws"] and .[2] == "--prompt"
    and .[4:] == ["--harness","pi","--model","model id","--wait"]' "$CAPTURE" >/dev/null
prompt=$(jq -r '.[3]' "$CAPTURE")
printf '%s\n' "$prompt" | grep -qF 'Run kind: fix. Target: review session ws/10.'
printf '%s\n' "$prompt" | grep -qF 'Review verdict: land after fixes'
# The JSON values are preserved, including extra fields and nullable locations.
findings=$(printf '%s\n' "$prompt" | jq -Rs 'capture("```json\n(?<body>[^\n]*)\n```").body | fromjson')
[ "$(printf '%s\n' "$findings" | jq -c .)" = "$(printf '%s\n' "$report" | jq -c '[.findings[] | select(.severity != "nit")]')" ]
# Explicit session, all nits, a multiline note read relative to the caller.
printf 'Policy: keep behavior.\nAnswer: use existing helper.\n' >"$tmp/note.txt"
(cd "$tmp"; sh "$fix" ws/2 --nits --note note.txt --harness claude >/dev/null)
prompt=$(jq -r '.[3]' "$CAPTURE")
printf '%s\n' "$prompt" | grep -qF 'Target: review session ws/2.'
printf '%s\n' "$prompt" | grep -qF 'Answer: use existing helper.'
findings=$(printf '%s\n' "$prompt" | jq -Rs 'capture("```json\n(?<body>[^\n]*)\n```").body | fromjson')
[ "$(printf '%s\n' "$findings" | jq -c .)" = "$(printf '%s\n' "$report" | jq -c .findings)" ]
# Closing-only records use the same parser as agent-result, not a second parser.
jq -n --arg report "$report" '{n:14,read_only:true,state:"finished",closing:("```json\n"+$report+"\n```")}' \
    >"$AGENT_RUNS/ws/sessions/14.json"
sh "$fix" ws >/dev/null
jq -e '.[3] | contains("Target: review session ws/14.")' "$CAPTURE" >/dev/null
refuse() {
    rm -f "$CAPTURE"
    if sh "$fix" "$@" >"$tmp/out" 2>"$tmp/err"; then
        echo "unexpected success: $*" >&2; exit 1
    fi
    [ ! -e "$CAPTURE" ]
    [ ! -s "$tmp/out" ]
    [ -s "$tmp/err" ]
}
refuse ws/11
refuse ws/12
refuse ws/13
refuse ws/99
refuse unknown
refuse ws/2/3
refuse ../2
refuse ws/2 --harness invalid
refuse ws --unknown
# Malformed stored schema is also refused.
record 15 true '{"verdict":"land","findings":[]}'
refuse ws/15
# No blockers/should-fixes: even --nits needs a note.
nit_report=$(printf '%s\n' "$report" | jq '.findings |= map(select(.severity == "nit"))')
record 16 true "$nit_report"
refuse ws/16
refuse ws/16 --nits
: >"$tmp/empty-note"
refuse ws/16 --note "$tmp/empty-note"
sh "$fix" ws/16 --note 'Only implement the policy decision.' >/dev/null
jq -e '.[3] | contains("Only implement the policy decision.") and contains("\n[]\n")' "$CAPTURE" >/dev/null
record 17 true "$(printf '%s\n' "$report" | jq '.findings=[]')"
sh "$fix" ws/17 --note 'Answer to for_human.' >/dev/null
# The launcher status is not hidden, while stdout is the reference unchanged.
export LAUNCH_STATUS=7
status=0
sh "$fix" ws/2 >"$tmp/out" || status=$?
[ "$status" -eq 7 ]
[ "$(cat "$tmp/out")" = ws/12 ]
unset LAUNCH_STATUS
# File reviews are attributed and retained separately from session records.
printf '%s\n' "$report" >"$tmp/review.json"
(cd "$tmp"; sh "$fix" ws --review review.json --reviewer claude-opus-5-5 --nits --note note.txt >/dev/null)
prompt=$(jq -r '.[3]' "$CAPTURE")
printf '%s\n' "$prompt" | grep -qF 'in workspace ws (reviewer: claude-opus-5-5).'
. "$root/scripts/lib/agent-runs.sh"
workspace_json "$AGENT_RUNS/ws" | jq -e --argjson report "$report" '
    .reviews | length == 1 and .[0].review == $report and .[0].reviewer == "claude-opus-5-5"' >/dev/null
refuse ws/11 --review "$tmp/review.json" --reviewer claude-opus-5-5
refuse ws --review "$tmp/review.json"
refuse ws --review "$tmp/review.json" --reviewer ''
refuse ws --reviewer claude-opus-5-5
printf '%s\n' "$prompt" | grep -qF 'Answer: use existing helper.'
findings=$(printf '%s\n' "$prompt" | jq -Rs 'capture("```json\n(?<body>[^\n]*)\n```").body | fromjson')
[ "$(printf '%s\n' "$findings" | jq -c .)" = "$(printf '%s\n' "$report" | jq -c .findings)" ]
# Invalid, missing, empty and multi-document files never launch, even with a note.
refuse ws --review "$tmp/missing.json" --reviewer tester
: >"$tmp/empty.json"
refuse ws --review "$tmp/empty.json" --reviewer tester --note 'Cannot supply the missing review.'
printf '{broken\n' >"$tmp/invalid.json"
refuse ws --review "$tmp/invalid.json" --reviewer tester
printf '{"verdict":"land","findings":[]}\n' >"$tmp/invalid.json"
refuse ws --review "$tmp/invalid.json" --reviewer tester
printf '%s\n%s\n' "$report" "$report" >"$tmp/multiple.json"
refuse ws --review "$tmp/multiple.json" --reviewer tester
printf '%s\n' "$nit_report" >"$tmp/nits.json"
refuse ws --review "$tmp/nits.json" --reviewer tester --nits
sh "$fix" ws --review "$tmp/nits.json" --reviewer tester --nits --note 'Fix the style nit.' >/dev/null
jq -e '.[3] | contains("style") and contains("Fix the style nit.")' "$CAPTURE" >/dev/null
# No parsed review at all: reject before the launcher, even with a note.
rm "$AGENT_RUNS/ws/sessions/"*.json
record 1 true '{"unparsed":true}'
refuse ws --note 'Cannot supply the missing review.'
# A workspace without review sessions can still use an orchestrator's file.
sh "$fix" ws --review "$tmp/review.json" --reviewer another-reviewer >/dev/null
jq -e '.[3] | contains("Review verdict: land after fixes") and (contains("style") | not)' "$CAPTURE" >/dev/null
refuse unknown --review "$tmp/review.json" --reviewer tester
workspace_json "$AGENT_RUNS/ws" | jq -e '.reviews | length == 3 and
    (map(.reviewer) | sort) == ["another-reviewer","claude-opus-5-5","tester"]' >/dev/null
[ "$(find "$AGENT_RUNS/ws/reviews" -type f ! -name '*.json' | wc -l)" -eq 0 ]
printf 'agent-fix tests passed\n'

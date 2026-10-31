#!/bin/sh
# Manifest fixtures only: no model or host units required.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$tool/lib/agent-runs.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_RUNS="$tmp/runs" AGENT_VERDICT_HOOK=
mkdir -p "$AGENT_RUNS/ws/sessions"
manifest="$AGENT_RUNS/ws/manifest.json"
printf '{"state":"ready","landed":"yesterday","keep":{"value":1}}\n' >"$manifest"
verdict="$tool/bin/agent-verdict"
sh "$verdict" ws --by human --agree --overrule 'false "alarm"' --overrule 'second' \
    --missed 'first miss' --missed 'second
line' --note 'Human said: keep $behavior.' >"$tmp/out" 2>"$tmp/err"
[ ! -s "$tmp/out" ]
jq -e '.keep.value == 1 and .landed == "yesterday" and .human_verdict == {
    agrees_with_review:true, overruled:["false \"alarm\"","second"],
    missed:["first miss","second\nline"], note:"Human said: keep $behavior.",
    at:.human_verdict.at} and (.human_verdict.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' "$manifest" >/dev/null
# Without --agree or --disagree nothing is recorded: no flags prints help,
# other flags alone are refused.
cp "$manifest" "$tmp/before"
sh "$verdict" ws >"$tmp/out" 2>"$tmp/err"
grep -qF -- '--agree|--disagree' "$tmp/out" && cmp "$tmp/before" "$manifest"
sh "$verdict" >"$tmp/out" 2>"$tmp/err"
grep -qF 'usage: agent-verdict' "$tmp/out"
sh "$verdict" ws --by facilitator >"$tmp/out" 2>&1 && cmp "$tmp/before" "$manifest"
if sh "$verdict" ws --missed 'x' >/dev/null 2>&1; then echo 'judgment-free flags unexpectedly succeeded' >&2; exit 1; fi
if sh "$verdict" ws --agree --disagree >/dev/null 2>&1; then echo 'both judgments unexpectedly succeeded' >&2; exit 1; fi
cmp "$tmp/before" "$manifest"
# Re-recording replaces one verdict, not a history or concatenated arrays.
sh "$verdict" ws --by human --disagree >/dev/null 2>&1
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
refuse unknown --agree
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
grep -qF 'agent-verdict ws --agree|--disagree' "$tmp/reminder"
sh "$verdict" ws --by human --agree >/dev/null 2>&1
human_verdict_reminder ws "$(workspace_json "$AGENT_RUNS/ws")" 2>"$tmp/reminder"
[ ! -s "$tmp/reminder" ]
# A facilitator verdict does not silence the human's landing reminder.
jq 'del(.human_verdict)' "$manifest" >"$tmp/manifest"
mv "$tmp/manifest" "$manifest"
sh "$verdict" ws --by facilitator --disagree >/dev/null 2>&1
human_verdict_reminder ws "$(workspace_json "$AGENT_RUNS/ws")" 2>"$tmp/reminder"
grep -qF 'agent-verdict ws --agree|--disagree' "$tmp/reminder"
rm "$AGENT_RUNS/ws/sessions/1.json"
printf '{"sessions":[{"review":{"unparsed":true}}]}\n' >"$manifest"
human_verdict_reminder ws "$(workspace_json "$AGENT_RUNS/ws")" 2>"$tmp/reminder"
grep -qF 'agent-verdict ws --agree|--disagree' "$tmp/reminder"
# Before landing the verdict stays only in the manifest; afterward it is
# mirrored into a git note and a second judge updates only their own lines.
repo="$tmp/noted-repo"
git init -q -b main "$repo"
printf 'base\n' >"$repo/file"
git -C "$repo" add file
git -C "$repo" commit -q -m base
landed_commit=$(git -C "$repo" rev-parse HEAD)
jq -n --arg repo "$repo" '{repo:$repo,landed:"yesterday"}' >"$manifest"
sh "$verdict" ws --by human --agree --overrule 'legacy finding' >/dev/null 2>"$tmp/err"
jq -e '.human_verdict.overruled == ["legacy finding"] and .landed_commit == null' "$manifest" >/dev/null
grep -Fq 'landed workspace ws has no recorded commit; no verdict note was written' "$tmp/err"
if git -C "$repo" notes --ref=verdict show "$landed_commit" >/dev/null 2>&1; then
    echo 'agent-verdict.test > wrote a note for a legacy landing without a commit' >&2; exit 1
fi
jq -n --arg repo "$repo" '{repo:$repo}' >"$manifest"
sh "$verdict" ws --by human --agree --overrule 'first finding' --note 'human note' >/dev/null 2>"$tmp/err"
if git -C "$repo" notes --ref=verdict show "$landed_commit" >/dev/null 2>&1; then
    echo 'agent-verdict.test > wrote a note before landing' >&2; exit 1
fi
jq --arg commit "$landed_commit" '.landed="2026-10-25T10:00:00Z" | .landed_commit=$commit' \
    "$manifest" >"$tmp/landed-manifest"
mv "$tmp/landed-manifest" "$manifest"
sh "$verdict" ws --by human --agree --overrule 'first finding' --note 'human note' >/dev/null 2>"$tmp/err"
git -C "$repo" notes --ref=verdict show "$landed_commit" >"$tmp/verdict-note"
grep -Fqx '# verdict: human agrees with the review ('"$(jq -r .human_verdict.at "$manifest")"')' "$tmp/verdict-note"
grep -Fqx 'overruled: first finding' "$tmp/verdict-note"
grep -Fqx 'note: human note' "$tmp/verdict-note"
sh "$verdict" ws --by facilitator --disagree --missed 'facilitator miss' >/dev/null 2>"$tmp/err"
git -C "$repo" notes --ref=verdict show "$landed_commit" >"$tmp/verdict-note"
grep -Fqx '# verdict: human agrees with the review ('"$(jq -r .human_verdict.at "$manifest")"')' "$tmp/verdict-note"
grep -Fqx '# verdict: facilitator disagrees with the review ('"$(jq -r .facilitator_verdict.at "$manifest")"')' "$tmp/verdict-note"
grep -Fqx 'overruled: first finding' "$tmp/verdict-note"
grep -Fqx 'missed: facilitator miss' "$tmp/verdict-note"
grep -Fqx 'note: human note' "$tmp/verdict-note"
[ "$(grep -c '^# verdict: human' "$tmp/verdict-note")" -eq 1 ]
sh "$verdict" ws --by human --disagree --overrule 'later judgment' >/dev/null 2>"$tmp/err"
git -C "$repo" notes --ref=verdict show "$landed_commit" >"$tmp/verdict-note"
grep -Fqx 'overruled: first finding' "$tmp/verdict-note"
grep -Fqx 'overruled: later judgment' "$tmp/verdict-note"
[ "$(grep -c '^# verdict: human' "$tmp/verdict-note")" -eq 2 ]
# --on records feedback on one finding: agree, disagree or a comment alone. It
# appends, leaves the bundle verdict alone, and refuses ids the review lacks.
fdir="$tmp/finding-runs/ws"
mkdir -p "$fdir/sessions"
printf '{"n":2,"read_only":true,"review":{"verdict":"land","findings":[{"severity":"nit"},{"severity":"should-fix"}]}}\n' >"$fdir/sessions/2.json"
jq -n --arg repo "$repo" --arg commit "$landed_commit" '{repo:$repo,landed:"t",landed_commit:$commit}' >"$fdir/manifest.json"
export AGENT_RUNS="$tmp/finding-runs"
manifest="$fdir/manifest.json"
sh "$verdict" ws --by human --on 2#2 --disagree --note 'not worth
a cycle' >/dev/null 2>"$tmp/err"
sh "$verdict" ws --by human --on 2#1 --note 'good catch, later' >/dev/null 2>"$tmp/err"
sh "$verdict" ws --by human --on 2#2 --agree >/dev/null 2>"$tmp/err"
jq -e '.human_verdict == null and [.human_findings[] | [.finding, .agrees, .note]] == [
    ["2#2", false, "not worth\na cycle"], ["2#1", null, "good catch, later"], ["2#2", true, ""]]' "$manifest" >/dev/null
git -C "$repo" notes --ref=verdict show "$landed_commit" >"$tmp/verdict-note"
grep -Fqx "# finding 2#2: human disagrees ($(jq -r '.human_findings[0].at' "$manifest"))" "$tmp/verdict-note"
grep -Fqx 'note: not worth a cycle' "$tmp/verdict-note"
grep -Fqx "# finding 2#1: human comments ($(jq -r '.human_findings[1].at' "$manifest"))" "$tmp/verdict-note"
grep -Fqx "# finding 2#2: human agrees ($(jq -r '.human_findings[2].at' "$manifest"))" "$tmp/verdict-note"
# Finding feedback alone leaves the landing waiting for a verdict.
AGENT_RUNS="$tmp/finding-runs" sh "$verdict" --pending | grep -q '^ws	'
cp "$manifest" "$tmp/before"
refuse ws --on 2#2
refuse ws --on 2#3 --agree
refuse ws --on 2#0 --agree
refuse ws --on 9#1 --agree
refuse ws --on 'x#1' --agree
refuse ws --on 2#1 --agree --missed 'x'
refuse ws --on
# A nonterminal call without --by refuses before changing either manifest or
# notes; an orchestrator verdict is recorded independently and stays human-pending.
cp "$manifest" "$tmp/before"
git -C "$repo" notes --ref=verdict show "$landed_commit" >"$tmp/note-before"
if sh "$verdict" ws --agree </dev/null >"$tmp/out" 2>"$tmp/err"; then
    echo 'nonterminal verdict without --by unexpectedly succeeded' >&2; exit 1
else
    status=$?
fi
[ "$status" -eq 2 ] && [ ! -s "$tmp/out" ] && [ -s "$tmp/err" ]
cmp "$tmp/before" "$manifest"
git -C "$repo" notes --ref=verdict show "$landed_commit" >"$tmp/note-after"
cmp "$tmp/note-before" "$tmp/note-after"
sh "$verdict" ws --by orchestrator --agree --note 'automation judgment' >/dev/null 2>"$tmp/err"
jq -e '.human_verdict == null and .orchestrator_verdict.agrees_with_review == true and
    .orchestrator_verdict.note == "automation judgment"' "$manifest" >/dev/null
git -C "$repo" notes --ref=verdict show "$landed_commit" >"$tmp/verdict-note"
grep -Fqx '# verdict: orchestrator agrees with the review ('"$(jq -r .orchestrator_verdict.at "$manifest")"')' "$tmp/verdict-note"
AGENT_RUNS="$tmp/finding-runs" sh "$verdict" --pending >"$tmp/pending"
grep -q "^ws$(printf '\t')" "$tmp/pending"
# --pending lists landed workspaces with a landed commit and no human verdict,
# newest first, as id, repository and first session label, tab-separated.
pend="$tmp/pending-runs"
mkdir -p "$pend/20261001-000000/sessions" "$pend/20261002-000000/sessions" \
    "$pend/20261003-000000" "$pend/20261004-000000" "$pend/20261005-000000"
printf '{"repo":"/x/srr","landed":"t","landed_commit":"abc"}\n' >"$pend/20261001-000000/manifest.json"
printf '{"n":1,"label":"payment-boundary"}\n' >"$pend/20261001-000000/sessions/1.json"
printf '{"repo":"/x/platform","landed":"t","landed_commit":"def"}\n' >"$pend/20261002-000000/manifest.json"
printf '{"repo":"/x/srr","landed":"t","landed_commit":"ghi","human_verdict":{"agrees_with_review":true}}\n' >"$pend/20261003-000000/manifest.json"
printf '{"repo":"/x/srr","landed":"t"}\n' >"$pend/20261004-000000/manifest.json"
printf '{"repo":"/x/srr"}\n' >"$pend/20261005-000000/manifest.json"
AGENT_RUNS=$pend sh "$verdict" --pending >"$tmp/pending" 2>"$tmp/err"
printf '20261002-000000\tplatform\t\tdef\n20261001-000000\tsrr\tpayment-boundary\tabc\n' | cmp - "$tmp/pending"
# Nothing pending prints nothing and succeeds.
AGENT_RUNS="$tmp/empty-runs" sh "$verdict" --pending >"$tmp/pending"
[ ! -s "$tmp/pending" ]
# --feedback lists every human verdict and finding comment, oldest first, as
# time, workspace, repository, label, target, stance and note (one line each);
# with a time, only what was recorded after it. Other judges are left out.
fb="$tmp/feedback-runs"
mkdir -p "$fb/20261001-000000/sessions" "$fb/20261002-000000"
printf '{"n":1,"label":"signup"}\n' >"$fb/20261001-000000/sessions/1.json"
cat >"$fb/20261001-000000/manifest.json" <<'EOF'
{"repo":"/x/srr","human_verdict":{"agrees_with_review":true,"note":"","at":"2026-10-01T03:00:00+00:00"},
 "human_findings":[{"finding":"2#1","agrees":null,"note":"what should\nit do?","at":"2026-10-01T01:00:00+00:00"},
                   {"finding":"2#2","agrees":false,"note":"","at":"2026-10-01T02:00:00+00:00"}],
 "facilitator_verdict":{"agrees_with_review":false,"note":"mine","at":"2026-10-01T04:00:00+00:00"},
 "orchestrator_verdict":{"agrees_with_review":false,"note":"automated","at":"2026-10-01T05:00:00+00:00"}}
EOF
printf '{"repo":"/x/platform"}\n' >"$fb/20261002-000000/manifest.json"
AGENT_RUNS=$fb sh "$verdict" --feedback >"$tmp/feedback"
printf '%s\t20261001-000000\tsrr\tsignup\t%s\n' \
    '2026-10-01T01:00:00+00:00' "2#1	comments	what should it do?" \
    '2026-10-01T02:00:00+00:00' "2#2	disagrees	" \
    '2026-10-01T03:00:00+00:00' "review	agrees	" | cmp - "$tmp/feedback"
AGENT_RUNS=$fb sh "$verdict" --feedback 2026-10-01T02:00:00+00:00 >"$tmp/feedback"
[ "$(cut -f5 "$tmp/feedback")" = review ]
# A bundle verdict, the end of a review, runs the hook with the workspace, the
# judge and the repository; finding feedback does not. A failing hook warns
# and leaves the verdict recorded.
printf '#!/bin/sh\necho "$@" >>%s\n' "$tmp/hook.calls" >"$tmp/hook"
chmod +x "$tmp/hook"
AGENT_VERDICT_HOOK="$tmp/hook" sh "$verdict" ws --by human --on 2#1 --note 'later' 2>/dev/null
[ ! -e "$tmp/hook.calls" ]
AGENT_VERDICT_HOOK="$tmp/hook" sh "$verdict" ws --by human --agree 2>/dev/null
[ "$(cat "$tmp/hook.calls")" = "ws human $repo" ]
AGENT_VERDICT_HOOK=false sh "$verdict" ws --by human --disagree 2>"$tmp/err"
grep -q 'hook' "$tmp/err" && jq -e '.human_verdict.agrees_with_review == false' "$manifest" >/dev/null
# Bash completion offers the pending ids first, then flags.
if command -v bash >/dev/null; then
    out=$(PATH="$tool/bin:$PATH" AGENT_RUNS=$pend bash -c '
        . "$1"; COMP_WORDS=(agent-verdict 2026); COMP_CWORD=1; _agent_verdict; printf "%s\n" "${COMPREPLY[@]}"
        COMP_WORDS=(agent-verdict 20261001-000000 --a); COMP_CWORD=2; _agent_verdict; printf "%s\n" "${COMPREPLY[@]}"
        COMP_WORDS=(agent-verdict 20261001-000000 --by or); COMP_CWORD=3; _agent_verdict; printf "%s\n" "${COMPREPLY[@]}"
    ' _ "$tool/system/usr/share/bash-completion/completions/agent-verdict")
    [ "$out" = "$(printf '20261002-000000\n20261001-000000\n--agree\norchestrator')" ]
fi
echo 'agent-verdict.test > ok'

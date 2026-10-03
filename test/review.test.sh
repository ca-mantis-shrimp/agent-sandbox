#!/bin/sh
# Closing report and host record contract; jq handles JSON, no harness needed.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$tool/lib/agent-runs.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
report='{"coverage":[{"check":"behavior","how":"git diff"}],"findings":[{"severity":"blocking","file":"a","line":1,"what":"bug","why":"breaks"}],"for_human":["choose"],"verdict":"do not land"}'
record=$(jq -n --arg report "$report" '{n:1,read_only:true,closing:("notes\n```json\n"+$report+"\n```")}')
enriched=$(session_json "$tmp" "$record")
[ "$(printf '%s' "$enriched" | jq -c .review)" = "$report" ]
# Reconciliation is preserved rather than overwritten by parsing the closing again.
enriched=$(printf '%s' "$enriched" | jq '.review.findings[0].reconciled=true')
[ "$(session_json "$tmp" "$enriched" | jq .review.findings[0].reconciled)" = true ]
jq -n --argjson session "$enriched" '{state:"finished",sessions:[$session]}' >"$tmp/manifest.json"
[ "$(workspace_json "$tmp" | jq .sessions[0].review.findings[0].reconciled)" = true ]
[ "$(session_json "$tmp" '{"read_only":true,"closing":"no JSON"}' | jq -c .review)" = null ]
[ "$(session_json "$tmp" '{"read_only":false,"closing":"```json\n{broken}\n```"}' | jq 'has("review")')" = false ]
# Approach findings can omit locations or explicitly set them to null.
for change in '.findings[0] |= (.file=null | .line=null)' 'del(.findings[0].file,.findings[0].line)' '.findings[0].line=null'; do
    approach=$(printf '%s' "$report" | jq -c "$change")
    record=$(jq -n --arg report "$approach" '{read_only:true,closing:("```json\n"+$report+"\n```")}')
    [ "$(session_json "$tmp" "$record" | jq -c .review)" = "$approach" ]
done
# Both syntax and schema failures are visible, not silently dropped.
for invalid in '{broken}' '[]' 'null' '1' '"text"' \
    "$(printf '%s' "$report" | jq '.verdict="invalid"')" \
    "$(printf '%s' "$report" | jq '.findings[0].line="one"')" \
    "$(printf '%s' "$report" | jq '.findings[0].file=1')" \
    "$(printf '%s' "$report" | jq '.coverage={}')"; do
    record=$(jq -n --arg report "$invalid" '{read_only:true,closing:("```json\n"+$report+"\n```")}')
    [ "$(session_json "$tmp" "$record" | jq -c .review)" = '{"unparsed":true}' ]
done
# Harvest uses these plain lines before showing the full closing message.
lines=$(printf '%s' "$report" | jq -r -L "$tool/lib" 'include "agent-review"; review_lines')
[ "$lines" = 'verdict: do not land
for human: choose
blocking a:1: bug
coverage: behavior — git diff' ]
[ "$(printf '%s' "$report" | jq -r -L "$tool/lib" 'include "agent-review"; .findings[0] |= (.file=null | .line=null) | review_lines' | grep '^blocking')" = 'blocking (approach):-: bug' ]
[ "$(jq -nr -L "$tool/lib" 'include "agent-review"; {unparsed:true} | review_lines')" = 'review: unparsed report' ]
[ "$(jq -nr -L "$tool/lib" 'include "agent-review"; null | review_lines')" = 'review: no report' ]
# External reports survive rereads with attribution and human reconciliation.
mkdir "$tmp/reviews"
jq -n --argjson report "$report" '{id:"one",reviewer:"claude-opus-5-5",review:$report}' >"$tmp/reviews/one.json"
workspace=$(workspace_json "$tmp")
printf '%s\n' "$workspace" | jq -e '.reviews[0].reviewer == "claude-opus-5-5" and
    .sessions[0].review.findings[0].reconciled == true' >/dev/null
lines=$(printf '%s\n' "$workspace" | jq -r -L "$tool/lib" 'include "agent-review"; blocking_review_lines')
[ "$lines" = 'agent-land > unreconciled blocking finding (external review one by claude-opus-5-5): a:1: bug — breaks' ]
jq '.review.findings[0].reconciled=true' "$tmp/reviews/one.json" >"$tmp/reconciled"
mv "$tmp/reconciled" "$tmp/reviews/one.json"
[ -z "$(workspace_json "$tmp" | jq -r -L "$tool/lib" 'include "agent-review"; blocking_review_lines')" ]
# The actual harvest command prints external reviews even without sessions.
mkdir -p "$tmp/tool/bin" "$tmp/tool/lib" "$tmp/runs/ws/work" "$tmp/runs/ws/reviews"
cp "$tool/bin/agent-harvest" "$tmp/tool/bin/"
cp "$tool/lib/agent-runs.sh" "$tool/lib/agent-review.jq" "$tool/lib/agent-quadlet.sh" "$tmp/tool/lib/"
printf '#!/bin/sh\nexit 0\n' >"$tmp/tool/bin/agent-reconcile"
chmod +x "$tmp/tool/bin/agent-reconcile"
# The repo being harvested into comes from the manifest, not the tool's location.
git init -q "$tmp/repo"
work="$tmp/runs/ws/work"
git -C "$work" init -q
git -C "$work" -c user.name=test -c user.email=test@localhost commit -q --allow-empty -m base
git -C "$work" branch agent/ws
git -C "$work" update-ref refs/agent/base HEAD
jq -n --arg repo "$tmp/repo" '{state: "ready", repo: $repo}' >"$tmp/runs/ws/manifest.json"
cp "$tmp/reviews/one.json" "$tmp/runs/ws/reviews/one.json"
AGENT_RUNS="$tmp/runs" sh "$tmp/tool/bin/agent-harvest" ws >"$tmp/harvest"
grep -qF 'external review one by claude-opus-5-5' "$tmp/harvest"
grep -qF 'blocking a:1: bug' "$tmp/harvest"
grep -qF 'agent-harvest > repo: no commits' "$tmp/harvest"
# An external-only review also triggers the human verdict reminder.
human_verdict_reminder ws "$(workspace_json "$tmp/runs/ws")" 2>"$tmp/reminder"
grep -qF 'agent-verdict ws' "$tmp/reminder"
jq '.human_verdict={agrees_with_review:true}' "$tmp/runs/ws/manifest.json" >"$tmp/verdict"
mv "$tmp/verdict" "$tmp/runs/ws/manifest.json"
human_verdict_reminder ws "$(workspace_json "$tmp/runs/ws")" 2>"$tmp/reminder"
[ ! -s "$tmp/reminder" ]
printf 'agent-review tests passed\n'

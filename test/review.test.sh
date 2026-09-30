#!/bin/sh
# Closing report and host record contract; jq handles JSON, no harness needed.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/scripts/lib/agent-runs.sh"
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
lines=$(printf '%s' "$report" | jq -r -L "$root/scripts/lib" 'include "agent-review"; review_lines')
[ "$lines" = 'verdict: do not land
for human: choose
blocking a:1: bug
coverage: behavior — git diff' ]
[ "$(printf '%s' "$report" | jq -r -L "$root/scripts/lib" 'include "agent-review"; .findings[0] |= (.file=null | .line=null) | review_lines' | grep '^blocking')" = 'blocking (approach):-: bug' ]
[ "$(jq -nr -L "$root/scripts/lib" 'include "agent-review"; {unparsed:true} | review_lines')" = 'review: unparsed report' ]
[ "$(jq -nr -L "$root/scripts/lib" 'include "agent-review"; null | review_lines')" = 'review: no report' ]
printf 'agent-review tests passed\n'

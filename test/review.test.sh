#!/bin/sh
# Transcript and host record contract; jq handles JSON, no harness needed.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/scripts/lib/agent-runs.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/transcripts"
jq -n '
 [{type:"tool_execution_start",toolName:"read",toolCallId:"p1",args:{path:"/job/work/a"}},
  {type:"tool_execution_end",toolCallId:"p1",isError:false,result:{content:[{type:"text",text:"whole file"}]}},
  {type:"tool_execution_start",toolName:"read",toolCallId:"p2",args:{path:"b",limit:2}},
  {type:"tool_execution_end",toolCallId:"p2",isError:false,result:{content:[{type:"text",text:"partial"}]}},
  {type:"tool_execution_start",toolName:"read",toolCallId:"p3",args:{path:"c"}},
  {type:"tool_execution_end",toolCallId:"p3",isError:true,result:{content:[{type:"text",text:"error"}]}},
  {type:"tool_execution_start",toolName:"read",toolCallId:"p4",args:{path:"d"}},
  {type:"tool_execution_end",toolCallId:"p4",isError:false,result:{content:[{type:"text",text:"[Showing lines 1-2000. Use offset]"}]}},
  {type:"assistant",message:{content:[{type:"tool_use",id:"c1",name:"Read",input:{file_path:"./sub/e"}}]}},
  {type:"user",message:{content:[{type:"tool_result",tool_use_id:"c1",content:"     1→full\n     2→file"}]}},
  {type:"assistant",message:{content:[{type:"tool_use",id:"c2",name:"Read",input:{file_path:"f",offset:2}}]}},
  {type:"user",message:{content:[{type:"tool_result",tool_use_id:"c2",content:"     2→partial"}]}},
  {type:"assistant",message:{content:[{type:"tool_use",id:"c3",name:"Read",input:{file_path:"g"}}]}},
  {type:"user",message:{content:[{type:"tool_result",tool_use_id:"c3",is_error:true,content:"     1→failed"}]}},
  {type:"assistant",message:{content:[{type:"tool_use",id:"c4",name:"Read",input:{file_path:"h"}}]}},
  {type:"user",message:{content:[{type:"tool_result",tool_use_id:"c4",content:([range(1;2001)|"\(.)→line"]|join("\n"))}]}},
  {type:"tool_execution_start",toolName:"bash",toolCallId:"shell",args:{command:"cat i"}},
  {type:"tool_execution_end",toolCallId:"shell",isError:false,result:{content:[{type:"text",text:"file contents"}]}}]
 | .[]' >"$tmp/transcripts/1.jsonl"
changed='["a","b","c","d","sub/e","f","g","h","i","deleted"]'
metric=$(jq -s -L "$root/scripts/lib" --argjson changed "$changed" 'include "agent-review"; opened_in_full($changed)' "$tmp/transcripts/1.jsonl")
[ "$(printf '%s' "$metric" | jq -c .)" = '{"read":["a","sub/e"],"changed":10}' ]
report='{"coverage":[{"check":"behavior","how":"git diff"}],"findings":[{"severity":"blocking","file":"a","line":1,"what":"bug","why":"breaks"}],"for_human":["choose"],"verdict":"do not land"}'
record=$(jq -n --arg report "$report" --argjson changed "$changed" '{n:1,read_only:true,transcript:"transcripts/1.jsonl",changed_files:$changed,closing:("notes\n```json\n"+$report+"\n```")}')
enriched=$(session_json "$tmp" "$record")
[ "$(printf '%s' "$enriched" | jq -c .review)" = "$report" ]
[ "$(printf '%s' "$enriched" | jq -c .opened_in_full)" = '{"read":["a","sub/e"],"changed":10}' ]
# Reconciliation is preserved rather than overwritten by parsing the closing again.
enriched=$(printf '%s' "$enriched" | jq '.review.findings[0].reconciled=true')
[ "$(session_json "$tmp" "$enriched" | jq .review.findings[0].reconciled)" = true ]
# Finalized records remain usable after landing removes work/transcript inputs.
rm "$tmp/transcripts/1.jsonl"
[ "$(session_json "$tmp" "$enriched" | jq -c .opened_in_full)" = '{"read":["a","sub/e"],"changed":10}' ]
printf '%s\n' "$enriched" >"$tmp/session.json"
jq -n --argjson session "$enriched" '{state:"finished",sessions:[$session]}' >"$tmp/manifest.json"
[ "$(workspace_json "$tmp" | jq .sessions[0].review.findings[0].reconciled)" = true ]
[ "$(session_json "$tmp" '{"read_only":true,"closing":"no JSON"}' | jq -c '[.review,.opened_in_full]')" = '[null,null]' ]
# Malformed JSON and invalid verdicts are not successful reports.
[ "$(jq -n -L "$root/scripts/lib" 'include "agent-review"; {closing:"```json\n{broken}\n```"} | review_report')" = null ]
repo="$tmp/repo"
git init -q "$repo"
printf base >"$repo/deleted"
git -C "$repo" add .
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm base
git -C "$repo" update-ref refs/agent/base HEAD
rm "$repo/deleted"
printf new >"$repo/new file"
git -C "$repo" add .
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm change
[ "$(changed_files "$repo" refs/agent/base | jq -c .)" = '["deleted","new file"]' ]
# A missing base is an error, not an empty denominator.
if changed_files "$repo" refs/agent/missing >/dev/null 2>&1; then exit 1; fi
git -C "$repo" mv 'new file' renamed
git -C "$repo" -c user.name=t -c user.email=t@t commit -qm rename
[ "$(changed_files "$repo" HEAD~1 | jq -c .)" = '["new file","renamed"]' ]
printf 'agent-review tests passed\n'

#!/bin/sh
# Only host-derived workspace commits can anchor the saved landing thread.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$tool/lib/agent-runs.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
export AGENT_RUNS="$tmp/runs"
mkdir -p "$AGENT_RUNS/ws"
git init -q "$tmp/repo"
git -C "$tmp/repo" commit -q --allow-empty -m base
base=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" switch -qc agent/ws
git -C "$tmp/repo" commit -q --allow-empty -m work
work=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" commit -q --allow-empty -m fix
fix=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" checkout -q --detach "$base"
git -C "$tmp/repo" commit -q --allow-empty -m 'other workspace landed meanwhile'
foreign=$(git -C "$tmp/repo" rev-parse HEAD)
ws=$(jq -n --arg work "$work" --arg fix "$fix" --arg base "$base" --arg foreign "$foreign" '{id:"ws",sessions:[
 {n:0,commits:{".":[$work,$foreign,$base],"../repo":[$fix],missing:[$fix]}},
 {n:1,read_only:true,head_at_start:{".":$foreign},model:"reviewer",review:{coverage:[],for_human:[],verdict:"land after fixes",findings:[
 {file:"a",line:2,severity:"blocking",what:"Bug",why:"Breaks"},
 {severity:"nit",what:"Bug longer",why:"Style"},
 {severity:"should-fix",what:"Other",why:"Oops"}]}},
 {n:2,commits:{".":[$foreign,$base,$work,$fix]},review_session:"1",closing:"```json\n{\"fixed\":[\"1#1\",\"Bug long\"],\"declined\":[{\"id\":\"1#3\",\"why\":\"Intentional\"}]}\n```"},
 {n:3,read_only:true,model:"second",review:{coverage:[],for_human:[],verdict:"land",findings:[]}}
]}')
prepared=$(prepare_review_thread "$tmp/repo" "$ws" "$AGENT_RUNS/ws/review-thread.jsonl" 2>"$tmp/warning")
[ "$(grep -c warning "$tmp/warning")" -eq 1 ]
jq -e --arg work "$work" --arg fix "$fix" '.sessions[0].commits == {".":[$work]} and .sessions[2].commits == {".":[$fix]} and .sessions[1].review_anchors == {".":$work} and .sessions[3].review_anchors == {".":$fix}' <<EOF
$prepared
EOF
[ "$(wc -l <"$AGENT_RUNS/ws/review-thread.jsonl")" -eq 3 ]
trailers=$(printf '%s\n' "$prepared" | jq -r -L "$tool/lib" 'include "agent-review"; del(.sessions[3]) | finding_trailers')
printf '%s\n' "$trailers" | grep -Fqx "Finding-Fixed: 1#1 $(printf %.7s "$fix") Bug (blocking)"
printf '%s\n' "$trailers" | grep -Fqx 'Finding-Open: 1#2 Bug longer (nit)'
if printf '%s\n' "$trailers" | grep -q 'Finding-Fixed: 1#2'; then exit 1; fi
write_review_thread "$tmp/repo" "$AGENT_RUNS/ws/review-thread.jsonl"
write_review_thread "$tmp/repo" "$AGENT_RUNS/ws/review-thread.jsonl"
git -C "$tmp/repo" notes --ref=review show "$work" >"$tmp/note"
grep -Fqx 'a:2: blocking: 1#1 Bug — Breaks' "$tmp/note"
[ "$(grep -c '^# review:' "$tmp/note")" -eq 1 ]
git -C "$tmp/repo" notes --ref=review show "$fix" | grep -Fq '# fix: ws/2'
if git -C "$tmp/repo" notes --ref=review show "$foreign" 2>/dev/null; then exit 1; fi
# Retry uses the same host-written rows even after branches disappear and HEAD moves.
git -C "$tmp/repo" merge -q --no-ff agent/ws -m landed
git -C "$tmp/repo" branch -D agent/ws >/dev/null
write_review_thread "$tmp/repo" "$AGENT_RUNS/ws/review-thread.jsonl"
[ "$(git -C "$tmp/repo" notes --ref=review show "$work" | grep -c '^# review:')" -eq 1 ]
# No earlier writer means no review anchor, regardless of agent-recorded heads.
prepared=$(prepare_review_thread "$tmp/repo" "$ws" "$tmp/empty" 2>/dev/null)
[ ! -s "$tmp/empty" ]
# External review links still credit fixes even with equal timestamps.
printf '%s\n' "$ws" | jq --arg fix "$fix" '.reviews=[{id:"review.abc",at:"now",review:.sessions[1].review}] | .sessions=[.sessions[2] | .commits={".":[$fix]} | .review_session="review.abc" | .closing="```json\n{\"fixed\":[\"review.abc#1\"],\"declined\":[]}\n```"]' |
 jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' | grep -Fq 'Finding-Fixed: review.abc#1'
echo 'review thread tests passed'

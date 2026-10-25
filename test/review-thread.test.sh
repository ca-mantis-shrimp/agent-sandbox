#!/bin/sh
# Thread reduction and append-only notes use harvested objects, never workspace Git.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$tool/lib/agent-runs.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
git init -q "$tmp/repo"
git -C "$tmp/repo" commit -q --allow-empty -m base
base=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" commit -q --allow-empty -m fix
fixed=$(git -C "$tmp/repo" rev-parse HEAD)
ws=$(jq -n --arg base "$base" --arg fixed "$fixed" '{id:"ws",sessions:[
 {n:1,read_only:true,model:"reviewer",head_at_start:{".":$base},review:{coverage:[],for_human:[],verdict:"land after fixes",findings:[
 {file:"a",line:2,severity:"blocking",what:"Bug",why:"Breaks"},
 {severity:"nit",what:"Bug longer",why:"Style"},
 {severity:"should-fix",what:"Other",why:"Oops"}]}},
 {n:2,read_only:false,commits:{".":[$fixed]},closing:"```json\n{\"fixed\":[\"1#1\",\"Bug long\"],\"declined\":[{\"id\":\"1#3\",\"why\":\"Intentional\"}]}\n```"}
]}')
trailers=$(printf '%s\n' "$ws" | jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers')
printf '%s\n' "$trailers" | grep -Fqx "Finding-Fixed: 1#1 $(printf %.7s "$fixed") Bug (blocking)"
printf '%s\n' "$trailers" | grep -Fqx 'Finding-Open: 1#2 Bug longer (nit)'
printf '%s\n' "$trailers" | grep -Fqx 'Finding-Open: 1#3 Other (should-fix)'
if printf '%s\n' "$trailers" | grep -q 'Finding-Fixed: 1#2'; then exit 1; fi
# Exact legacy text only, not a prefix, can resolve a finding.
printf '%s\n' "$ws" | jq '.sessions[1].closing="```json\n{\"fixed\":[\"Bug longer\"],\"declined\":[]}\n```"' |
 jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' | grep -Fq 'Finding-Fixed: 1#2'
# No produced commit, malformed report or earlier session cannot claim a fix.
for change in 'del(.sessions[1].commits)' '.sessions[1].closing="broken"' '.sessions[1].n=0'; do
 if printf '%s\n' "$ws" | jq "$change" | jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' | grep -q Finding-Fixed; then exit 1; fi
done
write_review_thread "$tmp/repo" "$ws"
write_review_thread "$tmp/repo" "$ws"
git -C "$tmp/repo" notes --ref=review show "$base" >"$tmp/review"
[ "$(grep -c '# review:' "$tmp/review")" -eq 1 ]
grep -Fqx 'a:2: blocking: 1#1 Bug — Breaks' "$tmp/review"
git -C "$tmp/repo" notes --ref=review show "$fixed" >"$tmp/fix"
grep -Fq '1#1' "$tmp/fix"
grep -Fq '1#3' "$tmp/fix"
# A second reviewer on the same commit appends, never replaces.
ws2=$(printf '%s\n' "$ws" | jq '.sessions=[.sessions[0] | .n=3 | .model="second"]')
write_review_thread "$tmp/repo" "$ws2"
git -C "$tmp/repo" notes --ref=review show "$base" >"$tmp/review"
[ "$(grep -c '# review:' "$tmp/review")" -eq 2 ]
grep -Fq '1#1 Bug' "$tmp/review"
grep -Fq '3#1 Bug' "$tmp/review"
# A report answering a different review cannot resolve this thread.
if printf '%s\n' "$ws" | jq '.sessions[1].review_session="99"' |
 jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' | grep -q Finding-Fixed; then exit 1; fi
# A submodule-only fix still has a produced commit to cite.
printf '%s\n' "$ws" | jq '.sessions[1].commits |= {sub:.["."]}' |
 jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' | grep -Fq 'Finding-Fixed: 1#1'
# The newest review starts its own thread; old fix IDs cannot resolve it.
if printf '%s\n' "$ws" | jq '.sessions += [.sessions[0] | .n=3]' |
 jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' | grep -q Finding-Fixed; then exit 1; fi
# Exact duplicate legacy texts are ambiguous, so neither is silently fixed.
if printf '%s\n' "$ws" | jq '.sessions[0].review.findings[1].what="Bug" |
 .sessions[1].closing="```json\n{\"fixed\":[\"Bug\"],\"declined\":[]}\n```"' |
 jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' | grep -q Finding-Fixed; then exit 1; fi
# Agent-controlled repository paths must never send host Git to another clone.
bad=$(printf '%s\n' "$ws" | jq --arg base "$base" '.sessions=[.sessions[0] | .head_at_start={"../repo":$base}]')
if write_review_thread "$tmp/repo" "$bad"; then exit 1; fi
echo 'review thread tests passed'

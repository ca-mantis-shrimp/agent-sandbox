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
origin=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" commit -q --allow-empty -m work
base=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" commit -q --allow-empty -m fix
fixed=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" branch agent/ws
ws=$(jq -n --arg origin "$origin" --arg base "$base" --arg fixed "$fixed" '{id:"ws",base:$origin,sessions:[
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
write_review_thread "$tmp/repo" "$bad" 2>"$tmp/rejected"
grep -Fq '../repo' "$tmp/rejected"

# An explicit link credits external reviews even at the same second (or with
# skewed clocks); legacy records without a link use inclusive time ordering.
external=$(printf '%s\n' "$ws" | jq '.reviews=[{id:"review.abc",at:"2026-10-25T12:00:00Z",review:.sessions[0].review}] |
 .sessions=[.sessions[1] | .review_session="review.abc" | .started="2026-10-25T12:00:00Z" |
 .closing="```json\n{\"fixed\":[\"review.abc#1\"],\"declined\":[]}\n```"]')
for change in '.' '.sessions[0].started="2026-10-25T11:59:59Z"' 'del(.sessions[0].review_session)'; do
 printf '%s\n' "$external" | jq "$change" | jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' | grep -Fq 'Finding-Fixed: review.abc#1'
done
printf '%s\n' "$external" | jq -r -L "$tool/lib" 'include "agent-review"; review_thread_records | .text' | grep -Fqx 'answers review file: review.abc'

# A submodule workspace: unchanged pins get no notes; changed pins do.
git init -q "$tmp/sub-src"
git -C "$tmp/sub-src" commit -q --allow-empty -m sub-base
subbase=$(git -C "$tmp/sub-src" rev-parse HEAD)
git -C "$tmp/repo" -c protocol.file.allow=always submodule -q add "$tmp/sub-src" sub
git -C "$tmp/repo" commit -qam 'add submodule'
subrootbase=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" commit -q --allow-empty -m 'root work'
rootwork=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo" branch -f agent/subws
subws=$(printf '%s\n' "$ws" | jq --arg base "$subrootbase" --arg root "$rootwork" --arg sub "$subbase" '
 .id="subws" | .base=$base | .sessions=[.sessions[0] | .head_at_start={"sub":$sub,".":$root}]')
write_review_thread "$tmp/repo" "$subws" 2>"$tmp/rejected"
if git -C "$tmp/repo/sub" notes --ref=review show "$subbase" 2>/dev/null; then exit 1; fi
git -C "$tmp/repo" notes --ref=review show "$rootwork" | grep -Fq '# review:'
git -C "$tmp/repo/sub" commit -q --allow-empty -m 'sub work'
subwork=$(git -C "$tmp/repo/sub" rev-parse HEAD)
git -C "$tmp/repo/sub" branch agent/subws
subws=$(printf '%s\n' "$subws" | jq --arg sub "$subwork" '.sessions[0].head_at_start.sub=$sub')
write_review_thread "$tmp/repo" "$subws"
git -C "$tmp/repo/sub" notes --ref=review show "$subwork" | grep -Fq '# review:'

# A missing host path is rejected per row, not a reason to lose later root rows.
rows=$(printf '%s\n' "$subws" | jq --arg root "$rootwork" '.sessions[0].n=9 | .sessions[0].head_at_start={"missing":$root,".":$root}')
write_review_thread "$tmp/repo" "$rows" 2>"$tmp/rejected"
grep -Fq 'missing' "$tmp/rejected"
git -C "$tmp/repo" notes --ref=review show "$rootwork" | grep -Fq 'subws/9'

# Existing commits outside base..workspace are not valid note or fix anchors.
git -C "$tmp/repo" checkout -q --detach "$subrootbase"
git -C "$tmp/repo" commit -q --allow-empty -m 'other workspace'
foreign=$(git -C "$tmp/repo" rev-parse HEAD)
for forged in "$subrootbase" "$origin" "$foreign"; do
 forgedws=$(printf '%s\n' "$subws" | jq --arg sha "$forged" '.sessions[0].head_at_start={".":$sha}')
 write_review_thread "$tmp/repo" "$forgedws" 2>"$tmp/rejected"
 grep -Fq "$forged" "$tmp/rejected"
 if git -C "$tmp/repo" notes --ref=review show "$forged" 2>/dev/null; then exit 1; fi
 forgedws=$(printf '%s\n' "$ws" | jq --arg sha "$forged" '.sessions[1].commits={".":[$sha]}')
 trailers=$(review_finding_trailers "$tmp/repo" "$forgedws")
 if printf '%s\n' "$trailers" | grep -q Finding-Fixed; then exit 1; fi
done
review_finding_trailers "$tmp/repo" "$ws" | grep -Fq 'Finding-Fixed: 1#1'
# After landing, deleted workspace branches are replaced by the recorded landing
# commit, including its pinned submodule commit, never the host's current HEAD.
git -C "$tmp/repo" checkout -q agent/subws
git -C "$tmp/repo" add sub
git -C "$tmp/repo" commit -qm 'pin changed sub'
# Another workspace landed after our base, in both root and submodule.
git -C "$tmp/repo/sub" checkout -q --detach "$subbase"
git -C "$tmp/repo/sub" commit -q --allow-empty -m 'foreign sub work'
subforeign=$(git -C "$tmp/repo/sub" rev-parse HEAD)
git -C "$tmp/repo" checkout -q --detach "$foreign"
git -C "$tmp/repo" add sub
git -C "$tmp/repo" commit -qm 'pin foreign sub work'
hosttip=$(git -C "$tmp/repo" rev-parse HEAD)
git -C "$tmp/repo/sub" merge -q --no-ff agent/subws -m 'land sub work'
git -C "$tmp/repo" merge -q --no-ff --no-commit agent/subws || :
git -C "$tmp/repo" add sub
git -C "$tmp/repo" commit -qm 'land workspace'
landed=$(git -C "$tmp/repo" rev-parse HEAD)
[ "$(git -C "$tmp/repo" rev-parse HEAD^1)" = "$hosttip" ]
git -C "$tmp/repo" checkout -q --detach
git -C "$tmp/repo" branch -D agent/subws >/dev/null
git -C "$tmp/repo/sub" branch -D agent/subws >/dev/null
subws=$(printf '%s\n' "$subws" | jq --arg landed "$landed" '.landed_commit=$landed | .sessions[0].n=10')
write_review_thread "$tmp/repo" "$subws"
git -C "$tmp/repo/sub" notes --ref=review show "$subwork" | grep -Fq 'subws/10'
# Neither main's post-base commits nor another workspace's submodule commits
# become valid on landing or retry; genuine merged-side anchors remain valid.
for pair in ". $foreign" "sub $subforeign"; do
 set -- $pair
 forgedws=$(printf '%s\n' "$subws" | jq --arg path "$1" --arg sha "$2" '
  .sessions[0].n=11 | .sessions[0].head_at_start={($path):$sha} |
  .sessions += [{n:12,commits:{($path):[$sha]},closing:"```json\n{\"fixed\":[\"11#1\"],\"declined\":[]}\n```"}]')
 write_review_thread "$tmp/repo" "$forgedws" 2>"$tmp/rejected"
 grep -Fq "$2" "$tmp/rejected"
 if git -C "$tmp/repo/$1" notes --ref=review show "$2" 2>/dev/null; then exit 1; fi
 if review_finding_trailers "$tmp/repo" "$forgedws" | grep -q Finding-Fixed; then exit 1; fi
done
validws=$(printf '%s\n' "$subws" | jq --arg sub "$subwork" '.sessions += [
 {n:11,commits:{sub:[$sub]},closing:"```json\n{\"fixed\":[\"10#1\"],\"declined\":[]}\n```"}]')
review_finding_trailers "$tmp/repo" "$validws" | grep -Fq 'Finding-Fixed: 10#1'
# A branch-added submodule has no base: do not claim its entire history.
# Multiple rows produce a single missing-base warning, not one per row.
added=$(printf '%s\n' "$subws" | jq --arg base "$origin" '
 .base=$base | .sessions=[.sessions[0], (.sessions[0] | .n=20)]')
write_review_thread "$tmp/repo" "$added" 2>"$tmp/rejected"
[ "$(grep -c 'missing workspace base.*sub' "$tmp/rejected")" -eq 1 ]
echo 'review thread tests passed'

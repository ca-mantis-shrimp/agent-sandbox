#!/bin/sh
# Per-repository S excludes host work; untouched or branch-added modules get no notes.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$tool/lib/agent-runs.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
git init -q "$tmp/sub"
git -C "$tmp/sub" commit -q --allow-empty -m base
subbase=$(git -C "$tmp/sub" rev-parse HEAD)
git init -q "$tmp/root"
git -C "$tmp/root" -c protocol.file.allow=always submodule -q add "$tmp/sub" sub
git -C "$tmp/root" commit -qm base
base=$(git -C "$tmp/root" rev-parse HEAD)
git -C "$tmp/root" switch -qc agent/ws
git -C "$tmp/root" commit -q --allow-empty -m root-work
root=$(git -C "$tmp/root" rev-parse HEAD)
git -C "$tmp/root" checkout -q --detach "$base"
ws=$(jq -n --arg root "$root" --arg sub "$subbase" '{id:"ws",sessions:[
 {n:1,commits:{".":[$root],sub:[$sub],added:[$root]}},
 {n:2,read_only:true,review:{coverage:[],findings:[],for_human:[],verdict:"land"}}
]}')
prepared=$(prepare_review_thread "$tmp/root" "$ws" "$tmp/thread" 2>"$tmp/warn")
[ "$(wc -l <"$tmp/thread")" -eq 1 ]
jq -e '.path == "."' "$tmp/thread" >/dev/null
# A real module writer and fixer each use their newest member of S.
git -C "$tmp/root/sub" switch -qc agent/ws
git -C "$tmp/root/sub" commit -q --allow-empty -m work
work=$(git -C "$tmp/root/sub" rev-parse HEAD)
git -C "$tmp/root/sub" commit -q --allow-empty -m fix
fix=$(git -C "$tmp/root/sub" rev-parse HEAD)
git -C "$tmp/root/sub" checkout -q --detach "$subbase"
git -C "$tmp/root/sub" commit -q --allow-empty -m host-work
foreign=$(git -C "$tmp/root/sub" rev-parse HEAD)
ws=$(printf '%s\n' "$ws" | jq --arg work "$work" --arg fix "$fix" --arg foreign "$foreign" '
 .sessions[0].commits.sub=[$foreign,$work] |
 .sessions[1].review.findings=[{file:"a",line:1,severity:"blocking",what:"Bug",why:"Fails"}] |
 .sessions += [{n:3,review_session:"2",commits:{sub:[$work,$foreign,$fix]},closing:"```json\n{\"fixed\":[\"2#1\"],\"declined\":[]}\n```"}]')
prepared=$(prepare_review_thread "$tmp/root" "$ws" "$tmp/thread" 2>"$tmp/warn")
[ "$(grep -c warning "$tmp/warn")" -eq 1 ]
[ "$(wc -l <"$tmp/thread")" -eq 3 ]
printf '%s\n' "$prepared" | jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' |
 grep -Fqx "Finding-Fixed: 2#1 $(printf %.7s "$fix") Bug (blocking)"
write_review_thread "$tmp/root" "$tmp/thread"
git -C "$tmp/root/sub" notes --ref=review show "$work" | grep -Fq '# review:'
git -C "$tmp/root/sub" notes --ref=review show "$fix" | grep -Fq '# fix:'
if git -C "$tmp/root/sub" notes --ref=review show "$foreign" 2>/dev/null; then exit 1; fi
# Claiming only foreign commits can neither anchor a review nor credit a fix.
ws=$(printf '%s\n' "$ws" | jq --arg foreign "$foreign" '.sessions[0].commits={sub:[$foreign]} | .sessions[2].commits={sub:[$foreign]}')
prepared=$(prepare_review_thread "$tmp/root" "$ws" "$tmp/thread" 2>/dev/null)
[ ! -s "$tmp/thread" ]
if printf '%s\n' "$prepared" | jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' | grep -q Finding-Fixed; then exit 1; fi
echo 'host review tests passed'

#!/bin/sh
set -eu
export AGENT_VERDICT_HOOK= # never wake a real steward from a test
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$tool/lib/agent-runs.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_RUNS="$tmp/runs"
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@localhost GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@localhost
mkdir -p "$AGENT_RUNS/ws/sessions"
git init -q "$tmp/repo"
git -C "$tmp/repo" commit -q --allow-empty -m 'feat: work' -m 'Finding-Open: 1#1 Bug (blocking)'
commit=$(git -C "$tmp/repo" rev-parse HEAD)
jq -n --arg repo "$tmp/repo" --arg commit "$commit" '{repo:$repo,landed:"now",landed_commit:$commit}' >"$AGENT_RUNS/ws/manifest.json"
printf '{"label":"example"}\n' >"$AGENT_RUNS/ws/sessions/1.json"
printf '# review ws/1: land by reviewer\na:2: blocking: 1#1 Bug — Why\n/srv/job/ws/work/sub/b:3: nit: 1#2 Style — Why\n' | git -C "$tmp/repo" notes --ref=review add -F - "$commit"
printf '%s\n' '# fix ws/2 by fixer, answering review 1' 'fixed: legacy a.sh:3: repaired' 'declined: 1#2 — see a.sh:3: intentional' '# heading a.sh:3: context' | git -C "$tmp/repo" notes --ref=review append -F - "$commit"
# Show reads Git notes, not a stale saved file.
printf 'stale\n' >"$AGENT_RUNS/ws/review-thread.txt"
printf '# verdict: first\n' | git -C "$tmp/repo" notes --ref=verdict append -F - "$commit"
printf '# verdict: second\n' | git -C "$tmp/repo" notes --ref=verdict append -F - "$commit"
(cd / && "$tool/bin/agent" show ws) >"$tmp/show"
grep -Fqx "$tmp/repo/a:2: blocking: 1#1 Bug — Why" "$tmp/show"
grep -Fqx "$tmp/repo/sub/b:3: nit: 1#2 Style — Why" "$tmp/show"
grep -Fqx 'fixed: legacy a.sh:3: repaired' "$tmp/show"
grep -Fqx 'declined: 1#2 — see a.sh:3: intentional' "$tmp/show"
grep -Fqx '# heading a.sh:3: context' "$tmp/show"
if grep -q stale "$tmp/show"; then exit 1; fi
grep -Fq 'Finding-Open: 1#1' "$tmp/show"
[ "$(grep -c '^# verdict:' "$tmp/show")" -eq 2 ]
"$tool/bin/agent-verdict" --pending >"$tmp/pending"
[ "$(cut -f4 "$tmp/pending")" = "$commit" ]
"$tool/bin/agent" show - <"$tmp/pending" >"$tmp/stdin"
cmp "$tmp/show" "$tmp/stdin"
printf 'ws\tignored\nsecond\n' | "$tool/bin/agent-verdict" - --by human --agree
jq -e '.human_verdict.agrees_with_review' "$AGENT_RUNS/ws/manifest.json" >/dev/null
if printf '\n' | "$tool/bin/agent" show -; then exit 1; fi
echo 'show tests passed'

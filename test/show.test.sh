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
printf '{"label":"example","review":{"findings":[{"what":"Bug","severity":"blocking"}]}}\n' >"$AGENT_RUNS/ws/sessions/1.json"
printf '# review ws/1: land by reviewer\na:2: blocking: 1#1 Bug — Why\n/srv/job/ws/work/sub/b:3: nit: 1#2 Style — Why\n' | git -C "$tmp/repo" notes --ref=review add -F - "$commit"
printf '%s\n' '# fix ws/2 by fixer, answering review 1' 'fixed: legacy a.sh:3: repaired' 'declined: 1#2 — see a.sh:3: intentional' '# heading a.sh:3: context' | git -C "$tmp/repo" notes --ref=review append -F - "$commit"
# Show reads Git notes, not a stale saved file.
printf 'stale\n' >"$AGENT_RUNS/ws/review-thread.txt"
printf '# verdict: first\n' | git -C "$tmp/repo" notes --ref=verdict append -F - "$commit"
printf '# verdict: second\n' | git -C "$tmp/repo" notes --ref=verdict append -F - "$commit"
# Freeze the old full output, including its blank lines and final newline.
printf '# review ws/1: land by reviewer\n%s/a:2: blocking: 1#1 Bug — Why\n%s/sub/b:3: nit: 1#2 Style — Why\n\n# fix ws/2 by fixer, answering review 1\nfixed: legacy a.sh:3: repaired\ndeclined: 1#2 — see a.sh:3: intentional\n# heading a.sh:3: context\n\n# landing: %s\nFinding-Open: 1#1 Bug (blocking)\n\n# verdict: first\n\n# verdict: second\n' "$tmp/repo" "$tmp/repo" "$commit" >"$tmp/old-output"
(cd / && "$tool/bin/agent" show --all ws) >"$tmp/show"
cmp "$tmp/old-output" "$tmp/show"
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
"$tool/bin/agent" show --all - <"$tmp/pending" >"$tmp/stdin"
cmp "$tmp/show" "$tmp/stdin"
# Without a steward note, show only open trailers (not reviews or human notes).
printf 'Finding-Open: 1#1 Bug (blocking)\n' >"$tmp/open"
"$tool/bin/agent" show ws >"$tmp/short"
cmp "$tmp/open" "$tmp/short"
git -C "$tmp/repo" notes --ref=verdict remove "$commit" >/dev/null
"$tool/bin/agent" show ws >"$tmp/short"
cmp "$tmp/open" "$tmp/short"
"$tool/bin/agent-verdict" ws --by human --agree --note 'Human judgment'
"$tool/bin/agent" show ws >"$tmp/short"
cmp "$tmp/open" "$tmp/short"
# The newest non-human bundle verdict wins, not manifest state, human verdicts,
# or newer finding comments. Its recorded block is printed without extra text.
"$tool/bin/agent-verdict" ws --by facilitator --agree --note 'Old steward note'
"$tool/bin/agent-verdict" ws --by orchestrator --disagree --overrule 'Already repaired' --note 'Need a decision: keep the current approach?'
git -C "$tmp/repo" notes --ref=verdict show "$commit" |
    tail -n 3 >"$tmp/steward"
"$tool/bin/agent-verdict" ws --by human --disagree --note 'New human judgment'
"$tool/bin/agent-verdict" ws --on 1#1 --by facilitator --note 'Finding comment, not landing note'
jq '.orchestrator_verdict.note = "stale manifest"' "$AGENT_RUNS/ws/manifest.json" >"$tmp/manifest"
mv "$tmp/manifest" "$AGENT_RUNS/ws/manifest.json"
"$tool/bin/agent" show ws >"$tmp/short"
cmp "$tmp/steward" "$tmp/short"
"$tool/bin/agent" show - <"$tmp/pending" >"$tmp/stdin"
cmp "$tmp/short" "$tmp/stdin"
# A later facilitator verdict supersedes the orchestrator's note too.
"$tool/bin/agent-verdict" ws --by facilitator --agree --note 'Nothing needed from you.'
git -C "$tmp/repo" notes --ref=verdict show "$commit" | tail -n 2 >"$tmp/steward"
"$tool/bin/agent" show ws >"$tmp/short"
cmp "$tmp/steward" "$tmp/short"
# No note and no open findings means no output, not a full historical thread.
git -C "$tmp/repo" commit -q --allow-empty -m 'feat: clean landing' -m 'Finding-Fixed: 1#1 Bug (blocking), by session 2'
clean=$(git -C "$tmp/repo" rev-parse HEAD)
jq --arg commit "$clean" '.landed_commit = $commit' "$AGENT_RUNS/ws/manifest.json" >"$tmp/manifest"
mv "$tmp/manifest" "$AGENT_RUNS/ws/manifest.json"
"$tool/bin/agent" show ws >"$tmp/short"
[ ! -s "$tmp/short" ]
# Restore the original landing for the stdin verdict check below.
jq --arg commit "$commit" '.landed_commit = $commit' "$AGENT_RUNS/ws/manifest.json" >"$tmp/manifest"
mv "$tmp/manifest" "$AGENT_RUNS/ws/manifest.json"
printf 'ws\tignored\nsecond\n' | "$tool/bin/agent-verdict" - --by human --agree
jq -e '.human_verdict.agrees_with_review' "$AGENT_RUNS/ws/manifest.json" >/dev/null
if printf '\n' | "$tool/bin/agent" show -; then exit 1; fi
echo 'show tests passed'

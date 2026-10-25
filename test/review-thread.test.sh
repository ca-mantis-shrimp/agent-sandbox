#!/bin/sh
# Decision 3: session records form one conversation, independent of commits.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
ws='{"id":"ws","sessions":[
 {"n":3,"model":"fixer","review_session":"2","closing":"```json\n{\"fixed\":[\"2#1\"],\"declined\":[{\"id\":\"2#2\",\"why\":\"Intentional\"}]}\n```"},
 {"n":2,"read_only":true,"model":"reviewer","review":{"coverage":[],"for_human":[],"verdict":"land after fixes","findings":[{"file":"a","line":2,"severity":"blocking","what":"Bug","why":"Breaks"},{"severity":"nit","what":"Style","why":"Simplify"}]}},
 {"n":1,"read_only":true,"model":"first","review":{"coverage":[],"for_human":[],"verdict":"land","findings":[]}}
]}'
printf '%s\n' "$ws" | jq -r -L "$tool/lib" 'include "agent-review"; review_thread_text' >"$tmp/thread"
printf '%s\n' '# review ws/1: land by first' '# review ws/2: land after fixes by reviewer' 'a:2: blocking: 2#1 Bug — Breaks' '(approach): nit: 2#2 Style — Simplify' '# fix ws/3 by fixer, answering review 2' 'fixed: 2#1' 'declined: 2#2 — Intentional' >"$tmp/expected"
cmp "$tmp/expected" "$tmp/thread"
printf '%s\n' "$ws" | jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' >"$tmp/trailers"
grep -Fqx 'Finding-Fixed: 2#1 Bug (blocking), by session 3' "$tmp/trailers"
grep -Fqx 'Finding-Open: 2#2 Style (nit)' "$tmp/trailers"
# An explicit link, not time order, decides which review a fix answers.
printf '%s\n' "$ws" | jq '.sessions[0].review_session="1"' | jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' >"$tmp/trailers"
if grep -q Finding-Fixed "$tmp/trailers"; then exit 1; fi
# Legacy reports still match exact, unambiguous text; never prefixes.
printf '%s\n' "$ws" | jq 'del(.sessions[0].review_session) | .sessions[0].closing="```json\n{\"fixed\":[\"Bug\",\"Sty\"],\"declined\":[]}\n```"' | jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' >"$tmp/trailers"
grep -Fqx 'Finding-Fixed: 2#1 Bug (blocking), by session 3' "$tmp/trailers"
grep -Fqx 'Finding-Open: 2#2 Style (nit)' "$tmp/trailers"
# Equal timestamps do not defeat explicit links to external reviews.
printf '%s\n' "$ws" | jq '.reviews=[{id:"review.abc",at:"now",review:.sessions[1].review}] | .sessions=[.sessions[0] | .review_session="review.abc" | .closing="```json\n{\"fixed\":[\"review.abc#1\"],\"declined\":[]}\n```"]' | jq -r -L "$tool/lib" 'include "agent-review"; finding_trailers' | grep -Fqx 'Finding-Fixed: review.abc#1 Bug (blocking), by session 3'
# File reviews retain their ids and participate in chronological conversation order.
printf '%s\n' "$ws" | jq '.sessions |= map(.started = (if .n == 1 then "a" else "c" end)) | .reviews=[{id:"review.abc",at:"b",reviewer:"external",review:.sessions[1].review}]' | jq -r -L "$tool/lib" 'include "agent-review"; review_thread_text' >"$tmp/thread"
printf '%s\n' '# review ws/1: land by first' '# review ws/review.abc: land after fixes by external' 'a:2: blocking: review.abc#1 Bug — Breaks' '(approach): nit: review.abc#2 Style — Simplify' '# review ws/2: land after fixes by reviewer' 'a:2: blocking: 2#1 Bug — Breaks' '(approach): nit: 2#2 Style — Simplify' '# fix ws/3 by fixer, answering review 2' 'fixed: 2#1' 'declined: 2#2 — Intentional' >"$tmp/expected"
cmp "$tmp/expected" "$tmp/thread"
# Without an explicit link the conversation does not guess attribution.
printf '%s\n' "$ws" | jq 'del(.sessions[0].review_session)' | jq -r -L "$tool/lib" 'include "agent-review"; review_thread_text' | grep -Fqx '# fix ws/3 by fixer, answering review unknown'
echo 'review thread tests passed'

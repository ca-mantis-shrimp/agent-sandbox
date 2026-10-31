#!/bin/sh
set -eu
for v in $(env | sed -n 's/^\(AGENT_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tool/bin" "$tmp/tool/lib" "$tmp/runs/ws/sessions"
cp "$tool/bin/agent-review-status" "$tmp/tool/bin/"
cp "$tool/bin/agent-result" "$tmp/tool/bin/"
cp "$tool/lib/agent-runs.sh" "$tool/lib/agent-systemd.sh" "$tool/lib/agent-review.jq" "$tmp/tool/lib/"
printf '#!/bin/sh\nexit 0\n' >"$tmp/tool/bin/agent-reconcile"
chmod +x "$tmp/tool/bin/agent-reconcile"
# agent-result only reaches systemctl when a running record is waited on.
mkdir "$tmp/stubs"
printf '#!/bin/sh\nprintf "active\\n"\n' >"$tmp/stubs/systemctl"
chmod +x "$tmp/stubs/systemctl"
export PATH="$tmp/stubs:$PATH" AGENT_RUNS="$tmp/runs"
report() {
    jq -cn --arg v "$1" '{coverage:[],findings:[],for_human:[],verdict:$v}'
}
closing() { printf 'Review follows.\n```json\n%s\n```' "$1"; }
record() { # <n> <read_only> <state> <verdict|unparsed>
    n=$1 ro=$2 state=$3 verdict=$4
    if [ "$verdict" = unparsed ]; then body=$(closing '{broken}'); else body=$(closing "$(report "$verdict")"); fi
    jq -n --argjson n "$n" --argjson ro "$ro" --arg state "$state" --arg closing "$body" \
        '{n:$n,read_only:$ro,state:$state,closing:$closing}' >"$tmp/runs/ws/sessions/$n.json"
}
manifest() { jq -n '{state:"ready",sessions:[]}' >"$tmp/runs/ws/manifest.json"; }
run() { AGENT_RUNS="$tmp/runs" sh "$tmp/tool/bin/agent-review-status" "$@"; }
expect() { # <ref> <stdout> <status>
    ref=$1 expected=$2 status=$3
    set +e
    output=$(run "$ref" 2>"$tmp/err")
    actual=$?
    set -e
    [ "$actual" -eq "$status" ] || { printf 'expected exit %s, got %s: %s\n' "$status" "$actual" "$ref" >&2; exit 1; }
    [ "$output" = "$expected" ] || { printf 'expected stdout <%s>, got <%s>\n' "$expected" "$output" >&2; exit 1; }
}
manifest
record 1 true finished land
expect ws 'land' 0
record 2 true finished 'land after fixes'
expect ws 'land after fixes' 10
record 3 true finished 'do not land'
expect ws 'do not land' 11
record 4 true finished unparsed
expect ws 'needs person: review unparsed' 12
# Latest means latest read-only session even when it cannot be parsed; don't
# fall back to the earlier parsed "land" result.
record 1 true finished land
record 2 true finished unparsed
expect ws 'needs person: review unparsed' 12
record 4 true failed land
expect ws 'needs person: session failed' 12
record 4 true running land
expect ws 'needs person: session not finished' 12
record 2 false finished land
expect ws/2 'needs person: session is not read-only' 12
expect ws/99 'needs person: no review' 12
# A missing workspace is a usage/data error, distinct from a review decision.
set +e
output=$(run missing 2>"$tmp/err")
status=$?
set -e
[ "$status" -eq 2 ] && [ -z "$output" ]
# Wait is forwarded to agent-result for the selected session.
cat >"$tmp/tool/bin/agent-result" <<'STUB'
#!/bin/sh
case "$*" in
    'ws') printf '{"sessions":[{"n":7,"read_only":true,"state":"running"}]}\n' ;;
    'ws/7 --wait') report='{"coverage":[],"findings":[],"for_human":[],"verdict":"land"}'; jq -cn --arg report "$report" '{n:7,read_only:true,state:"finished",review:($report|fromjson),closing:("```json\n"+$report+"\n```")}';;
    *) echo "unexpected agent-result args: $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$tmp/tool/bin/agent-result"
set +e
output=$(run ws --wait 2>"$tmp/err")
status=$?
set -e
[ "$status" -eq 0 ] && [ "$output" = land ] || { printf 'wait result failed: status=%s output=<%s>\n' "$status" "$output" >&2; cat "$tmp/err" >&2; exit 1; }
printf 'agent-review-status tests passed\n'

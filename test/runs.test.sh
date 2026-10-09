#!/bin/sh
#
# Tests lib/agent-runs.sh: references, and the workspace document that
# every reader goes through. No host units needed; each assertion
# aborts the script under set -e, so reaching the final line is the pass.
set -eu

tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$tool/lib/agent-runs.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- references -------------------------------------------------------------

[ "$(ref_workspace 20260930-010203)" = 20260930-010203 ]
[ "$(ref_workspace 20260930-010203/2)" = 20260930-010203 ]
[ -z "$(ref_session 20260930-010203)" ]
[ "$(ref_session 20260930-010203/2)" = 2 ]

AGENT_RUNS=$tmp/elsewhere
[ "$(runs_dir)" = "$tmp/elsewhere" ]
unset AGENT_RUNS
[ "$(runs_dir)" = /var/lib/agent-runs ]

# --- a workspace with no sessions reports its own state ----------------------

ws="$tmp/ws"
mkdir -p "$ws/sessions"
echo '{"id": "ws", "state": "ready", "started": "2026-09-30T01:00:00-07:00"}' >"$ws/manifest.json"
[ "$(workspace_json "$ws" | jq -c '[.state, (.sessions | length)]')" = '["ready",0]' ]
[ -z "$(running_sessions "$ws")" ]

# --- sessions come back in order, and the newest decides the state ----------

# Written out of order, and 10 sorts before 2 as a file name.
echo '{"n": 10, "state": "failed", "model": "c"}' >"$ws/sessions/10.json"
echo '{"n": 2, "state": "finished", "model": "b"}' >"$ws/sessions/2.json"
echo '{"n": 1, "state": "finished", "model": "a"}' >"$ws/sessions/1.json"
[ "$(workspace_json "$ws" | jq -c '[.state, [.sessions[].model]]')" = '["failed",["a","b","c"]]' ]

# --- any running session makes the workspace running ------------------------

echo '{"n": 2, "state": "running", "model": "b", "read_only": true}' >"$ws/sessions/2.json"
[ "$(workspace_json "$ws" | jq -r .state)" = running ]
[ "$(running_sessions "$ws")" = 2 ]
# The manifest's own facts survive the merge.
[ "$(workspace_json "$ws" | jq -r .id)" = ws ]

# --- a manifest from before sessions had their own records passes through ---

old="$tmp/old"
mkdir -p "$old"
echo '{"id": "old", "state": "finished", "model": "m", "sessions": [{"action": "a", "outcome": "completed", "why": "done"}]}' \
    >"$old/manifest.json"
[ "$(workspace_json "$old" | jq -c '[.state, .sessions[0].outcome, (.sessions | length)]')" = '["finished","completed",1]' ]
[ -z "$(running_sessions "$old")" ]

# --- repo_commits lists each repo's commits since a ref ----------------------

repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$repo" update-ref refs/agent/base HEAD
[ "$(repo_commits "$repo" refs/agent/base)" = '{}' ]
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m two
[ "$(repo_commits "$repo" refs/agent/base | jq -c '.["."] | length')" = 2 ]
[ "$(repo_commits "$repo" refs/agent/missing)" = '{}' ]

# --- new workspaces snapshot pi config, never login or mount declarations ---
export AGENT_RUNS="$tmp/new-runs" HOME="$tmp/home"
mkdir -p "$HOME/.pi/agent/agents" "$repo/.sandbox"
printf '%s\n' '{"packages":["npm:remote-pi","npm:keep"],"theme":"test"}' >"$HOME/.pi/agent/settings.json"
echo custom >"$HOME/.pi/agent/agents/custom.md"
echo private-login >"$HOME/.pi/agent/auth.json"
echo 'obsolete /must-not-create' >"$repo/.sandbox/volumes"
git -C "$repo" add .sandbox/volumes
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m config
id=$(cd "$repo" && "$tool/bin/agent-new")
run="$AGENT_RUNS/$id"
[ -d "$run/work" ] && [ -d "$run/home" ] && [ -d "$run/agents" ]
[ -z "$(find "$run/home" -mindepth 1 -print)" ]
[ "$(readlink "$run/pi/auth.json")" = /srv/pi-login/auth.json ]
jq -e '.packages == ["npm:keep"] and .theme == "test"' "$run/pi/settings.json" >/dev/null
[ "$(cat "$run/pi/agents/custom.md")" = custom ]
[ ! -e "$run/work/must-not-create" ]
rm -rf "$HOME/.pi"
id=$(cd "$repo" && "$tool/bin/agent-new")
[ "$(readlink "$AGENT_RUNS/$id/pi/auth.json")" = /srv/pi-login/auth.json ]
[ ! -e "$AGENT_RUNS/$id/pi/settings.json" ]
[ ! -e "$AGENT_RUNS/$id/pi/agents" ]

printf 'agent-runs tests passed\n'

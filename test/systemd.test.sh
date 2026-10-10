#!/bin/sh
# Run-directory contract and static unit lifecycle, with no real host units.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$tool/lib/agent-runs.sh"
. "$tool/lib/agent-systemd.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_RUNS="$tmp/runs" AGENT_BASE="$tmp/base" AGENT_LAYERS="$tmp/images" HOME="$tmp/home"
export XDG_RUNTIME_DIR="$tmp/runtime"
mkdir -p "$AGENT_RUNS/ws/work" "$AGENT_BASE" "$AGENT_LAYERS" "$tmp/bin" "$HOME"
run="$AGENT_RUNS/ws"
# Host identities are fixtures, never the session's passwd/group databases.
printf '%s\n' '#!/bin/sh' \
    '[ "${GETENT_FAIL:-}" != "$1" ] || exit 2' \
    'case "$*" in' \
    '  "passwd agent") printf '\''agent:x:%s:812:Agent "worker":/home/agent:/usr/bin/nologin\n'\'' "${TEST_AGENT_UID:-731}" ;;' \
    '  "group agents") echo "agents:x:${TEST_AGENTS_GID:-812}:" ;;' \
    '  *) exit 2 ;;' \
    'esac' >"$tmp/bin/getent"
chmod +x "$tmp/bin/getent"
export PATH="$tmp/bin:$PATH"
[ "$(agent_unit ws)" = agent@ws.service ]
[ "$(agent_unit 20260930-010203)" = agent@20260930-010203.service ]
if agent_unit '../bad' >/dev/null 2>&1; then exit 1; fi
fails() { if "$@"; then echo "expected failure: $*" >&2; exit 1; fi; }
[ "$(agent_lock_path ws)" = "$XDG_RUNTIME_DIR/agent-sandbox/ws.lock" ]
[ "$(stat -c %a "$XDG_RUNTIME_DIR/agent-sandbox")" = 700 ]
fails agent_lock_path '../bad'
# Probe the default path without creating anything in the host runtime.
[ "$(unset XDG_RUNTIME_DIR; mkdir() { :; }; agent_lock_path ws)" = "/run/user/$(id -u)/agent-sandbox/ws.lock" ]
fails write_agent_run "$run" /repo/example claude model 1 false 2>"$tmp/error"
grep -qF "$AGENT_LAYERS/harness.raw" "$tmp/error"
# Without a project layer a run still starts, on base + harness, and says so once.
touch "$AGENT_LAYERS/harness.raw"
write_agent_run "$run" /repo/example claude model 1 false 2>"$tmp/error"
[ "$(cat "$tmp/error")" = 'agent-sandbox > no project layer for example; running on base + harness' ]
[ "$(readlink "$run/layers/harness.raw")" = "$AGENT_LAYERS/harness.raw" ]
[ ! -e "$run/layers/project.raw" ] && [ ! -L "$run/layers/project.raw" ]
[ ! -L "$run/layers/project-etc.raw" ]
# With one, the run links it and stays quiet.
touch "$AGENT_LAYERS/example.raw" "$AGENT_LAYERS/example-etc.raw"
write_agent_run "$run" /repo/example claude model 1 false 2>"$tmp/error"
[ ! -s "$tmp/error" ]
# Records preserve host fields and escape text through jq; aliases follow them.
jq -e '. == {userName:"agent", uid:731, gid:812, realName:"Agent \"worker\"",
    homeDirectory:"/home/agent", shell:"/usr/bin/nologin", disposition:"system"}' "$run/userdb/agent.user" >/dev/null
jq -e '. == {groupName:"agents", gid:812}' "$run/userdb/agents.group" >/dev/null
[ "$(readlink "$run/userdb/731.user")" = agent.user ]
[ "$(readlink "$run/userdb/812.group")" = agents.group ]
for record in "$run/userdb"/*; do
    [ "$(stat -Lc %a "$record")" = 644 ]
done
grep -qxF 'User=agent' "$tool/system/usr/lib/systemd/system/agent@.service"
grep -qxF 'Group=agents' "$tool/system/usr/lib/systemd/system/agent@.service"
# Shared host networking permits loopback without a resolver-only exception;
# preserve the LAN, link-local and multicast block exactly.
grep -qxF 'IPAddressDeny=link-local multicast 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 fc00::/7' "$tool/system/usr/lib/systemd/system/agent@.service"
! grep -q '^IPAddressAllow=' "$tool/system/usr/lib/systemd/system/agent@.service"
! grep -q '^PrivateNetwork=yes' "$tool/system/usr/lib/systemd/system/agent@.service"
grep -qxF 'BindReadOnlyPaths=-/var/lib/agent-runs/%i/userdb:/run/host/userdb' "$tool/system/usr/lib/systemd/system/agent@.service"
# Every run replaces records, their permissions and aliases, with current IDs.
echo stale >"$run/userdb/agent.user"
chmod 0600 "$run/userdb/agents.group"
TEST_AGENT_UID=732 TEST_AGENTS_GID=813 write_agent_run "$run" /repo/example pi model 2 false
jq -e '.uid == 732' "$run/userdb/agent.user" >/dev/null
jq -e '.gid == 813' "$run/userdb/agents.group" >/dev/null
[ ! -L "$run/userdb/731.user" ] && [ ! -L "$run/userdb/812.group" ]
[ "$(readlink "$run/userdb/732.user")" = agent.user ]
[ "$(readlink "$run/userdb/813.group")" = agents.group ]
for record in "$run/userdb"/*; do
    [ "$(stat -Lc %a "$record")" = 644 ]
done
for database in passwd group; do
    GETENT_FAIL=$database fails write_agent_run "$run" /repo/example pi model 2 false 2>"$tmp/error"
    grep -q "getent $database .* failed" "$tmp/error"
done
AGENT_SESSION_USD=5 write_agent_run "$run" /repo/example claude 'a "model"' 1 true
[ "$(readlink "$run/root")" = "$AGENT_BASE" ]
[ "$(readlink "$run/cache")" = "$AGENT_RUNS/.cache/example" ]
[ -d "$run/cache" ]
[ -d "$run/work" ] && [ -d "$run/home" ] && [ -d "$run/agents" ]
[ "$(readlink "$run/pi/auth.json")" = /srv/pi-login/auth.json ]
# Mounts must not require directories inside the checkout, home or snapshot.
[ -z "$(find "$run/work" "$run/home" "$run/agents" -mindepth 1 -print)" ]
[ "$(readlink "$run/layers/harness.raw")" = "$AGENT_LAYERS/harness.raw" ]
[ "$(readlink "$run/layers/project.raw")" = "$AGENT_LAYERS/example.raw" ]
[ "$(readlink "$run/layers/project-etc.raw")" = "$AGENT_LAYERS/example-etc.raw" ]
[ ! -e "$run/layers/harness-etc.raw" ]
[ "$(readlink "$run/review/work")" = ../work ]
grep -qxF 'AGENT_MODEL="a \"model\""' "$run/run.env"
grep -qxF 'AGENT_SESSION_USD="5"' "$run/run.env"
[ "$(stat -c %a "$run/home")" = 775 ]
touch "$run/home/keep"
rm "$AGENT_LAYERS/example-etc.raw"
AGENT_PI_PROVIDER=custom-provider write_agent_run "$run" /repo/example pi model 2 false
grep -qxF 'AGENT_PI_PROVIDER="custom-provider"' "$run/run.env"
unset AGENT_PI_PROVIDER
write_agent_run "$run" /repo/example pi model 2 false
grep -qxF 'AGENT_PI_PROVIDER="openai"' "$run/run.env"
fails env AGENT_PI_PROVIDER="bad
provider" sh -c '. "$1/lib/agent-runs.sh"; . "$1/lib/agent-systemd.sh"; write_agent_run "$2" /repo/example pi model 2 false' sh "$tool" "$run"
[ -f "$run/home/keep" ]
[ "$(readlink "$run/pi/auth.json")" = /srv/pi-login/auth.json ]
[ ! -L "$run/review/work" ]
[ ! -L "$run/layers/project-etc.raw" ]
if grep -q AGENT_SESSION_USD "$run/run.env"; then exit 1; fi

# Legacy mount declarations are data only: never sourced, and warned once.
mkdir -p "$run/work/.sandbox"
printf '%s\n' "touch '$tmp/volumes-executed'" >"$run/work/.sandbox/volumes"
write_agent_run "$run" /repo/example pi model 2 false 2>"$tmp/warning"
[ "$(wc -l <"$tmp/warning")" -eq 1 ]
grep -qxF 'agent-sandbox > .sandbox/volumes is no longer read; .sandbox/setup points tools at /srv/cache' "$tmp/warning"
[ ! -e "$tmp/volumes-executed" ]
rm "$run/work/.sandbox/volumes"

# A PATH stub observes exact commands and simulates state/outcome.
export SYSTEMCTL_LOG="$tmp/commands" SYSTEMCTL_STATE="$tmp/state"
echo inactive >"$SYSTEMCTL_STATE"
printf '%s\n' '#!/bin/sh' \
    'echo "$*" >>"$SYSTEMCTL_LOG"' \
    'case "$*" in' \
    '  *"-p ActiveState --value") cat "$SYSTEMCTL_STATE" ;;' \
    '  *"-p Result"*) printf "Result=success\nExecMainCode=1\nExecMainStatus=0\n" ;;' \
    '  "--no-ask-password start "*) [ "${TEST_START_FAIL:-0}" = 0 ] || exit 1; echo active >"$SYSTEMCTL_STATE" ;;' \
    '  "--no-ask-password stop "*) echo inactive >"$SYSTEMCTL_STATE" ;;' \
    '  *) exit 1 ;;' \
    'esac' >"$tmp/bin/systemctl"
chmod +x "$tmp/bin/systemctl"
export PATH="$tmp/bin:$PATH"
fails agent_unit_active ws
grep -qxF 'show agent@ws.service -p ActiveState --value' "$SYSTEMCTL_LOG"
[ "$(agent_unit_props ws | wc -l)" = 3 ]
echo activating >"$SYSTEMCTL_STATE"
agent_unit_active ws
: >"$SYSTEMCTL_STATE"
agent_unit_active ws

# Real launchers with fake units: readers serialize too; a writer clears review.
mkdir -p "$run/sessions" "$run/prompts" "$run/transcripts"
cp -R "$tool/agents/." "$run/agents/"
# A session can replace the snapshot and run.env with shell payloads. The
# host must read defaults from its install and never execute either payload.
printf '%s\n' "touch '$tmp/models-executed'" 'exit 99' >"$run/agents/models.env"
printf '%s\n' "touch '$tmp/env-executed'" 'exit 99' >"$run/run.env"
# Holding the old run-directory lock must not block run, stop or reconcile.
exec 7>"$run/.lock"
flock 7
# Record which files each host command actually locks.
export FLOCK_REAL="$(command -v flock)" FLOCK_LOG="$tmp/locks"
printf '%s\n' '#!/bin/sh' \
    'case "$1" in *[!0-9]*) ;; *) readlink "/proc/$$/fd/$1" >>"$FLOCK_LOG" ;; esac' \
    'exec "$FLOCK_REAL" "$@"' >"$tmp/bin/flock"
chmod +x "$tmp/bin/flock"
git init -q "$run/work"
git -C "$run/work" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
# agent-layer is stubbed in a copy of the tool: it logs slot, name and recipe contents.
real=$tool tool=$tmp/tool
mkdir -p "$tool" && cp -R "$real/bin" "$real/lib" "$real/agents" "$tool/" && mkdir -p "$tool/layers"
printf '%s\n' '#!/bin/sh' 'echo "$1 $2 $3 $(cat "$3/mkosi.conf" 2>/dev/null)" >>"$LAYER_LOG"' \
    'printf "{\"name\":\"%s\"}\n" "$2" >"$AGENT_LAYERS/$2.build.json"' >"$tool/bin/agent-layer"
chmod +x "$tool/bin/agent-layer"
export LAYER_LOG="$tmp/layer-log"
# The real repository commits a project recipe; the clone's copy differs and must be ignored.
repo="$tmp/example"
git init -q "$repo"
mkdir -p "$repo/.sandbox/layer"
echo committed >"$repo/.sandbox/layer/mkosi.conf"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@t commit -q -m base
mkdir -p "$run/work/.sandbox/layer"
echo tampered >"$run/work/.sandbox/layer/mkosi.conf"
jq -n --arg repo "$repo" --arg base "$(git -C "$repo" rev-parse HEAD)" '{state:"ready", repo:$repo, base:$base}' >"$run/manifest.json"
echo inactive >"$SYSTEMCTL_STATE"
[ "$("$tool/bin/agent-run" --in ws --harness claude --prompt review --read-only)" = ws/1 ]
[ -L "$run/review/work" ]
[ "$(sed -n 1p "$LAYER_LOG")" = "harness harness $tool/layers/harness " ]
sed -n 2p "$LAYER_LOG" | grep -q '^project example /.*/\.sandbox/layer committed$'
jq -e '.layers == {harness: {name: "harness"}, project: {name: "example"}}' "$run/sessions/1.json" >/dev/null
[ ! -e "$tmp/models-executed" ] && [ ! -e "$tmp/env-executed" ]
. "$tool/agents/models.env"
[ "$AGENT_PI_PROVIDER" = openai ]
jq -e --arg model "$AGENT_CLAUDE_MODEL" '.model == $model' "$run/sessions/1.json" >/dev/null
fails "$tool/bin/agent-run" --in ws --prompt review --read-only
[ "$(find "$run/sessions" -name '*.json' | wc -l)" -eq 1 ]
"$tool/bin/agent-stop" ws/1
"$tool/bin/agent-result" ws/1 >"$tmp/result" && exit 1
jq -e '.state == "stopped"' "$tmp/result" >/dev/null
[ "$(AGENT_PI_PROVIDER=launch-provider AGENT_PI_MODEL=launch-model "$tool/bin/agent-run" --in ws --harness pi --prompt work)" = ws/2 ]
grep -qxF 'AGENT_PI_PROVIDER="launch-provider"' "$run/run.env"
grep -qxF 'AGENT_MODEL="launch-model"' "$run/run.env"
[ ! -L "$run/review/work" ]
# An old session's result or stop must never wait for / stop the newer session.
"$tool/bin/agent-result" ws/1 --wait >"$tmp/result" && exit 1
fails "$tool/bin/agent-stop" ws/1
[ "$(cat "$SYSTEMCTL_STATE")" = active ]
grep -qxF -- '--no-ask-password start agent@ws.service' "$SYSTEMCTL_LOG"
grep -qxF -- '--no-ask-password stop agent@ws.service' "$SYSTEMCTL_LOG"
echo inactive >"$SYSTEMCTL_STATE"
"$tool/bin/agent-result" ws/2 >"$tmp/result"
jq -e '.state == "finished"' "$tmp/result" >/dev/null
export TEST_START_FAIL=1
fails "$tool/bin/agent-run" --in ws --prompt denied
jq -e '.state == "failed" and .outcome == "failed:start"' "$run/sessions/3.json" >/dev/null
unset TEST_START_FAIL
# run, stop, and reconcile all used the same host-only file.
[ "$(sort -u "$FLOCK_LOG")" = "$XDG_RUNTIME_DIR/agent-sandbox/ws.lock" ]
[ "$(wc -l <"$FLOCK_LOG")" -ge 6 ]
flock -u 7

[ "$(classify_agent_outcome oom-kill 2 9 0)" = failed:oom ]
[ "$(classify_agent_outcome oom-kill 2 9 1)" = failed:oom ]
[ "$(classify_agent_outcome timeout 2 9 0)" = failed:timeout ]
[ "$(classify_agent_outcome timeout 2 9 1)" = stopped:timeout ]
[ "$(classify_agent_outcome success 1 0 0)" = finished ]
[ "$(classify_agent_outcome success 0 0 0)" = finished ]
[ "$(classify_agent_outcome signal 2 15 0)" = failed:signal:15 ]
[ "$(classify_agent_outcome signal 2 15 1)" = stopped ]
[ "$(classify_agent_outcome exit-code 1 1 0)" = failed:exit:1 ]
[ "$(classify_agent_outcome exit-code 1 1 1)" = failed:exit:1 ]
[ "$(classify_agent_outcome '' '' '' 0)" = failed:unit-state-unavailable ]
[ "$(classify_agent_outcome '' '' '' 1)" = failed:unit-state-unavailable ]
unit_state_running active
unit_state_running activating
unit_state_running deactivating
unit_state_running ''
fails unit_state_running inactive
fails unit_state_running failed
echo 'systemd tests passed'

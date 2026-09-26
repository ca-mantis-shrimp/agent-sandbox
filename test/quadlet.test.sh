#!/bin/sh
#
# Tests scripts/lib/agent-quadlet.sh's pure functions: unit rendering and the
# systemd-state-to-outcome mapping. No podman and no systemd --user session
# needed (neither is available inside the agent sandbox); each assertion is
# a check that aborts the script under set -e, so getting to the final line
# is the pass.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$script_dir/lib/agent-quadlet.sh"

# --- quadlet_dir / quadlet_unit -------------------------------------------

[ "$(quadlet_unit 20260926-000000)" = "agent-20260926-000000" ]

unset XDG_RUNTIME_DIR 2>/dev/null || true
[ "$(quadlet_dir)" = "/run/user/$(id -u)/containers/systemd" ]
XDG_RUNTIME_DIR=/tmp/xdg-test
export XDG_RUNTIME_DIR
[ "$(quadlet_dir)" = "/tmp/xdg-test/containers/systemd" ]

# --- render_agent_unit -----------------------------------------------------

unit=$(render_agent_unit 20260926-000000 clearhead-agent "/agents/loop sandbox-quadlet-lifecycle" \
    "Volume=/run/it:/job
Volume=/run/it/agents:/agents:ro" \
    "Environment=AGENT_HARNESS=claude" \
    "Secret=claude_token,type=env,target=CLAUDE_CODE_OAUTH_TOKEN" \
    800 21600 60)

assert_line() { # <expected exact line>
    printf '%s\n' "$unit" | grep -qxF "$1" || {
        echo "agent-quadlet.test: missing line: $1" >&2
        printf '%s\n' "$unit" >&2
        exit 1
    }
}

assert_line "Image=clearhead-agent"
assert_line "Pull=never"
assert_line "ContainerName=agent-20260926-000000"
assert_line "UserNS=keep-id"
assert_line "Volume=/run/it:/job"
assert_line "Volume=/run/it/agents:/agents:ro"
assert_line "Environment=AGENT_HARNESS=claude"
assert_line "Secret=claude_token,type=env,target=CLAUDE_CODE_OAUTH_TOKEN"
assert_line "Exec=/agents/loop sandbox-quadlet-lifecycle"
assert_line "Restart=no"
assert_line "MemoryMax=16G"
assert_line "MemorySwapMax=0"
assert_line "CPUQuota=800%"
assert_line "TasksMax=4096"
assert_line "RuntimeMaxSec=21600"
assert_line "TimeoutStopSec=60"
assert_line "OOMPolicy=kill"

# A run with no secret (pi) and no extra environment omits both lines, rather
# than rendering "Secret=" or "Environment=" empty.
bare=$(render_agent_unit 20260926-000001 clearhead-agent "/agents/loop" \
    "Volume=/run/it:/job" "" "" 800 21600 60)
printf '%s\n' "$bare" | grep -q '^Secret=' && { echo "agent-quadlet.test: unexpected Secret= line" >&2; exit 1; }
printf '%s\n' "$bare" | grep -q '^Environment=' && { echo "agent-quadlet.test: unexpected Environment= line" >&2; exit 1; }
true

# --- classify_agent_outcome -------------------------------------------------

# OOM is authoritative even if a stop was also requested.
[ "$(classify_agent_outcome oom-kill 2 9 0)" = "failed:oom" ]
[ "$(classify_agent_outcome oom-kill 2 9 1)" = "failed:oom" ]

# RuntimeMaxSec really reports Result=timeout on this host; start --wait
# duration includes startup and must not determine the outcome.
[ "$(classify_agent_outcome timeout 2 9 0)" = "failed:timeout" ]
[ "$(classify_agent_outcome timeout 2 9 1)" = "stopped:timeout" ]

# systemctl show uses numeric wait(2) codes; a short successful unit may
# already have cleared ExecMainCode to 0 by the time --wait returns.
[ "$(classify_agent_outcome success 1 0 0)" = "finished" ]
[ "$(classify_agent_outcome success 0 0 0)" = "finished" ]
[ "$(classify_agent_outcome signal 2 15 0)" = "failed:signal:15" ]
[ "$(classify_agent_outcome signal 2 15 1)" = "stopped" ]
[ "$(classify_agent_outcome exit-code 1 1 0)" = "failed:exit:1" ]
[ "$(classify_agent_outcome exit-code 1 1 1)" = "failed:exit:1" ]
[ "$(classify_agent_outcome '' '' '' 0)" = "failed:unit-state-unavailable" ]
[ "$(classify_agent_outcome '' '' '' 1)" = "failed:unit-state-unavailable" ]

printf 'agent-quadlet tests passed\n'

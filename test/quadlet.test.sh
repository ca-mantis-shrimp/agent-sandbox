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

# OOM wins even if the run also happens to be past its deadline.
[ "$(classify_agent_outcome oom-kill exited 0 99999 100 0)" = "failed:oom" ]

# A deadline hit is judged by elapsed wall time, not by Result: the process
# can still report Result=success (it exited cleanly on SIGTERM) even though
# systemd only sent that SIGTERM because RuntimeMaxSec expired.
[ "$(classify_agent_outcome success exited 0 21600 21600 0)" = "failed:timeout" ]
[ "$(classify_agent_outcome success exited 0 21601 21600 0)" = "failed:timeout" ]
[ "$(classify_agent_outcome success exited 0 21599 21600 0)" = "finished" ]

# scripts/agent-stop's marker overrides an otherwise-ambiguous signal/exit
# result, but never overrides oom or a deadline hit.
[ "$(classify_agent_outcome signal killed 15 10 21600 1)" = "stopped" ]
[ "$(classify_agent_outcome oom-kill killed 9 10 21600 1)" = "failed:oom" ]

[ "$(classify_agent_outcome success exited 0 10 21600 0)" = "finished" ]
[ "$(classify_agent_outcome signal killed 15 10 21600 0)" = "failed:signal:15" ]
[ "$(classify_agent_outcome exit-code exited 1 10 21600 0)" = "failed:exit:1" ]

printf 'agent-quadlet tests passed\n'

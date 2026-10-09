# Static system-manager sessions: one unit per workspace, data in its run directory.
agent_unit() { # <workspace>
    case "$1" in
        ''|*[!A-Za-z0-9_-]*) echo "agent-sandbox > invalid workspace: $1" >&2; return 1 ;;
    esac
    printf 'agent@%s.service\n' "$1"
}

unit_state_running() { # <ActiveState>
    case "$1" in inactive | failed) return 1 ;; *) return 0 ;; esac
}

agent_unit_active() { # <workspace>; silence during manager re-exec is not a stop
    unit_state_running "$(systemctl show "$(agent_unit "$1")" -p ActiveState --value 2>/dev/null)"
}

agent_unit_props() { # <workspace>
    systemctl show "$(agent_unit "$1")" -p Result -p ExecMainCode -p ExecMainStatus
}

# Write data for the installed unit. Needs agent-runs.sh; run/work and agents
# already exist. Do not build images here. Keep home and repository cache.
write_agent_run() ( # <run-dir> <repository> <harness> <model> <n> <read-only>
    set -eu
    umask 002
    run=$1 repo_name=$(basename "$2")
    : "${AGENT_BASE:?AGENT_BASE must name the host base tree}"
    : "${AGENT_LAYERS:?AGENT_LAYERS must name the host image directory}"
    [ -d "$AGENT_BASE" ] || { echo "agent-sandbox > missing base tree: $AGENT_BASE" >&2; exit 1; }
    for image in harness "$repo_name"; do
        [ -f "$AGENT_LAYERS/$image.raw" ] || {
            echo "agent-sandbox > missing layer: $AGENT_LAYERS/$image.raw" >&2; exit 1;
        }
    done
    mkdir -p "$run/layers" "$run/home" "$(runs_dir)/.cache/$repo_name"
    ln -sfn "$AGENT_BASE" "$run/root"
    ln -sfn "$(runs_dir)/.cache/$repo_name" "$run/cache"
    for slot in harness harness-etc project project-etc; do
        case "$slot" in project*) image="$repo_name${slot#project}" ;; *) image=$slot ;; esac
        rm -f "$run/layers/$slot.raw"
        [ ! -f "$AGENT_LAYERS/$image.raw" ] || ln -s "$AGENT_LAYERS/$image.raw" "$run/layers/$slot.raw"
    done
    mkdir -p "$run/review"
    rm -f "$run/review/work"
    [ "$6" != true ] || ln -s ../work "$run/review/work"
    # EnvironmentFile syntax, not shell syntax: quote and escape values.
    env_value() {
        printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
    }
    for value in "$3" "$4" "$5" "${AGENT_SESSION_USD:-}"; do
        case "$value" in *'
'*|*''*) echo 'agent-sandbox > newline in run environment' >&2; exit 1 ;; esac
    done
    {
        printf 'AGENT_HARNESS="%s"\n' "$(env_value "$3")"
        printf 'AGENT_MODEL="%s"\n' "$(env_value "$4")"
        printf 'AGENT_SESSION="%s"\n' "$(env_value "$5")"
        [ -z "${AGENT_SESSION_USD:-}" ] || printf 'AGENT_SESSION_USD="%s"\n' "$(env_value "$AGENT_SESSION_USD")"
        [ "$3" != gate ] || printf 'AGENT_LAND_GATE="%s"\n' "$(env_value "${AGENT_LAND_GATE:-.sandbox/gate}")"
    } >"$run/run.env.tmp"
    mv "$run/run.env.tmp" "$run/run.env"
)

classify_agent_outcome() { # <result> <exec-main-code> <exec-main-status> <stop-requested 0|1>
    result=$1 code=$2 status=$3 stop_requested=$4
    if [ -z "$result" ] || [ -z "$code" ] || [ -z "$status" ]; then
        echo "failed:unit-state-unavailable"; return
    fi
    if [ "$result" = "oom-kill" ]; then echo "failed:oom"; return; fi
    if [ "$stop_requested" -eq 1 ]; then
        case "$result" in
            timeout) echo "stopped:timeout" ;;
            exit-code) echo "failed:exit:$status" ;;
            *) echo "stopped" ;;
        esac
        return
    fi
    if [ "$result" = "timeout" ]; then echo "failed:timeout"; return; fi
    if [ "$result" = "success" ] && [ "$status" = "0" ] && { [ "$code" = "0" ] || [ "$code" = "1" ]; }; then
        echo "finished"; return
    fi
    if [ "$code" = "2" ] || [ "$code" = "3" ]; then echo "failed:signal:$status"; return; fi
    echo "failed:exit:$status"
}

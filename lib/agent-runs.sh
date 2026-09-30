# Shared by the scripts/agent-* tools: where workspaces live and how their
# records are read. Pure functions, except repo_commits (git) — so
# scripts/agent-runs.test.sh can source this and check it on its own.
#
# Three separate things, combined by whoever calls the tools:
#
#   workspace  $AGENT_RUNS/<id>/: a clone on branch agent/<id> (work/), the
#              harness snapshot (agents/) and manifest.json, the workspace's
#              own facts. It lasts until it is landed or discarded.
#   agent      a harness and a model, chosen per session.
#   session    one agent working on one prompt in one workspace: its own
#              systemd unit, and its own record, sessions/<n>.json.
#
# A session's record is written by whoever knows the fact: the host when it
# starts and when it finalizes the session, the session itself for its result.
# One file per session means sessions in a workspace never contend for a file.

runs_dir() {
    printf '%s\n' "${AGENT_RUNS:-$HOME/agent-runs}"
}

# A reference is <workspace> or <workspace>/<n>.
ref_workspace() { # <ref>
    printf '%s\n' "${1%%/*}"
}

ref_session() { # <ref> -> n, or empty when the ref names the whole workspace
    case "$1" in
        */*) printf '%s\n' "${1#*/}" ;;
        *) printf '\n' ;;
    esac
}

# The id a session's Quadlet unit is named by (see quadlet_unit).
session_unit_id() { # <workspace> <n>
    printf '%s-%s\n' "$1" "$2"
}

# The numbers of the sessions whose record says they are running.
running_sessions() { # <workspace-dir>
    for f in "$1"/sessions/*.json; do
        [ -f "$f" ] && jq -r 'select(.state == "running") | .n' "$f"
    done
    return 0
}

# The whole workspace as one JSON document: the manifest, its sessions in
# order, and a state derived from them — running while any session runs,
# otherwise the last session's state, otherwise the manifest's own (preparing,
# ready or failed). Manifests from before sessions had their own records carry
# their sessions and state inline; those pass through unchanged.
workspace_json() { # <workspace-dir>
    dir=$1
    set -- "$dir/manifest.json"
    for f in "$dir"/sessions/*.json; do
        [ -f "$f" ] && set -- "$@" "$f"
    done
    jq -s '.[0] as $m
        | (($m.sessions // []) + (.[1:] | sort_by(.n))) as $sessions
        | [$sessions[] | .state // empty] as $states
        | $m + {sessions: $sessions,
                state: (if ($states | any(. == "running")) then "running"
                        elif ($states | length) > 0 then $states[-1]
                        else $m.state end)}' "$@"
}

# Each repo's commits since <from-ref>, as {"<path>": [sha, ...]}, keyed by the
# repo's path in the clone ("." is the repo itself); repos with none are left
# out, and so is a repo that lacks the ref.
repo_commits() { # <work-dir> <from-ref>
    (
        cd "$1"
        {
            echo .
            git submodule --quiet foreach --recursive 'echo "$displaypath"'
        } | while read -r repo; do
            git -C "$repo" log --format=%H "$2..HEAD" 2>/dev/null |
                jq -R . | jq -s --arg repo "$repo" 'select(length > 0) | {($repo): .}'
        done | jq -s 'add // {}'
    )
}

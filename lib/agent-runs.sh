# Shared by the agent-* tools: where workspaces live and how their
# records are read. repo_commits and clone_local use git; workspace_json and
# running_sessions read records. session_json and human_verdict_reminder need
# the caller's $tool, the sandbox's own directory (each tool resolves it
# through any symlink to itself), to locate lib/agent-review.jq.
# Tests can source this without a systemd session.
#
# Three separate things, combined by whoever calls the tools:
#
#   workspace  $AGENT_RUNS/<id>/: a clone on branch agent/<id> (work/), the
#              harness snapshot (agents/) and manifest.json, the workspace's
#              own facts. It lasts until it is landed or discarded.
#   agent      a harness and a model, chosen per session.
#   session    one agent working on one prompt in one workspace: its own
#              workspace's systemd unit, and its own record, sessions/<n>.json.
#
# A session's record is written by whoever knows the fact: the host when it
# starts and when it finalizes the session, the session itself for its result.
# One file per session means sessions in a workspace never contend for a file.

session_json() { # <workspace-dir> <record-json>; read-only enrichment
    # Preserve the stored report, including human reconciliation. The workspace
    # argument is retained for callers; no transcript or clone is needed.
    printf '%s\n' "$2" | jq -L "$tool/lib" 'include "agent-review";
        if .read_only == true and .review == null then . + {review: review_report} else . end'
}

runs_dir() {
    printf '%s\n' "${AGENT_RUNS:-/var/lib/agent-runs}"
}

# The repository a workspace works on: the checkout agent-new cloned, as its
# manifest records. Workspaces from before the manifest recorded it, and
# candidates without a manifest, use the caller's own checkout.
workspace_repo() { # <workspace-dir>
    repo=$(jq -r '.repo // empty' "$1/manifest.json" 2>/dev/null) || repo=
    [ -n "$repo" ] || repo=$(git rev-parse --show-toplevel)
    printf '%s\n' "$repo"
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
    reviews=$(
        set --
        for f in "$dir"/reviews/*.json; do
            [ ! -f "$f" ] || set -- "$@" "$f"
        done
        if [ "$#" -eq 0 ]; then printf '[]\n'; else jq -s '.' "$@"; fi
    )
    workspace=$(jq -s --argjson reviews "$reviews" '.[0] as $m
        | (($m.sessions // []) + (.[1:] | sort_by(.n))) as $sessions
        | [$sessions[] | .state // empty] as $states
        | $m + {sessions: $sessions, reviews: (($m.reviews // []) + $reviews),
                state: (if ($states | any(. == "running")) then "running"
                        elif ($states | length) > 0 then $states[-1]
                        else $m.state end)}' "$@")
    printf '%s\n' "$workspace" | jq -c '.sessions[]?' | while IFS= read -r session; do
        session_json "$dir" "$session"
    done | jq -s --argjson workspace "$workspace" '$workspace + {sessions: .}'
}

# Advisory after a successful landing. Accept the already-loaded workspace;
# review reports may live in session files, external files or older inline records.
human_verdict_reminder() { # <workspace-id> <workspace-json>
    printf '%s\n' "$2" | jq -r -L "$tool/lib" --arg ws "$1" '
        include "agent-review";
        select(.human_verdict == null and ([workspace_reviews] | length > 0))
        | "agent-land > review has no human verdict; record the human’s call with agent-verdict \($ws)"' >&2
}

# Clone <repo> at its HEAD into <dest>, every submodule at its pin. Submodules
# come from <repo>'s own checkouts, not the remotes in .gitmodules, so unpushed
# local commits are available too.
clone_local() { # <repo> <dest>
    git clone -q "$1" "$2"
    (
        cd "$2"
        git submodule -q init
        git config --file .gitmodules --get-regexp '^submodule\..*\.path$' |
            while read -r key path; do
                name=${key#submodule.}
                name=${name%.path}
                git config "submodule.$name.url" "$1/$path"
            done
        # Git refuses local-path submodule clones by default; these are our own repos.
        git -c protocol.file.allow=always submodule -q update --recursive
    )
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

# Make the layers a run will mount current. Needs the caller's $tool. The harness
# layer comes from the installed tool, never the workspace. The project layer comes
# from <repository>'s object store at the workspace's base commit (manifest .base,
# else HEAD), read with archive only. TRUST: the recipe runs on the host with
# network, so it must be committed history the human already has, never the
# agent-writable clone: a worker that edits .sandbox/layer runs on the old layer.
ensure_layers() ( # <run-dir> <repository>
    "$tool/bin/agent-layer" harness harness "$tool/layers/harness" || return
    base=$(jq -r '.base // empty' "$1/manifest.json" 2>/dev/null) || base=
    [ -n "$base" ] || base=$(git -C "$2" rev-parse HEAD) || return
    git -C "$2" cat-file -e "$base:.sandbox/layer" 2>/dev/null || return 0
    recipe=$(mktemp -d) || return
    status=0
    { git -C "$2" archive "$base" .sandbox/layer | tar -x -C "$recipe" &&
        "$tool/bin/agent-layer" project "$(basename "$2")" "$recipe/.sandbox/layer"; } || status=$?
    rm -rf "$recipe"
    return $status
)

# Read-lock the layers a run uses (fds 5 and 6), so no agent-layer build replaces an
# image between layers_json and the unit's mounts; agent-layer holds the exclusive
# lock while it builds. Call after ensure_layers, release with release_layers once
# the unit has started. The project lock is taken whenever the run could mount
# <repo>.raw, record or not: write_agent_run mounts an existing image, and a first
# build can publish after any check. Descriptors across bin/: 9 is the workspace
# lock (agent-run, agent-land, agent-stop, agent-reconcile) and agent-layer's build
# lock, 8 is agent-land's gate workspace lock; 5 and 6 belong to these two functions.
hold_layers() { # <repository>
    mkdir -p "$AGENT_LAYERS/.build" || return
    exec 5>>"$AGENT_LAYERS/.build/harness.lock" && flock -s 5 || return
    exec 6>>"$AGENT_LAYERS/.build/$(basename "$1").lock" && flock -s 6
}
release_layers() { exec 5>&- 6>&-; }

# The build records the run's images came from: {"harness": ..., "project": ... or null}.
layers_json() { # <repository>
    jq -n --argjson harness "$(cat "$AGENT_LAYERS/harness.build.json" 2>/dev/null || echo null)" \
        --argjson project "$(cat "$AGENT_LAYERS/$(basename "$1").build.json" 2>/dev/null || echo null)" \
        '{harness: $harness, project: $project}'
}

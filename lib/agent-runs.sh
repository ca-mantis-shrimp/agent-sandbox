# Shared by the agent-* tools: where workspaces live and how their
# records are read. clone_local uses git on fresh clones; workspace_json and
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
# manifest records. A missing repository is an error, never the caller's checkout.
workspace_repo() { # <workspace-dir>
    repo=$(jq -er '.repo | select(type == "string" and length > 0)' "$1/manifest.json" 2>/dev/null) || {
        echo "workspace manifest lacks .repo: $1/manifest.json" >&2
        return 1
    }
    printf '%s\n' "$repo"
}

# Print workspaces holding <repository>. Inspect host paths and unit state only,
# never run Git in a workspace clone. Needs agent-systemd.sh. A stale running
# record does not hold a repo after its unit stops; manager silence is not a stop.
held_workspaces() ( # <repository>
    held_repo=$(git -C "$1" rev-parse --show-toplevel) || exit 2
    held_repo=$(CDPATH= cd -- "$held_repo" && pwd -P) || exit 2
    # 3 is the sole positive not-held answer; ordinary shell failures use 1.
    held=3
    held_runs=$(runs_dir) || exit 2
    if [ -e "$held_runs" ]; then
        [ -d "$held_runs" ] && [ -r "$held_runs" ] && [ -x "$held_runs" ] || exit 2
    fi
    for held_dir in "$held_runs"/*/; do
        [ -d "$held_dir" ] || continue
        [ -r "$held_dir" ] && [ -x "$held_dir" ] || exit 2
        [ -f "$held_dir/manifest.json" ] || continue
        origin=$(workspace_repo "$held_dir") || exit 2
        case "$origin" in /*) ;; *) echo 'agent-sandbox > manifest repo must be absolute' >&2; exit 2 ;; esac
        origin=$(CDPATH= cd -- "$origin" 2>/dev/null && pwd -P) || exit 2
        [ "$origin" = "$held_repo" ] || continue
        live_sessions=$(running_sessions "$held_dir") || exit 2
        [ -n "$live_sessions" ] || continue
        held_id=$(basename "$held_dir")
        held_state=$(agent_unit_state "$held_id") || exit 2
        if unit_state_running "$held_state"; then
            printf '%s\t%s\n' "$held_id" "$held_state"
            held=0
        fi
    done
    exit "$held"
)

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
    if [ -e "$1/sessions" ]; then
        [ -d "$1/sessions" ] && [ -r "$1/sessions" ] && [ -x "$1/sessions" ] || return 1
    fi
    for f in "$1"/sessions/*.json; do
        if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
        [ -f "$f" ] || return 1
        jq -sr 'if length != 1 then error("expected one session record")
            else .[0] | if type != "object" or (.state | type) != "string"
                then error("invalid session record")
                elif .state == "running" then .n else empty end end' "$f" || return 1
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
repo_paths() { # <real-repo>; never the workspace clone
    echo .
    git -C "$1" submodule --quiet foreach --recursive 'echo "$displaypath"'
}

latest_writer() { # <run-dir>
    set -- "$1"/sessions/*.json
    [ -e "$1" ] || return 0
    jq -s -er '[.[] | select(.read_only != true)]
        | if any(.[]; (.n | type != "number") or (.n <= 0) or (.n != (.n | floor)))
          then error("writer session n must be a positive integer")
          elif length == 0 then "" else max_by(.n).n end' "$@"
}

positive_session_number() {
    case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac
}

missing_export() { # <workspace> <n>; recovery advice shared by harvest and land
    printf 'session %s left no export (killed?); run a short writer session to export, e.g. agent-run --in %s --prompt "Commit nothing; end."\n' "$2" "$1" >&2
}

session_export() { # <run-dir> <n>; invalid or absent data is unknown (null)
    if ! positive_session_number "$2" || [ -L "$1/exports" ] ||
        [ -L "$1/exports/$2.json" ] || [ ! -f "$1/exports/$2.json" ]; then
        printf 'null\n'
        return
    fi
    real_repo=$(workspace_repo "$1") || return
    paths=$(repo_paths "$real_repo" | jq -R . | jq -s .)
    jq -se --argjson paths "$paths" '
        select(length == 1) | .[0]
        | def shas: type == "array" and all(.[]; type == "string" and test("^[0-9a-fA-F]{40}$"));
        select(type == "object" and (keys | sort) == ($paths | sort))
        | select(all(.[]; (.base | shas) and (.session | shas) and (.dirty | type == "boolean")))
    ' "$1/exports/$2.json" 2>/dev/null || printf 'null\n'
}

repo_commits() { # <run-dir> <from-ref>
    case "$2" in
        refs/agent/base) n=$(latest_writer "$1"); field=base ;;
        refs/agent/session-*) n=${2#refs/agent/session-}; field=session ;;
        *) printf 'null\n'; return ;;
    esac
    session_export "$1" "$n" | jq --arg field "$field" '
        if . == null then null else with_entries(.value = .value[$field] | select(.value | length > 0)) end'
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

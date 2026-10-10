# Agent sandbox

Run headless agents in disposable systemd sandboxes on your own hardware. Git is the output channel: agents commit without git credentials; the human harvests, reviews, lands and pushes. The runner knows prompts, not any project's task system.

## Workspaces, agents and sessions

- A **workspace** is a clone of the repository you run `agent-new` in, at its HEAD, with each repo on `agent/<workspace>` and `refs/agent/base` marking its starting point. It holds a harness snapshot and records, and lasts across sessions until landed or discarded.
- An **agent** is a harness plus a model, chosen per session (`--harness claude|pi`, `--model <id>`). Defaults are read from the installed tool checkout's `agents/models.env`, never the writable workspace snapshot; `AGENT_HARNESS`, `AGENT_CLAUDE_MODEL` and `AGENT_PI_MODEL` override them.
- A **session** is one agent on one prompt in one workspace: the system-manager unit `agent@<workspace>.service` and one `sessions/<n>.json` record. A worker, a reviewer from another vendor and a fixer can be successive sessions seeing the same commits.

One session at a time per workspace, including read-only sessions. Host commands share a lock at `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agent-sandbox/<workspace>.lock`, outside the agent-writable run directory. Work belonging together goes in one workspace, as sessions (`--in`). Parallel workspaces should cover separate areas: independent clones otherwise conflict or start without each other's unlanded work. The human's review time is the limit: at most two unreviewed workspaces. While a session works, the orchestrator works on something that does not overlap.

## Install

Installing is a declaration, not a script, kept wherever your environment is declared:

- this repository (`https://github.com/ca-mantis-shrimp/agent-sandbox`), checked out at a pinned revision or tag;
- its `bin/` on `PATH`, directly or through symlinks;
- the host integration shipped in `system/`, including `agent@.service`, the agent user, agents group, run-directory permissions and polkit authorization. Hosts install it through their own package/image declaration (the Arch package definition is `system/PKGBUILD`).

Updating is moving that pin. A workspace keeps the harness snapshot it started with. The commands find `lib/` and `agents/` beside the real `bin/`, through any symlink, and work on the Git repository of the directory you run `agent-new` in; every later command finds that repository from the workspace's manifest.

## Host setup and images

The host provides:

- Git, jq, `flock` (util-linux), and systemd **257 or newer**, with the static system unit installed.
- The calling process in the **agents** group. Polkit uses process groups: after adding membership, use a fresh login (or `newgrp agents`).
- `AGENT_BASE`, an absolute path to the base OS tree, and `AGENT_LAYERS`, an absolute path to a directory of prebuilt disk extension images. The runner does not build images.
- `harness.raw` (the harness tools) and `<repo>.raw` (the project's tools), where `<repo>` is the original repository directory's name. Only `harness.raw` is required to start; a repository whose needs the base and harness already meet has no `<repo>.raw`, and the run says so on stderr. Optional `harness-etc.raw` and `<repo>-etc.raw` carry each layer's `/etc` configuration as confext pairs. The sysext images carry `/usr` and `/opt`; extension-release names must match the run-directory slots, `harness`, `harness-etc`, `project`, `project-etc`.
- For Claude, `/etc/credstore/agent.claude_token`. The unit imports it and `agents/session` exports `CLAUDE_CODE_OAUTH_TOKEN` from the systemd credential directory when present.
- For pi, a host-managed shared login in `/var/lib/agent-runs/.pi`, mounted at `/srv/pi-login`. Each run's `pi/auth.json` links to `/srv/pi-login/auth.json`; the runner never copies the login. User-level settings and custom agents are snapshotted when present.

`agent-doctor` checks the required host runtime, process group, base and harness layer, and reports a missing or unreadable Claude credential. A project's layer is checked on launch, with the missing path in the error. `agent-layer` builds layers; the runner still only checks that they exist.

Workspaces are run directories at `$AGENT_RUNS/<workspace>/` (default **`/var/lib/agent-runs`**). `AGENT_RUNS` is overridable for tests; the installed unit hard-codes `/var/lib/agent-runs`, so a different path is not a live-host runtime option. Directories and records are created with umask 002 for the agents group; the host declares group ownership/inheritance.

| Path | Contents |
| --- | --- |
| `work/` | clone and submodules |
| `agents/` | harness snapshot, mounted read-only |
| `manifest.json` | workspace facts, including the repository it cloned |
| `sessions/`, `prompts/`, `transcripts/` | per-session records, prompts and transcripts |
| `exports/` | writer-session JSON (commit shas and dirty flags) and per-repo Git bundles |
| `run.env` | harness, model, session number, optional spend cap |
| `root` | link to `AGENT_BASE` |
| `layers/` | links to the required images and existing optional confext pairs |
| `home/` | writable home, retained across sessions |
| `cache` | link to `$AGENT_RUNS/.cache/<repo>`, shared by that repo's workspaces |
| `review/work` | link to `../work`, only for read-only sessions; removed for writers |
| `pi/` | pi's run directory (`PI_CODING_AGENT_DIR`): optional `settings.json` and `agents/`, plus the shared-login `auth.json` link |

Each workspace mounts at **`/srv/job/<workspace>`** (`AGENT_JOB`), with the checkout at **`/srv/job/<workspace>/work`**. The session entry point is `/srv/agents/session` and the shared repository cache is `/srv/cache`. The runner creates `work/`, `home/` and `agents/` before starting, but never creates mount-point directories inside them; mount targets exist in the run directory or sit on the unit's `/srv` and `/home` tmpfs. The distinct path prevents Cargo's shared target cache from reusing another workspace's local-crate build. The agent runs as its own system user, with a read-only base tree, restricted network access and host-managed resource limits. See the header of [`agent@.service`](system/usr/lib/systemd/system/agent@.service) for the authoritative run-directory contract.

The target repository's own startup lives in `.sandbox/`, all optional:

- `setup`: sourced before each session and the landing gate; exports tool paths and points tools directly at `/srv/cache` (for example, `CARGO_HOME=/srv/cache/cargo` and `CARGO_TARGET_DIR=/srv/cache/target`). Session output goes to `setup.log`; failure fails the session. `.sandbox/volumes` is not supported; the project chooses cache locations in `setup`, not mount declarations.
- `prompt.md`: standing prose prepended to every session prompt.
- `gate`: the repository's landing gate (`AGENT_LAND_GATE` can override it).

A driver that turns a project's tasks into sessions belongs to that project, beside its `.sandbox/`.

## Commands

Run these from the host, not inside an agent session.

| To | Command |
| --- | --- |
| create a workspace only | `agent-new` (prints its id) |
| start any task in a new workspace | `agent-run --prompt <file\|text>` |
| add a session | `agent-run --in <workspace> --prompt <file\|text> [--harness pi] [--model <id>] [--read-only] [--label <text>] [--wait]` |
| read JSON results | `agent-result <workspace>[/<n>] [--wait]` |
| fix a review | `agent-fix <workspace>[/<n>] [--review <file> --reviewer <name>] [--harness claude\|pi] [--model <id>] [--note <file\|text>] [--nits] [--wait]` |
| record the human's judgment | `agent-verdict <workspace> [--agree] [--overrule <text>]... [--missed <text>]... [--note <text>]` |
| fetch commits without merging | `agent-harvest <workspace>` |
| gate and merge harvested work | `agent-land <workspace>` |
| stop sessions gracefully | `agent-stop <workspace>[/<n>]` |
| see workspaces or recent tool calls | `agent-status [<workspace> [n]]` |
| check this host's setup | `agent-doctor` |

`agent-run` prints `<workspace>/<n>` and normally returns once the unit is up. A prompt names a file if it exists, otherwise it is literal text. `agent-result --wait` blocks until the named session (or all sessions in the workspace) stops and finalizes records. Its exit codes are 0 for finished/ready, 1 for failed/stopped, 3 for running/preparing. A normal harness exit is not proof that the task succeeded: read the closing message.

Host commands never run Git in agent-writable clones. Writers export plain data inside the sandbox; harvest fetches bundles into real repositories. Missing or invalid commit exports are reported as JSON `null` (unknown), and harvest/land refuse them. Read-only and gate sessions do not export. Harvest and land require the latest writer's valid export, never an older writer's: SIGKILL or OOM can prevent the EXIT trap from exporting. If they report `session <n> left no export (killed?)`, run a short writer to export the retained commits, for example `agent-run --in <ws> --prompt "Commit nothing; end."`, then harvest again. Bundles are named `root.bundle` for the root and `sm-<URI-encoded-path>.bundle` for submodules.

`AGENT_SESSION_USD` defaults to $3 per session. The static unit defaults to a six-hour deadline, 60-second stop grace, and per-session limits of 8 CPUs and 16G memory with no swap. CPU and memory limits are the unit's defaults; `AGENT_CPUS` and `AGENT_MEMORY` are gone. Limits belong to the host: use unit overrides for defaults, or override one run with `systemctl set-property agent@<workspace>.service CPUQuota=400% MemoryMax=8G`, not runner-generated units. Follow a session with `journalctl -u agent@<workspace>.service -f`. Starts and stops use the system manager with `--no-ask-password`, never the user manager.

## Review, fix and land

1. Start work with `agent-run --prompt`, or with the project's own driver.
2. Read the result with `agent-result <workspace> --wait`.
3. Start a read-only review in the same workspace with a **different vendor**, for example:

   ```sh
   agent-run --in <workspace> --harness pi --read-only \
     --prompt "Run kind: review. Target: this workspace's branch."
   ```

4. Read the review, then use `agent-fix <workspace>[/<n>]` for blocking and should-fix findings. Without a session number it selects the latest read-only session with a parsed review. `--nits` includes nits; `--note` supplies human decisions. An external review can instead be supplied with `--review <file> --reviewer <name>` (not with a session number); it is retained in `reviews/`.
5. Check fixes. A fix does not reconcile a finding; the human records reconciliation after checking it. Reviews advise landing, not gate it.
6. Run `agent-harvest <workspace>` when no session is running; it fetches branches in each repo and shows commits and closing messages without merging. Harvest again after further sessions.
7. Run `agent-land <workspace>`. It merges bottom-up into the candidate run directory `$AGENT_RUNS/land-<workspace>/work`, then starts `agent@land-<workspace>.service` with `AGENT_HARNESS=gate`. `agents/session` sources `.sandbox/setup`, runs the gate, and writes `gate.status` and `gate.log`. Landing requires both a successful unit outcome and gate status 0. No real branch advances until the gate passes. It prints unreconciled blocking findings for the human's decision.
8. Record the human's landing judgment with `agent-verdict`; then push separately.

The landing gate runs the branch's `.sandbox/setup` and gate in the same unit template as sessions, so it can read the Claude credential and pi's shared login. For our own work, the branch was written by agent sessions that already held both, so this adds no credential exposure. If gates ever run code from elsewhere, give them their own unit without the credential and the login.

A conflict leaves the candidate for resolution and a rerun. A red gate leaves the candidate and `gate.log`, with real branches unchanged. Once gated, the host never runs Git in that candidate again: reruns gate the retained tree and advance to tips saved before its first gate. To incorporate candidate edits or newly harvested work after gating, remove the candidate and rerun. If a real branch moved after the candidate was built, remove the candidate and rerun. Advancing several repos is not atomic: a partial failure reports which advanced, and a rerun skips them. Successful landing removes the workspace clone and candidate clone, retaining records, transcripts and the candidate's home/cache.

## Unattended runs

Sessions belong to the system manager and outlive the terminal that starts them. The project's driver must also be host-managed (a service or timer), with the sandbox's `bin/` on its declared PATH. Scheduling, login/session policy, credentials and keeping the machine awake belong to the host, not this runner. Spending stays bounded by `AGENT_SESSION_USD` per session and by the driver's own cap; results wait in the records for `agent-result` and `agent-harvest`.

## Layers

`agent-layer <slot> <name> <recipe-dir> [--force]` builds one layer (a sysext and a confext) from an mkosi recipe directory (see `layers/harness`) on `AGENT_BASE`, into `AGENT_LAYERS/<name>.raw` and `<name>-etc.raw`. Bases are pinned and layers float: it rebuilds only when the recipe's content hash changes, the base changes, or the last build is older than `AGENT_LAYER_MAX_AGE` seconds (default 604800). It writes the extension-release files from the base's os-release, so systemd accepts the layer only on that base.

Each build writes `<name>.build.json` last: recipe and base ids, build time, packages not in the base manifest, and the lines of `usr/share/agent-layer/versions` (`name version`, written by the recipe for anything fetched outside pacman). Failed builds leave the old images and record alone and keep `AGENT_LAYERS/.build/<name>` as evidence.

mkosi's and systemd-repart's output goes to `AGENT_LAYERS/.build/<name>.log` (overwritten each build, kept after failure too); the terminal shows only agent-layer's own lines. Staleness is decided again after taking the build lock, so two concurrent runs build once. Age is a soft trigger: when the only reason is "older than <n>d" and the rebuild fails, agent-layer keeps the old images, prints a `WARNING` naming the log and the build's date, and exits 0, so an offline machine keeps working. Every other reason still fails.

Trust rule: the recipe runs with network on the host, in a user namespace. Pass only a trusted, committed recipe.

`agent-run` and `agent-land` (before gating) make the run's layers current with `ensure_layers` (`lib/agent-runs.sh`): the `harness` layer from the installed tool's `layers/harness`, and a `project` layer named after the repository when the real repository has `.sandbox/layer` at the workspace's base commit (read with `git archive`, never from the workspace clone). A worker that edits `.sandbox/layer` therefore runs on the old layer; the new recipe takes effect after landing. Each `sessions/<n>.json`, and the `gate` entry in the manifest, records `layers`: `{"harness": <build record>, "project": <build record or null>}`, the contents of `AGENT_LAYERS/<name>.build.json` at the start.

## Tests

Run `sh test/<name>.test.sh`, or `.sandbox/gate` for all tests. Runtime and landing tests stub `systemctl` on PATH; they do not start host units or build images. Changes to `agents/` still need real Claude/pi and landing sessions on a configured host to prove image mounts, credentials, group permissions, isolation and lifecycle behavior.

## Gotchas

- Headless sessions end on their closing reply. Run all commands in the foreground and wait; nothing resumes the session later.
- Landing refuses unharvested commits: harvest after the last writer finishes.
- A systemd manager re-exec may briefly return no state; that silence is not treated as a stopped session.
- Headless `nvim`/`busted` can hang on inherited open stdin; append `< /dev/null`.
- Sourcing `lib/*.sh` into zsh breaks because `path` is zsh's PATH; use `sh -c`.

Current implementation state, open gaps and decisions belong in [the sandbox charter](.clearhead/charters/README.md), not this guide.

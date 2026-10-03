# Agent sandbox

Run headless agents in disposable, rootless Podman containers on your own hardware. Git is the output channel: agents commit without git credentials; the human harvests, reviews, lands and pushes. The runner knows prompts, not any project's task system, and works on any Git repository with a root `Containerfile`.

## Workspaces, agents and sessions

- A **workspace** is a clone of the repository you run `agent-new` in, at its HEAD, with each repo on `agent/<workspace>` and `refs/agent/base` marking its starting point. It holds a harness snapshot and records, and lasts across sessions until landed or discarded.
- An **agent** is a harness plus a model, chosen per session (`--harness claude|pi`, `--model <id>`). Defaults live in `agents/models.env`; `AGENT_HARNESS`, `AGENT_CLAUDE_MODEL` and `AGENT_PI_MODEL` override them.
- A **session** is one agent on one prompt in one workspace: one systemd user unit and one `sessions/<n>.json` record. A worker, a reviewer from another vendor and a fixer can be successive sessions seeing the same commits.

One writer at a time per workspace; a writer excludes readers. Read-only sessions may overlap. Work belonging together goes in one workspace, as sessions (`--in`). Parallel workspaces should cover separate areas: independent clones otherwise conflict or start without each other's unlanded work. The human's review time is the limit: at most two unreviewed workspaces. While a session works, the orchestrator works on something that does not overlap.

## Install

There is no install step. The sandbox runs from its own checkout, so installing it is a declaration, kept wherever your environment is declared (a shell profile, a dotfiles manager such as chezmoi, a Nix or distribution package):

- this repository, checked out at a pinned revision or tag;
- its `bin/` on `PATH`, directly or through symlinks.

Updating is moving that pin. A workspace keeps the harness snapshot it started with. The commands find `lib/` and `agents/` beside the real `bin/`, through any symlink, and work on the Git repository of the directory you run `agent-new` in; every later command finds that repository from the workspace's manifest.

## Host setup

The host provides, once:

- Git, jq, `flock` (util-linux), Podman (rootless, with subordinate IDs for your user in `/etc/subuid` and `/etc/subgid`) and a systemd user session.
- uid 1000 for the user running the sandbox: sessions run as uid 1000 under `--userns=keep-id`, so their commits stay yours.
- `loginctl enable-linger`, so sessions survive logging out.
- The `claude_token` Podman secret for Claude sessions: `claude setup-token`, then `podman secret create claude_token -` with the token on stdin.
- For pi sessions, the sandbox's own pi login in the `agent-pi` volume, never the host's `auth.json`: log in once with `podman run --rm -it --userns=keep-id -v agent-pi:/home/agent/.pi/agent localhost/<repo>-agent pi`, then `/login`. The host's `~/.pi/agent/settings.json` is reused when there is one.

`agent-doctor` checks them, one line each, and changes nothing. Images need nothing installed: `agent-new` builds them per repository.

The image is built in two layers. The target repository's root `Containerfile` comes first: built as root, on any base, it installs the tools that repository needs and must also provide `git`, `jq` and `npm`. The sandbox's `agents/Containerfile` goes over it, adding the harnesses (and their version pins) and the uid-1000 user sessions run as, whose home is `/home/agent`. Tools live in the image.

Workspaces live at `$AGENT_RUNS/<workspace>/` (default `~/agent-runs`):

| Path | Contents |
| --- | --- |
| `work/` | clone and submodules |
| `agents/` | harness snapshot, mounted read-only |
| `manifest.json` | workspace facts, including the repository it cloned |
| `sessions/`, `prompts/`, `transcripts/` | per-session records, prompts and transcripts |

Each workspace mounts at **`/job/<workspace>`**, with the working checkout at **`/job/<workspace>/work`**. The distinct path prevents Cargo's shared target cache from reusing another workspace's local-crate build. Later edits to the installed harness do not change a workspace's snapshot.

The target repository's own startup lives in `.sandbox/`, all optional:

- `setup`: sourced before each session and the landing gate; can export `PATH`. Session output goes to `setup.log`; failure fails the session.
- `prompt.md`: standing prose prepended to every session prompt.
- `gate`: the repository's landing gate (`AGENT_LAND_GATE` can override it).
- `volumes`: cache volumes for sessions and the gate, one `name:/container/path` per line, such as `cargo:/home/agent/.cargo/registry`. Only named volumes are allowed, since a branch writes this file and the next session mounts it; each becomes `agent-cache-<name>`, shared by every repository that declares the name. The repository's image creates the mount points, under `/home/agent` so the agent user owns them.

A driver that turns a project's tasks into sessions belongs to that project, beside its `.sandbox/`.

## Commands

Run these from the host, not inside an agent container.

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

Limits: `AGENT_SESSION_USD` defaults to $3 per session; `AGENT_RUN_DEADLINE_SEC` to 21600 seconds; `AGENT_STOP_GRACE_SEC` to 60 seconds. Units enforce resource limits per session, which are the host's to set: `AGENT_CPUS` (8) and `AGENT_MEMORY` (16G); the landing gate uses the same. Follow a unit with `journalctl --user -u agent-<workspace>-<n>.service -f`.

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
7. Run `agent-land <workspace>`. It merges bottom-up into a candidate clone and runs `.sandbox/setup` then `.sandbox/gate` in the candidate's image. No real branch advances until the gate passes. It prints unreconciled blocking findings for the human's decision.
8. Record the human's landing judgment with `agent-verdict`; then push separately.

A conflict leaves the candidate for resolution and a rerun. A red gate leaves the candidate and `gate.log`, with real branches unchanged. If a real branch moved after the candidate was built, remove the candidate and rerun. Advancing several repos is not atomic: a partial failure reports which advanced, and a rerun skips them. Successful landing removes the workspace clone and candidate, retaining records and transcripts.

## Tests

`test/*.test.sh` run with `sh`; each passes by reaching its last line. `land.test.sh` needs Podman and a base image (`AGENT_LAND_TEST_IMAGE`).

## Gotchas

- Headless sessions end on their closing reply. Run all commands in the foreground and wait; nothing resumes the session later.
- Landing refuses unharvested commits: harvest after the last writer finishes.
- A system upgrade re-executing the user systemd manager formerly ended `--wait` early; `agent_unit_active` handles that (fixed 2026-09-30).
- Headless `nvim`/`busted` can hang on inherited open stdin; append `< /dev/null`.
- Sourcing `lib/*.sh` into zsh breaks because `path` is zsh's PATH; use `sh -c`.

Current implementation state, open gaps and decisions belong in [the sandbox charter](../.clearhead/charters/agent-sandbox.md), not this guide.

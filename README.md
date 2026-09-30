# Agent sandbox

Run headless agents in disposable, rootless Podman containers on your own hardware. Git is the output channel: agents commit without git credentials; the human harvests, reviews, lands and pushes. The runner knows prompts, not ClearHead actions.

## Workspaces, agents and sessions

- A **workspace** is a clone at the source checkout's HEAD, with each repo on `agent/<workspace>` and `refs/agent/base` marking its starting point. It holds a harness snapshot and records, and lasts across sessions until landed or discarded.
- An **agent** is a harness plus a model, chosen per session (`--harness claude|pi`, `--model <id>`). Defaults live in `agents/models.env`; `AGENT_HARNESS`, `AGENT_CLAUDE_MODEL` and `AGENT_PI_MODEL` override them.
- A **session** is one agent on one prompt in one workspace: one systemd user unit and one `sessions/<n>.json` record. A worker, a reviewer from another vendor and a fixer can be successive sessions seeing the same commits.

One writer at a time per workspace; a writer excludes readers. Read-only sessions may overlap. Work belonging together goes in one workspace, as sessions (`--in`). Parallel workspaces should cover separate areas: independent clones otherwise conflict or start without each other's unlanded work. The human's review time is the limit: at most two unreviewed workspaces. While a session works, the orchestrator works on something that does not overlap.

## Host and repository setup

The host needs Git, jq, Podman and a systemd user session (`loginctl enable-linger` helps it survive logout). The image is built from the repository's root `Containerfile`; tools live in the image. Claude sessions use the `claude_token` Podman secret; pi uses the sandbox's own login in the `agent-pi` volume, not the host's `auth.json`. Currently `agent-new` also reads `~/.pi/agent/settings.json`, even for Claude workspaces.

Workspaces live at `$AGENT_RUNS/<workspace>/` (default `~/agent-runs`):

| Path | Contents |
| --- | --- |
| `work/` | clone and submodules |
| `agents/` | harness snapshot, mounted read-only |
| `manifest.json` | workspace facts |
| `sessions/`, `prompts/`, `transcripts/` | per-session records, prompts and transcripts |

Each workspace mounts at **`/job/<workspace>`**, with the working checkout at **`/job/<workspace>/work`**. The distinct path prevents Cargo's shared target cache from reusing another workspace's local-crate build. Later edits to the source harness do not change a workspace's snapshot.

Repository-specific startup lives in `.sandbox/`:

- `setup`: sourced before each session and the landing gate; can export `PATH`. Session output goes to `setup.log`; failure fails the session.
- `prompt.md`: standing prose prepended to every session prompt.
- `gate`: the repository's landing gate (`AGENT_LAND_GATE` can override it).
- `work-prompt.md`: the ClearHead driver's action prompt template.

The session setup and standing prompt are optional. In this platform, setup builds `clearhead` from the branch and the prompt points to [the sandbox runbook](../docs/overnight-runbook.md). The generic runner can work on a repo without `.clearhead/`.

## Commands

Run these from the host, not inside an agent container.

| To | Command |
| --- | --- |
| create a workspace only | `scripts/agent-new` (prints its id) |
| start any task in a new workspace | `scripts/agent-run --prompt <file\|text>` |
| add a session | `scripts/agent-run --in <workspace> --prompt <file\|text> [--harness pi] [--model <id>] [--read-only] [--label <text>] [--wait]` |
| read JSON results | `scripts/agent-result <workspace>[/<n>] [--wait]` |
| fix a review | `scripts/agent-fix <workspace>[/<n>] [--review <file> --reviewer <name>] [--harness claude\|pi] [--model <id>] [--note <file\|text>] [--nits] [--wait]` |
| record the human's judgment | `scripts/agent-verdict <workspace> [--agree] [--overrule <text>]... [--missed <text>]... [--note <text>]` |
| fetch commits without merging | `scripts/agent-harvest <workspace>` |
| gate and merge harvested work | `scripts/agent-land <workspace>` |
| stop sessions gracefully | `scripts/agent-stop <workspace>[/<n>]` |
| see workspaces or recent tool calls | `scripts/agent-status [<workspace> [n]]` |
| work ClearHead actions | `scripts/clearhead-work [<action>...]` |

`agent-run` prints `<workspace>/<n>` and normally returns once the unit is up. A prompt names a file if it exists, otherwise it is literal text. `agent-result --wait` blocks until the named session (or all sessions in the workspace) stops and finalizes records. Its exit codes are 0 for finished/ready, 1 for failed/stopped, 3 for running/preparing. A normal harness exit is not proof that the task succeeded: read the closing message and, for ClearHead work, the action's state.

`clearhead-work` creates one workspace and one session per action, so later actions build on earlier commits. Without arguments it rereads the unscheduled queue after each session; with arguments it works those actions in order. Name decided actions until the queue is curated. Pairings and outcomes (completed, blocked, unfinished) live in `clearhead-work.json`, not the generic runner's records.

Limits: `AGENT_SESSION_USD` defaults to $3 per session; `AGENT_RUN_DEADLINE_SEC` to 21600 seconds; `AGENT_STOP_GRACE_SEC` to 60 seconds. The ClearHead driver additionally uses `AGENT_MAX_ACTIONS` (10) and `AGENT_RUN_USD` ($15). Units enforce resource limits (8 CPUs and 16 GB per session); the NUC fits about two sessions at once and the shared build cache serializes compiles. Follow a unit with `journalctl --user -u agent-<workspace>-<n>.service -f`.

## Review, fix and land

For this platform, follow the run kinds and report contract in [the runbook](../docs/overnight-runbook.md).

1. Start work with `scripts/clearhead-work <action>`, or a generic task with `agent-run --prompt`.
2. Read the result with `agent-result <workspace> --wait`.
3. Start a read-only review in the same workspace with a **different vendor**, for example:

   ```sh
   scripts/agent-run --in <workspace> --harness pi --read-only \
     --prompt "Run kind: review. Target: this workspace's branch."
   ```

4. Read the review, then use `agent-fix <workspace>[/<n>]` for blocking and should-fix findings. Without a session number it selects the latest read-only session with a parsed review. `--nits` includes nits; `--note` supplies human decisions. An external review can instead be supplied with `--review <file> --reviewer <name>` (not with a session number); it is retained in `reviews/`.
5. Check fixes. A fix does not reconcile a finding; the human records reconciliation after checking it. Reviews advise landing, not gate it.
6. Run `agent-harvest <workspace>` when no session is running; it fetches branches in each repo and shows commits and closing messages without merging. Harvest again after further sessions.
7. Run `agent-land <workspace>`. It merges bottom-up into a candidate clone and runs `.sandbox/setup` then `.sandbox/gate` in the candidate's image. No real branch advances until the gate passes. It prints unreconciled blocking findings for the human's decision.
8. Record the human's landing judgment with `agent-verdict`; then push separately.

A conflict leaves the candidate for resolution and a rerun. A red gate leaves the candidate and `gate.log`, with real branches unchanged. If a real branch moved after the candidate was built, remove the candidate and rerun. Advancing several repos is not atomic: a partial failure reports which advanced, and a rerun skips them. Successful landing removes the workspace clone and candidate, retaining records and transcripts.

## Gotchas

- Headless sessions end on their closing reply. Run all commands in the foreground and wait; nothing resumes the session later.
- Landing refuses unharvested commits: harvest after the last writer finishes.
- Pushing platform also pushes submodule `main` branches.
- A system upgrade re-executing the user systemd manager formerly ended `--wait` early; `agent_unit_active` handles that (fixed 2026-09-30).
- Headless `nvim`/`busted` can hang on inherited open stdin; append `< /dev/null`.
- Sourcing `scripts/lib/*.sh` into zsh breaks because `path` is zsh's PATH; use `sh -c`.

Current implementation state, open gaps and decisions belong in [the sandbox charter](../.clearhead/charters/agent-sandbox.md), not this guide.

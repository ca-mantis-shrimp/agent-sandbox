# Agent sandbox

Run headless agents in disposable systemd sandboxes on your own hardware. Git is the output channel: agents commit without git credentials; the human harvests, reviews, lands and pushes. The runner knows prompts, not any project's task system.

## Workspaces, agents and sessions

- A **workspace** is a clone of the repository you run `agent-new` in, at its HEAD, with each repo on `agent/<workspace>` and `refs/agent/base` marking its starting point. It holds a harness snapshot and records, and lasts across sessions until landed or discarded.
- An **agent** is a harness plus a model, chosen per session (`--harness claude|pi`, `--model <id>`). Defaults are read from the installed tool checkout's `agents/models.env`, never the writable workspace snapshot; `AGENT_HARNESS`, `AGENT_CLAUDE_MODEL`, `AGENT_PI_MODEL` and `AGENT_PI_PROVIDER` override them. Pi's provider defaults to `openai` beside its model in that file; set `AGENT_PI_PROVIDER` in the launching environment to choose another provider.
- A **session** is one agent on one prompt in one workspace: the system-manager unit `agent@<workspace>.service` and one `sessions/<n>.json` record. A worker, a reviewer from another vendor and a fixer can be successive sessions seeing the same commits.

One session at a time per workspace, including read-only sessions. Host commands share a lock at `${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/agent-sandbox/<workspace>.lock`, outside the agent-writable run directory. Work belonging together goes in one workspace, as sessions (`--in`). Parallel workspaces should cover separate areas: independent clones otherwise conflict or start without each other's unlanded work. The human's review time is the limit: at most two unreviewed workspaces. While a session works, the orchestrator works on something that does not overlap.

## Install

Installing is a declaration, not a script, kept wherever your environment is declared:

- this repository (`https://github.com/ca-mantis-shrimp/agent-sandbox`), checked out at a pinned revision or tag;
- its `bin/` on `PATH`, directly or through symlinks;
- the host integration shipped in `system/`, including `agent@.service`, the agent user, agents group, run-directory permissions and polkit authorization. By default the host declares and merges an **agent-sandbox system extension**, not sandbox content in its OS image. Hosts that install packages can instead use the Arch package definition, `system/PKGBUILD`.

Updating is moving that pin. A workspace keeps the harness snapshot it started with. The commands find `lib/` and `agents/` beside the real `bin/`, through any symlink, and work on the Git repository of the directory you run `agent-new` in; every later command finds that repository from the workspace's manifest.

## Host setup and images

Build the host extension without root from the pinned tool checkout, then activate
it separately as root:

```sh
agent-host-build                       # default output: ./agent-sandbox.raw
agent-host-install ./agent-sandbox.raw # run as root (using the host's chosen tool)
```

`agent-host-build [<out.raw>]` archives **committed `system/` at HEAD**, ignoring
working-tree edits. The output basename must be `agent-sandbox.raw` to match its
extension-release name. Building needs `unshare` and `systemd-repart`; repart
definitions come from `AGENT_REPART_DEFINITIONS` when set, otherwise mkosi's
installed resources (the same lookup as `agent-layer`). The unsigned image carries
`ID=_any`, `EXTENSION_RELOAD_MANAGER=1`, and `AGENT_SANDBOX_COMMIT` and
`AGENT_SANDBOX_SYSTEM_TREE` provenance fields.
Only build and install a trusted revision: this extension configures host authority.

`agent-host-install` stages the image in `/var/lib/extensions/`, validates it with
`systemd-dissect --validate`, and atomically replaces `agent-sandbox.raw` only on
success. It runs `systemd-sysext refresh` (including manager reload), then applies
only the sandbox's sysusers and tmpfiles configs. It refuses any other
`agent-sandbox*` directory or `.raw` extension in `/etc/extensions`,
`/run/extensions` or `/var/lib/extensions`, naming it rather than deleting it. The host declares persistence/merging of this extension at boot
(for example, enabling `systemd-sysext.service`); the installer does not enable units.
On a pin move, build and install again. `agent-doctor` compares the merged
extension's `system/` tree id with the tool checkout's HEAD, so unrelated commits
do not report drift. There is no automatic rebuild or install trigger.

Alternatively, package-installing Arch hosts can use `system/PKGBUILD`; absence of
a merged extension is a doctor note, not a failure. Do not install both routes.

The host provides:

- Git, jq, `flock` and, for the tests, `script` (both util-linux), and systemd **257 or newer**, with the static system unit installed.
- The calling process in the **agents** group. Polkit uses process groups: after adding membership, use a fresh login (or `newgrp agents`).
- `AGENT_BASE`, an absolute path to the base OS tree, and `AGENT_LAYERS`, an absolute path to a directory of prebuilt disk extension images. The runner does not build images.
- `harness.raw` (the harness tools) and `<repo>.raw` (the project's tools), where `<repo>` is the original repository directory's name. Only `harness.raw` is required to start; a repository whose needs the base and harness already meet has no `<repo>.raw`, and the run says so on stderr. Optional `harness-etc.raw` and `<repo>-etc.raw` carry each layer's `/etc` configuration as confext pairs. The sysext images carry `/usr` and `/opt`; extension-release names must match the run-directory slots, `harness`, `harness-etc`, `project`, `project-etc`.
- For Claude, `/etc/credstore/agent.claude_token`, or `/etc/credstore.encrypted/agent.claude_token` sealed with `systemd-creds encrypt` (for example, to the TPM). The unit imports it and `agents/session` exports `CLAUDE_CODE_OAUTH_TOKEN` from the systemd credential directory when present.
- For pi, a host-managed shared login in `/var/lib/agent-runs/.pi`, mounted at `/srv/pi-login`. Each run's `pi/auth.json` links to `/srv/pi-login/auth.json`; the runner never copies the login. User-level settings and custom agents are snapshotted when present.

Create or renew the shared pi login **on the host** by running:

```sh
PI_CODING_AGENT_DIR=/var/lib/agent-runs/.pi pi
```

Then use `/login`. The browser's OAuth redirect to localhost reaches pi directly on the host. The provider name `/login` stores the token under must match `AGENT_PI_PROVIDER`; `agent-doctor` checks that provider's key in the shared `auth.json`. This is a separate sandbox login, never the host's own `~/.pi` login. The host declares `/var/lib/agent-runs/.pi` as `root:agents`, mode `2770`; after login or renewal, ensure `auth.json` belongs to group `agents` and remains group-readable and writable (for example, mode `0660`). Sessions refresh this file.

`agent-doctor` checks the required host runtime, process group, base and harness layer, and reports a missing or unreadable Claude credential. It reports which pi provider it checked and fails if the shared login is unreadable, invalid JSON or lacks that provider's key. This read-only `jq` check requires no host pi installation and never refreshes OAuth tokens underneath running sessions; it does not prove the token is unexpired or accepted by the provider. A project's layer is checked on launch, with the missing path in the error. `agent-layer` builds layers; the runner still only checks that they exist.

Workspaces are run directories at `$AGENT_RUNS/<workspace>/` (default **`/var/lib/agent-runs`**). `AGENT_RUNS` is overridable for tests; the installed unit hard-codes `/var/lib/agent-runs`, so a different path is not a live-host runtime option. Directories and records are created with umask 002 for the agents group; the host declares group ownership/inheritance.

| Path | Contents |
| --- | --- |
| `work/` | clone and submodules |
| `agents/` | harness snapshot, mounted read-only |
| `manifest.json` | workspace facts, including the repository it cloned |
| `sessions/`, `prompts/`, `transcripts/` | per-session records, prompts and transcripts |
| `exports/` | writer-session JSON (commit shas and dirty flags) and per-repo Git bundles |
| `run.env` | harness, model, pi provider, session number, optional spend cap |
| `root` | link to `AGENT_BASE` |
| `layers/` | links to the required images and existing optional confext pairs |
| `home/` | writable home, retained across sessions |
| `cache` | link to `$AGENT_RUNS/.cache/<repo>`, shared by that repo's workspaces |
| `review/work` | link to `../work`, only for read-only sessions; removed for writers |
| `pi/` | pi's run directory (`PI_CODING_AGENT_DIR`): optional `settings.json` and `agents/`, plus the shared-login `auth.json` link |

Each workspace mounts at **`/srv/job/<workspace>`** (`AGENT_JOB`), with the checkout at **`/srv/job/<workspace>/work`**. The session entry point is `/srv/agents/session` and the shared repository cache is `/srv/cache`. The runner creates `work/`, `home/` and `agents/` before starting, but never creates mount-point directories inside them; mount targets exist in the run directory or sit on the unit's `/srv` and `/home` tmpfs. The distinct path prevents Cargo's shared target cache from reusing another workspace's local-crate build. The agent runs as its own system user, with a read-only base tree, restricted network access and host-managed resource limits. Sessions can reach the host's loopback, including anything listening on all interfaces (0.0.0.0 or ::) via loopback, so a host should not run loopback-only services that sessions must not reach. See the header of [`agent@.service`](system/usr/lib/systemd/system/agent@.service) for the authoritative run-directory contract.

The target repository's own startup lives in `.sandbox/`, all optional:

- `setup`: sourced before each session and the landing gate; exports tool paths and points tools directly at `/srv/cache` (for example, `CARGO_HOME=/srv/cache/cargo` and `CARGO_TARGET_DIR=/srv/cache/target`). Session output goes to `setup.log`; failure fails the session. `.sandbox/volumes` is not supported; the project chooses cache locations in `setup`, not mount declarations.
- `prompt.md`: standing prose prepended to every session prompt; a matching `Run kind: <kind>` contract from the trusted agents snapshot comes first. Put generic work/review/fix rules in that contract and project-specific gate commands, task systems and other project rules here.
- `gate`: the repository's landing gate (`AGENT_LAND_GATE` can override it).

A driver that turns a project's tasks into sessions belongs to that project, beside its `.sandbox/`.

## Commands

Run these from the host, not inside an agent session. The unfiltered `agent-status` listing omits retired workspaces; their records and transcripts remain on disk, and `agent-status <workspace>` can still show a retired workspace's state.

| To | Command |
| --- | --- |
| get command help | `agent help` |
| create a workspace only | `agent new` or `agent-new` (prints its id) |
| start any task in a new workspace | `agent-run --prompt <file\|text>` |
| add a session | `agent-run --in <workspace> --prompt <file\|text> [--harness pi] [--model <id>] [--read-only] [--label <text>] [--wait]` |
| read JSON results | `agent-result <workspace>[/<n>] [--wait]` |
| branch on a review | `agent-review-status <workspace>[/<n>] [--wait]` |
| fix a review | `agent-fix <workspace>[/<n>] [--review <file> --reviewer <name>] [--harness claude\|pi] [--model <id>] [--note <file\|text>] [--nits] [--wait]` |
| list landings awaiting a human verdict | `agent-verdict --pending` (workspace, repository, label, landed commit; tab-separated) |
| list the human's review feedback, so someone reads it | `agent-verdict --feedback [<time>]` (time, workspace, repository, label, review or finding id, stance, note; tab-separated, oldest first) |
| read a landing's review thread | `agent show <workspace>` or `agent verdict --pending \| fzf \| agent show -` |
| record a human, facilitator or orchestrator judgment | `agent-verdict <workspace> --agree\|--disagree [--by human\|facilitator\|orchestrator] [--overrule <text>]... [--missed <text>]... [--note <text>]` (no judgment flag: help, nothing recorded) |
| comment on one finding of a landing's review | `agent-verdict <workspace> --on <finding-id> [--agree\|--disagree] [--by human\|facilitator\|orchestrator] [--note <text>]` (appends; the landing stays pending) |
| give an outside agent a mailbox, not a shell | `agent-mailbox <agent>` as its key's forced command (see Outside agents) |
| fetch commits without merging | `agent-harvest <workspace>` |
| gate and merge harvested work | `agent-land <workspace>` |
| stop sessions gracefully | `agent-stop <workspace>[/<n>]` |
| discard a workspace with no commits | `agent-retire <workspace>` |
| read completed-session token usage as JSON | `agent-usage <workspace>[/<n>]` |
| see workspaces, recent tool calls and questions | `agent-status [<workspace> [n]]` |
| wait until a running session asks a question | `agent-status --wait-question` |
| answer a session question | `agent-answer <workspace>/<question> <text\|file>` |
| check whether a repository is held | `agent-status --held <repo-path>` |
| explicitly install the host commit guard | `agent-doctor --install-hooks <repo-path>` |
| check this host's setup | `agent-doctor` |

`agent-run` prints `<workspace>/<n>` and normally returns once the unit is up. A prompt names a file if it exists, otherwise it is literal text. `agent-result --wait` blocks until the named session (or all sessions in the workspace) stops and finalizes records. Its exit codes are 0 for finished/ready, 1 for failed/stopped, 3 for running/preparing. A normal harness exit is not proof that the task succeeded: read the closing message.

### Session questions

Work, review and fix sessions can call `/srv/agents/agent-ask "question"` once
when they need context from their launcher. The helper writes an untrusted
`questions/<id>.md` outside `work/` and blocks without model polling until the
host writes `questions/<id>.answer`. It prints the answer as plain text; it never
runs it. `agent-status` displays unanswered questions from running sessions,
including a sanitized first line and a per-workspace count. A facilitator can
block in `agent-status --wait-question` and answer with
`agent-answer <workspace>/<id> "text"` or a file. Answers are never overwritten.

The default wait is 900 seconds; set `AGENT_QUESTION_TIMEOUT_SECS` in the
launcher environment to a positive value no greater than 3600 seconds. A timeout
exits non-zero, marks the question with `<id>.timeout`, and tells the session to
take the normal `NEEDS DECISION` stop. Timed-out questions are excluded from the
host's waiting list and cannot be answered. This leaves time before the unit's
six-hour maximum. Question and answer files are
capped at 65536 bytes. Questions are data only, not commands or terminal input;
the host refuses symlinks, non-regular files and oversized questions rather
than reading them. The session holds its unit, workspace lock and deadline while
waiting, so ask only when the answer can unblock worthwhile work.

Host commands never run Git in agent-writable clones. Writers export plain data inside the sandbox; harvest fetches bundles into real repositories. Missing or invalid commit exports are reported as JSON `null` (unknown), and harvest/land refuse them. Read-only and gate sessions do not export. Harvest and land require the latest writer's valid export, never an older writer's: SIGKILL or OOM can prevent the EXIT trap from exporting. If they report `session <n> left no export (killed?)`, run a short writer to export the retained commits, for example `agent-run --in <ws> --prompt "Commit nothing; end."`, then harvest again. Bundles are named `root.bundle` for the root and `sm-<URI-encoded-path>.bundle` for submodules.

`AGENT_SESSION_USD` defaults to $3 per session. The static unit defaults to a six-hour deadline, 60-second stop grace, and per-session limits of 8 CPUs and 16G memory with no swap. CPU and memory limits are the unit's defaults; `AGENT_CPUS` and `AGENT_MEMORY` are gone. Limits belong to the host: use unit overrides for defaults, or override one run with `systemctl set-property agent@<workspace>.service CPUQuota=400% MemoryMax=8G`, not runner-generated units. Follow a session with `journalctl -u agent@<workspace>.service -f`. Starts and stops use the system manager with `--no-ask-password`, never the user manager.

## Session usage

`agent-usage <workspace>[/<n>]` reads each session's record and transcript (headless Claude stream or pi JSON) and prints JSON: per-session counters named `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`, `output_tokens`, plus an aggregate. It makes no API calls, reads no credentials or `run.env`, and estimates no cost. Interactive session files and live snapshots are out of scope.

- **Claude:** the final `type=result` `.usage` only; preliminary `assistant` usage is ignored (it undercounts). No result, several results or no counters is `missing`/`ambiguous`, never a guess. Counters that are not whole non-negative numbers are invalid, and malformed lines next to a result (which may have been a second result) make it `partial`.
- **Pi:** the sum of completed assistant `message_end` usage (`input`, `output`, `cacheRead`→`cache_read…`, `cacheWrite`→`cache_creation…`), never `message_update` deltas. In pi's normalization for the OpenAI-style and Anthropic adapters, `input` excludes cache reads and writes, and `output` includes reasoning; other adapters were not checked. Pi writes 0 when a provider omits a counter, so a pi zero may mean unreported. Error and aborted messages keep their reported counters but make the session `partial`, as do pending or absent `stopReason`, counters missing from a message (each counter is summed from the messages that state it), and an unfinished session. Identical `message_end` events carrying a `responseId` or `timestamp` count once (`partial`); identical ones without identity are `ambiguous`; distinct messages with equal usage are never merged.
- **Status** per session: `reported`, `partial`, `missing`, `ambiguous`, `incomplete` (still running), or `unreadable` (bad or non-single-object record, or a read/parse failure; the row is kept, never dropped). Record outcome `failed:start` only sets `start_failed: true`: it does not prove the model never ran, so any transcript consumption is still reported. Counters are `null` when unknown; `0` means the transcript stated zero. A missing transcript is not zero. `counters_complete` is true when all four are stated. Only files that really resolve inside the run's `sessions/` and `transcripts/` are read; symlinks that leave them, directory symlinks included, are treated as unavailable.
- **Aggregate** totals sum only `reported` sessions. Each field has `observed_sessions`, `missing_sessions` (reported sessions lacking it), `unobserved_sessions` (every session not contributing to the sum) and `lower_bound_sum` (reported plus partial). `complete` is true only when every session is `reported` with all four counters. A failure to reduce the workspace exits non-zero without partial output. Session numbers must be canonical positive decimals of at most 15 digits (`1`, not `01`, `0` or longer); a malformed `<n>` or a digit-only `sessions/*.json` name such as `01.json` makes the command exit non-zero with no stdout rather than hide or double-count a session.
- **Model and route:** `record_model` is the requested model; `observed_models` and `observed_providers` appear only when the transcript carries them (Claude's `system.init` model; pi's per-message `provider`). A provider is the pi route, not a billing account or subscription. Claude's route is unknown, and older sessions are never inferred from the current `run.env`.

## Host commit guard

Do not edit a project's tracked files on the host while a session holds it.
`agent-status --held <repo-path>` prints the holding workspace ids and unit
ActiveState, tab-separated, one per line. It exits **0 when held**, **3 when not
held**, or **2 for invalid input/record errors**. Other failures are also errors,
never a not-held answer.
Paths inside the repository and symlink aliases resolve to the same checkout.
Only writer sessions hold the repository; read-only reviews do not conflict
with host commits. Records without `read_only` count as writers. Running records are
checked against the unit: stopped units release stale holds; unavailable manager
state conservatively retains them, shown as `unavailable`. A failed unit query
also retains the hold, even if it printed a stopped state. Corrupt or unreadable
session records refuse the check. No sessions means no hold and no unit query.

Opt in separately in each **host clone**:

```sh
agent-doctor --install-hooks /path/to/repository
```

This installs an executable `pre-commit` hook at Git's hooks path (honoring
`core.hooksPath`), refuses to replace a human's hook, and is safe to repeat.
The installed stub forwards to this tool checkout's `lib/agent-pre-commit.sh`, so
moving that checkout's revision updates the guard without reinstalling hooks.
Reinstalling upgrades old byte-copied guards identified by their
`# Installed explicitly by agent-doctor --install-hooks. Host PATH declares tools.`
marker line; unmarked hooks and symlinks are never replaced. If the installed
checkout moves or disappears, commits fail closed until the guard is reinstalled.
It never installs silently or into workspace snapshots. The guard resolves
`bin/agent-status` beside its own checkout, not from the host's `PATH`; a missing
command fails closed. The hook names every holding
workspace and refuses the commit; check failures also refuse rather than silently
allowing a commit. Only the human's explicit `git commit --no-verify` bypasses it;
there is no sandbox bypass setting.

This is a commit-time coordination guard, not a file lock: it does not prevent
editing, and a session can start after the check. It tracks the host checkout
named by the workspace manifest, not every independent clone of the same remote.
Manifest `.repo` paths must be absolute; relative paths are refused, not resolved
against the caller's directory. Linked Git worktrees are distinct checkouts for
hold matching, even though their default hooks directory is shared: a hold on
one worktree does not hold its siblings.
It does not install a `merge=union` attribute for `.actions` files: a refused
commit or merge conflict is preferable to a garbled action line.

## Review, fix and land

1. Start work with `agent-run --prompt`, or with the project's own driver.
2. Read the result with `agent-result <workspace> --wait`.
3. Start a read-only review in the same workspace with a **different vendor**, for example:

   ```sh
   agent-run --in <workspace> --harness pi --read-only \
     --prompt "Run kind: review. Target: this workspace's branch."
   ```

4. Read the review, then use `agent-fix <workspace>[/<n>]` for blocking and should-fix findings. Without a session number it selects the latest read-only session with a parsed review. `--nits` includes nits; `--note` supplies human decisions. An external review can instead be supplied with `--review <file> --reviewer <name>` (not with a session number); it is retained in `reviews/`.

   A workflow can use `agent-review-status <workspace>[/<n>] [--wait]` to branch on a review without treating a clean session exit as approval. It prints the verdict (or a `needs person: ...` state) on one line: exit 0 means `land`, 10 means `land after fixes`, 11 means `do not land`, 12 means a person must decide (including an unparsed/missing review, failed or unfinished session, or non-read-only session), and 2 means invalid usage or no such workspace. Without `<n>`, it checks the latest read-only session even when that review is unparsed; `--wait` waits for that session via `agent-result`. Unknown verdicts never authorize landing.
5. Check fixes. A fix does not reconcile a finding; the human records reconciliation after checking it. Reviews advise landing, not gate it.
6. Run `agent-harvest <workspace>` when no session is running; it fetches branches in each repo and shows commits and closing messages without merging. Harvest again after further sessions.
7. Run `agent-land <workspace>`. Before merging, it checks the harvested branch's test-commit file locks in every repository (see below). It merges bottom-up into the candidate run directory `$AGENT_RUNS/land-<workspace>/work`, then starts `agent@land-<workspace>.service` with `AGENT_HARNESS=gate`. `agents/session` sources `.sandbox/setup`, runs the gate, and writes `gate.status` and `gate.log`. Landing requires both a successful unit outcome and gate status 0. No real branch advances until the gate passes. It prints unreconciled blocking findings for the human's decision.
8. Record the human's, facilitator's or orchestrator's landing judgment with `agent-verdict`; then push separately. Without `--by`, the command defaults to the human only when stdin is a terminal; nonterminal calls that record a judgment must name the judge explicitly, preventing unattended callers from accidentally recording a human verdict.

At landing the host builds the conversation from its session records, in session order, and writes it as one note (`refs/notes/review`) on the landed root commit. Each review starts `# review <workspace>/<n>: <verdict> by <model>`. Each finding has a stable ID, `<review session>#<1-based index>`, and a quickfix line: `file:line: severity: <id> what — why` (or `(approach): ...` without a file). Early findings may refer to lines that later fixes moved.

`agent-fix` supplies those IDs (without renumbering filtered nits). Its closing report lists `fixed` IDs and `declined` objects with `id` and `why`. Each fix starts `# fix <workspace>/<n> by <model>, answering review <n>`, followed by `fixed: <id>` and `declined: <id> — why` lines. Landing saves the whole text to `$AGENT_RUNS/<workspace>/review-thread.txt` before merging or advancing. Note-write failures warn; rerun `agent-land` after landing to rewrite the same saved text, without rereading session records. There are no per-repository notes or agent-chosen commit anchors. Harvest writes no notes.

The root landing message records the newest review's outcomes as trailers:

- `Finding-Fixed: <id> <what> (<severity>), by session <n>`
- `Finding-Open: <id> <what> (<severity>)`
- `Agent-Workspace: <workspace>`

A writer's parsed fix report can mark a finding fixed; Finding-Fixed credits its session, not a commit. An explicit `review_session` link identifies the answered review, including a review file stored in the same second. Legacy fixes without a link must be later sessions, or have a start timestamp at or after the external review's timestamp. IDs match exactly; legacy `what` strings match only exactly and unambiguously, never by prefix or fuzzy similarity. Declined, missing and unmatched findings stay open. This records a fixer's claim, not human approval. For example, `git log --format='%(trailers:key=Finding-Open)'` lists open findings across landings. Submodule merge messages retain the workspace trailer; the root records the overall outcomes. Merge messages also include the newest work session's first closing paragraph.

Recorded human, facilitator and orchestrator verdicts go to `refs/notes/verdict` on the **landed root commit** and are stored independently in the workspace manifest. A later `agent-verdict` appends a new judgment, preserving earlier judgments; before landing it only updates the workspace manifest. Notes are conversation records, not mutable finding state. The human-only `--pending` and `--feedback` views ignore facilitator and orchestrator verdicts: an orchestrator judgment does not satisfy the human's pending review.

`agent show <workspace>` prints saved reviews and fix reports in session order, then landing trailers and append-only verdict notes. Finding paths resolve to the local checkout, so `nvim -q <(agent show <workspace>)` works from anywhere. Both `agent show -` and `agent verdict - --agree --by human` read the first tab-separated field of the first stdin line, for pipelines from `agent verdict --pending` through a selector.

The human's feedback needs a reader. `agent verdict --feedback [<time>]` lists verdicts and finding comments recorded after a time. A bundle verdict, which ends a review, also runs the host's hook if it is executable: `$AGENT_VERDICT_HOOK`, by default `~/.config/agent-sandbox/on-verdict`, as `<hook> <workspace> <judge> <repository>`. The hook belongs to the host, not to a repository, so a landed change can never alter what runs; it should return quickly and do slow work in the background. Tests set `AGENT_VERDICT_HOOK=` so they never run it.

Read either note with `git notes --ref=review show <landed-commit>` (or `--ref=verdict show <landed-commit>`). Open review findings in nvim quickfix with `nvim -q <(git notes --ref=review show <commit>)`. Fetch notes with `git fetch origin '+refs/notes/*:refs/notes/*'`; after landing, push them explicitly with `git push origin refs/notes/review refs/notes/verdict`. The sandbox does not change any remote's push configuration.

A commit whose subject starts with `Tests:`, `test:`, or `test(<scope>):` locks every file it touches against later commits whose subjects do not start with one of those prefixes on that branch. The prefixes are case-sensitive; `tests:` and `testing:` do not lock files. Landing checks commits since the branch diverged from the real checkout using only Git, with no model call. A later matching test commit may change locked files or lock additional files; it does not forgive an earlier violation. Other commits may change unlocked files. “Later” means a descendant in Git history, not a newer timestamp; deletions and renames count as changes, and merge commits are checked against each parent. Even editing and then restoring a locked file is refused. The refusal names the repository, files, locking commits and violating commits, before any candidate merge or gate. There is no override: repair the branch history and harvest again before retrying.

The landing gate runs the branch's `.sandbox/setup` and gate in the same unit template as sessions, so it can read the Claude credential and pi's shared login. For our own work, the branch was written by agent sessions that already held both, so this adds no credential exposure. If gates ever run code from elsewhere, give them their own unit without the credential and the login.

A conflict leaves the candidate for resolution and a rerun. A red gate leaves the candidate and `gate.log`, with real branches unchanged. Once gated, the host never runs Git in that candidate again: reruns gate the retained tree and advance to tips saved before its first gate. To incorporate candidate edits or newly harvested work after gating, remove the candidate and rerun. If a real branch moved after the candidate was built, remove the candidate and rerun. Advancing several repos is not atomic: a partial failure reports which advanced, and a rerun skips them. Successful landing removes the workspace clone and candidate clone, retaining records, transcripts and the candidate's home/cache.

## Outside agents

An agent that runs on its own machine, outside our trust boundary, can reach this host over SSH only through a mailbox. Its key goes in `~/.ssh/authorized_keys` as

```
restrict,command="<sandbox>/bin/agent-mailbox <agent>",from="<its addresses>" <key>
```

so every connection runs `agent-mailbox` with no terminal or forwarding. The agent can `tasks` (list the ids queued in agent-queue's `to-<agent>/incoming/`), `get <task-id>` (print one), and `put <task-id> [<file>]` (store stdin, default `report.md`, in `~/.local/share/agent-mailbox/<agent>/<task-id>/`). Names are checked, a delivery is never overwritten, each file is capped at 1 MiB and the inbox at 64 MiB, and every call is logged in `calls.log` there. Nothing the agent sends is run, and deliveries are data for the facilitator to read. The script lives in this repository, not agent-queue, because the outside agent can push to agent-queue.

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

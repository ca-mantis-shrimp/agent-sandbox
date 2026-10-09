---
id: 01a0dab2-c8dc-7eb1-bdf0-36d42e27a5f6
alias: agent-sandbox
state: Active
objectives: [trustworthy-evolution, strong-CI-CD]
description: Run headless agents on our own hardware in a disposable container whose only output is commits, with standard telemetry, so unattended work is safe, reviewable and measurable without a proprietary cloud
---

# Agent Sandbox

Started 2026-09-25. The NUC runs agents unattended; this charter keeps that disciplined.

## Principles

- **Git is the only channel.** A run clones the repo, the agent commits, `agent-harvest` fetches the commits back. No credentials enter the container except the model's own.
- **The host stays boring.** Tools live in the image; runs, caches and images are disposable.
- **Stopping is a good outcome.** A clear account of why an agent stopped beats a forced finish. Spend caps bound every session, and nothing rewards gaming the result.
- **Standards first.** The environment is systemd images: a pinned base from personal-os, plus extension layers (sysext/confext DDIs) built by mkosi from recipes; sessions are systemd units (meta-analysis DECISIONS: systemd, not podman; images are DDIs; bases pinned, layers float). Telemetry uses OpenTelemetry semantic conventions; a custom attribute needs a reason.

## Dependency direction

ClearHead is aware of everyone; nobody is aware of ClearHead. Charters and actions have lifecycles, and the sandbox must outlive any one of them.

| Layer | Knows about | Owns |
| --- | --- | --- |
| host | the sandbox, by `PATH` and its package | the installed unit and polkit rule (system/PKGBUILD), the base tree, credentials in /etc/credstore, timers: when things run |
| sandbox | git, systemd, mkosi, harnesses | clone, `agent@` unit, layer builds (`agent-layer`), harness layer and adapters, manifest, telemetry |
| project | the sandbox, through `.sandbox/` | its layer recipe (`.sandbox/layer`, optional), setup, gate, driver: what runs |
| ClearHead driver (platform's) | sandbox, ClearHead | queue loop, prompt, completed/blocked/unfinished |
| ClearHead data model | whatever it links to | an action points at the commits a run produced |

Many hosts and many projects use the same sandbox, each declaring its own part its own way (decided with the human, 2026-10-03); the sandbox knows none of them. So it works on any repo, with or without a `.sandbox/layer` or a `.clearhead/`, on any host that `agent-doctor` passes.

## Flow

The human's review time is the constraint, not the machine: every workspace produces work to review.

- **At most two unreviewed workspaces.** Starting more only grows the queue.
- **Parallel across separate areas, one at a time within one area.** A workspace clones `main`, so workspaces over the same files conflict at landing, and one built on unlanded work starts stale. Work that belongs together goes in one workspace, as sessions (`--in`).
- **While a session works, the orchestrator works on something that doesn't overlap with it.** Editing `agents/` is safe: a workspace uses its own snapshot.
- The NUC fits about two sessions at once (8 CPUs and 16 GB each; the shared build cache serializes compiles).

## Current status, 2026-10-03: its own repository

The runner left platform: this repository is the sandbox, with its history, and platform uses it from PATH (its driver, `scripts/clearhead-work`, its `.sandbox/` and its runbook stay there). All eight platform assumptions listed in `sandbox-extract` are gone; that action records how, what was verified and what is left. The 2026-09-30 handoff below predates this; its paths under `scripts/` are now `bin/`, `lib/` and `test/` here.

## Handoff, 2026-09-30 (updated after the first gated landing)

**Where it stands.** The runner is harness-neutral and knows nothing about ClearHead. Workspaces, agents and sessions are separate; the Log below records the decisions. The durable command reference, repository setup, review/fix loop and gotchas live in [the agent sandbox guide](../../README.md).

**What to work on next, in order:**

1. `sandbox-auto-reconcile` (priority 1): partly overtaken on 2026-09-30, see the note at the end of its description. Narrow it before working it.
2. `sandbox-extract` (priority 3): decided 2026-09-30 (move the sh as is; sibling repo `~/Products/agent-sandbox`, used from PATH). Its description lists the platform assumptions still in the runner. Port trigger, the orchestrator's view: the first feature that needs shared state across scripts beyond one jq expression.
3. Curate the unscheduled queue before running `clearhead-work` without arguments: on 2026-09-30 its top was sandbox work and undecided items (calendar-sync needs a charter). Until then, name decided actions.

**Verified on the host, 2026-09-30:** a Claude worker, a `gpt-6-sol` read-only reviewer and a Claude fixer as three sessions in one workspace; the writer guard; two simultaneous launches; `.sandbox/setup`; harvest. Then workspace 20260930-101709: `clearhead-work` over two named actions (two Claude sessions, $0.20 and $0.32, both completed), a `gpt-6-sol` read-only review ($0.11, "land"), harvest, and `agent-land` through the candidate gate (53s), which merged into a main that had moved. The landing gate passes in the image from a fresh clone (about 75s). `scripts/agent-runs.test.sh`, `agent-quadlet.test.sh` and `agent-land.test.sh` pass.

**Not verified, so do not assume:**

- A pi *work* session (read-write) through `agents/session`. Only read-only pi sessions ran.
- A stop (`agent-stop`), a timeout and an OOM under per-session units.
- `clearhead-work` over the unscheduled queue with no arguments.

**Known gaps:**

- `sandbox-cross-vendor-review` can close: a real work run was reviewed by a read-only session from another vendor. Its description still asks for a durable verdict and findings; the closing message carries them today.
- The landing gate re-downloads npm and uv dependencies on every landing; cache volumes would make it faster.
- Two writers at once in one workspace would need a worktree per session; nothing needs it yet.

## Historical handoff, 2026-09-25

Before the 2026-09-30 redesign, one `scripts/agent-run [action]` was one run in one container and `agents/loop` worked the queue inside it. Only Claude had a runner adapter; pi/Codex reviews were launched by hand. The earlier queue started with `land-run-171333` (a Codex review's two should-fixes), then dated snapshots, the driver split, telemetry and benchmarks, and extraction. The current state and actions above supersede that handoff.

## Findings

- 2026-09-25: headless sessions end when the agent replies. Tools that wait for a later turn (`ScheduleWakeup`, background jobs) silently lose the work, so they are disallowed.
- 2026-09-25: "exit 0" is not an outcome. The driver judges the action's state, and every session's closing message reaches the human at harvest.
- 2026-09-25: a spent budget ended a session before it recorded its finding. The prompt now says to record a decision point before exploring further.

## Log

- 2026-09-30T01:27-07:00 — driver-split step 1 of 3 landed: agent-run --prompt <file|text> starts one generic session (agents/session) and returns the run id on stdout at once; agent-result <id> --wait finalizes and prints the manifest, which now carries sessions {label, ok, cost_usd, closing, stop_reason, transcript} and commits per repo. agents/loop keeps the ClearHead queue for now and adds action and outcome (the action's real state) to the session it started. Run ids are claimed with mkdir so parallel launches cannot collide. Verified on the host with four real runs: string prompt with a commit, file prompt, two simultaneous launches, and the loop path on a missing action. Next: move the queue loop to a host orchestrator that calls --prompt, then the repo setup hook.
- 2026-09-30T01:30-07:00 — driver-split step 2 of 3 landed (reordered: the hook had to precede the orchestrator, since per-action runs each need clearhead on PATH): agents/session sources the clone's .sandbox/setup and prepends .sandbox/prompt.md, both optional. Platform's setup builds clearhead from the branch (3s with the shared cache); its prose points every session at the runbook. Open question before step 3, the host orchestrator: one run per action means each clone starts from HEAD, so a queue no longer stacks its actions' commits on one branch the way the in-container loop does.
- 2026-09-30T01:50-07:00 — driver-split DONE, with a redesign decided with the human on 2026-09-30: workspaces, agents and sessions are separate things. A workspace (agent-new) is a clone on its own branch; an agent is a harness plus a model, chosen per session (--harness, --model, defaults in agents/models.env); a session (agent-run --prompt, --in <workspace>) is one agent on one prompt in one workspace, with its own Quadlet unit and its own record, sessions/<n>.json, which names the commits it made. One writer at a time per workspace, a writer excludes readers, read-only sessions may overlap. agent-result <workspace>[/<n>] --wait is the JSON contract. The ClearHead side is scripts/clearhead-work (host: one workspace, a session per action, outcomes in clearhead-work.json) plus .sandbox/ (setup, prompt.md, work-prompt.md); agents/loop is gone. Verified on the host: a Claude worker, a gpt-6-sol read-only reviewer and a Claude fixer in one workspace, the reviewer seeing the worker's commit and refused a write by the read-only mount; the writer guard; the driver; harvest. This also delivers the mechanism of sandbox-cross-vendor-review (a review is a read-only session with another harness); that action stays open until a real work run has been reviewed this way. Not done: concurrent writers in one workspace, which would need a worktree per session.
- 2026-09-30T10:30-07:00 — sandbox-premerge-gate DONE: agent-land gates a candidate clone in the sandbox image before any real branch moves. Running the gate in a clean image found five host-only assumptions (npm 12 blocking tree-sitter-cli's installer, topiary, graphviz, the RDF proof and the nvim specs using installed builds) and a real crash in clearhead.nvim on Neovim 0.12 without the parser. First real use: clearhead-work over two named core actions, a gpt-6-sol review, and a landing. Two bugs found on the way, both fixed with tests: agent-result --wait ended when a pacman upgrade re-executed the user systemd manager, and agent-land refused repos a workspace left alone.
- 2026-09-30T21:27+00:00 — 2026-09-30, the human dropped the transcript-derived coverage metric (opened_in_full) after it scored a diligent reviewer 0 of 6 on a real transcript, since reviewers read changed regions with offset/limit; the structured review report (coverage, findings, for_human, verdict) stays, and self-reported coverage is calibrated against the human’s verdicts instead.

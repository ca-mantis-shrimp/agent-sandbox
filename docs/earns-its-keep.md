# Does the sandbox earn its complexity?

The steward's answer, 2026-11-07, to Darrion's question that day: "do we like the tool? its functionality justifies the
complexity? theres no better architecture staring at me?" (=earns-its-keep). Measured from this repository, `~/Products`,
`/var/lib/agent-runs` and the Claude transcripts on this host. Every number below says how it was measured. A
guess is labelled as one.

## The answer

**Yes, it earns its complexity, and no rebuild is warranted.** It may get about 8% smaller, if the one command
nobody seems to use is deleted, and it should gain a linter.

- **Use.** 126 workspaces, 453 sessions and 92 gated landings in four weeks (`/var/lib/agent-runs`, 2026-10-10 to
  2026-11-07). Three repositories call it from code (assistant, meta-analysis, platform), and the Dagu workflows are
  built on it. Six repositories ran work in it: srr 52 workspaces, agent-sandbox 32, platform 18, assistant 7,
  meta-analysis 6, yapdm 2. The other 9 were scratch repositories under `/tmp` or have no recorded repository.
- **Size.** 29 shell files with 2,888 lines (2,344 without comments and blank lines), plus 228 lines of jq. The unit,
  completions and packaging are not counted. The 3,694 test lines outnumber the code.
- **Bash is not the problem.** 5 of the 59 review findings since 2026-10-25 are clearly shell-specific, and 3 more
  partly. That is 8–14%, and none of the 5 blocking findings is purely shell-specific. The 2026-10-25 survey of 49
  defect fixes found 8–11 shell-shaped (16–22%). That share is history, not a bound: another language could also
  prevent some logic errors, or add its own. But the defects we have are mostly logic and design, which survive
  a port of roughly 3k code lines and 3.7k test lines. Shellcheck is cheap but narrow. It catches the 16 no-op `! cmd`
  assertions (SC2251) and quoting, not lost pipeline statuses or races, so it is hygiene, not the answer to those.
- **No better architecture is staring at us.** The suspected overlaps are not there, as the next section shows. The
  complexity sits in two places, and both carry features that were asked for. Landing (`agent-harvest`,
  `agent-land`: 544 lines, 16 of the 59 findings, 12 fix commits) is mostly multi-repo submodule landing, which platform
  uses: 15 submodule merges since 2026-10-01. The review record (`agent-fix`, `-review-status`, `-verdict`, `-show`,
  `agent-review.jq`: 471 lines) implements Decisions 1–4 and 8.

## The suspected overlaps

| Suspicion | Finding |
| --- | --- |
| Dagu workflows re-encode fix, review-status and land | No. `wf-cycle` and `wf-land` call `agent-review-status`, `agent-fix`, `agent-harvest` and `agent-land` as primitives. None of them parses reviews, builds fix prompts or merges. The workflow sequences; the sandbox does each step. |
| Isolation duplicates podman, systemd-nspawn or bubblewrap | No. Isolation is `agent@.service`, 79 lines of systemd directives (RootDirectory, ExtensionImages, ProtectSystem, PrivatePIDs, IPAddressDeny, ...). Images come from mkosi via `agent-layer` (144 lines). Moving to podman or bubblewrap would replace this declaration, not remove any shell. That move is already ruled out: meta-analysis decided on systemd, not podman. |
| Verdicts belong on the approval record | Probably, later. =verdicts-as-approvals already plans it and waits on meta-analysis's =approval-record. If storage stays in git notes, only the format changes, so the code shrinks little. This is a guess, not a measurement. |

## Inventory

Lines are `wc -l`. "Code callers" means scripts outside this repository that run the command; docs are not counted.
"Uses" counts calls in Bash tool inputs across the 199 Claude transcripts kept on this host. It is a rough lower bound:
pi sessions and humans at a terminal are not counted. "Fixes" counts commits whose subject starts with fix.
"Findings" counts review findings on that file since 2026-10-25, from the 11 landings with `refs/notes/review`.

| Command or lib | Lines | Code callers | Uses | Fixes | Findings | Mark |
| --- | ---: | --- | ---: | ---: | ---: | --- |
| `agent-run` | 86 | assistant `dispatch`, `wf-work`, `review-cycle`, platform `clearhead-work` | 354 | 1 | 0 | keep |
| `agent-result` | 56 | `wf-session`, `wf-cycle`, `wf-review-history`, `clearhead-work` | 605 | 0 | 0 | keep |
| `agent-new` | 77 | `clearhead-work` | 34 | 1 | 0 | keep |
| `agent-reconcile` | 68 | none: only `agent-run`, `-result`, `-harvest` and `-land` call it | 2 | 1 | 0 | merge into `lib/` |
| `agent-status` | 153 | assistant `wake`, `question-watch` | 235 | 0 | 0 | keep |
| `agent-stop` | 37 | none (manual) | 16 | 0 | 0 | keep |
| `agent-retire` | 81 | none (manual) | 12 | 0 | 0 | keep |
| `agent-harvest` | 87 | `wf-land`, `clearhead-work` | 172 | 2 | 0 | keep |
| `agent-land` | 457 | `wf-land` | 261 | 12 | 16 | keep, watch |
| `agent-fix` | 87 | `wf-cycle` | 151 | 0 | 0 | keep |
| `agent-review-status` | 82 | `wf-cycle`, `wf-land` | 31 | 1 | 3 | keep |
| `agent-verdict` | 159 | assistant `on-verdict`, `wake` | 140 | 2 | 1 | keep, reshape (=verdicts-as-approvals) |
| `agent-show` | 54 | assistant `on-verdict` | 25 | 1 | 2 | keep |
| `agent-answer`, `agent-ask`, `agent-questions.sh` | 228 | `question-watch` waits on questions; answers are typed by hand | 12 | 3 | 6 | keep |
| `agent-usage`, `agent-usage.jq` | 236 | none | 14 | 0 | 0 | **delete, if the facilitator confirms** |
| `agent-doctor` | 134 | none (manual) | 26 | 2 | 0 | keep |
| `agent-layer`, `agent-repart.sh` | 152 | none (manual, per base) | 16 | 2 | 1 | keep |
| `agent-host-build`, `-install` | 62 | none (manual, per pin move) | 6 | 0 | 0 | keep |
| `agent-mailbox` | 43 | assistant's ssh key (forced command) | 7 | 0 | 0 | keep; ask whether it belongs here |
| `agent`, completions | 115 | every `agent <command>` | — | 1 | 4 | keep |
| `lib/agent-runs.sh` | 296 | shared by most commands | — | 5 | 0 | keep |
| `lib/agent-systemd.sh`, `agents/session`, `export` | 329 | the unit and session runtime | — | 1 | 0 | keep |

By job: the session runtime is 966 lines, landing 544, review 471, host setup 393, shared lib 296, usage 236,
questions 228, the dispatcher and completions 115, and the mailbox 43.

### Why `agent-usage` should probably go

It reports token use per session. It landed on 2026-10-13 after eight review and fix sessions and is 191 lines without
comments, 7.5% of the code, plus 295 test lines. No script calls it. The Claude transcripts that ran it date from
2026-10-13 and 10-15, the days it landed. The one call since (2026-11-07) gave no arguments, which fails. Pi
sessions and a human at a terminal are not counted, so this shows little use, not none. assistant's `model-tiers` hypothesis
names it as the place to read tokens, and `scripts/pace` reads subscription limits instead. If nobody measures tokens per
session, the command is carrying a feature nobody uses. Before deleting it, I ask the facilitator, who owns that
hypothesis (=drop-usage).

### Why merge `agent-reconcile`

It is a library function shaped like a command: no outside caller, and not in the README's command table. Moving it
into `lib/` saves no lines but shrinks the public surface from 21 commands to 20. Low value; do it only alongside
other work in those files.

### `agent-mailbox`

It is an ssh forced command for outside agents, and it names agent-queue, a project. The ground rules say the sandbox
names no project, so this command has the strongest case for moving: to assistant, whose `wake` reads its inbox.
The README explains why it is here (the outside agent can push to agent-queue). Moving it crosses projects, so the
call goes to the facilitator, not this page.

## Where shell does cost us

The shell-specific findings cluster in two patterns:

- **Lost exit statuses.** A pipeline's status is its last command's (`agent-land:319`), and `set -e` exits with jq's
  status (`agent-review-status:66`). Shellcheck catches little of this; it is convention and review.
- **Filesystem-safety code.** In the question and answer files, three fix commits and two blocking findings dealt with
  symlinks, TOCTOU and noclobber semantics. They are partly shell-specific: any language has these races. sh can hold an
  open descriptor (`exec 3<file`), but it has no `O_NOFOLLOW`, `fstat` or `openat`, so it cannot check the file it
  opened, only a path. This 228-line corner is the one place
  where another language would buy real safety. If it keeps producing findings, move it out of sh first, before
  anything else.

## What would change this answer

- **A port trigger.** The 2026-09-30 handoff named one: "the first feature that needs shared state across scripts
  beyond one jq expression". It has not fired as a feature. =verdict-manifest-mode, a manifest rewritten unsafely, is
  the closest so far. Two more bugs in shared manifest writes would be the signal.
- **Landing.** If submodule pin cases keep coming (=land-pin-behind-main, =lock-skip-gitlinks, and the older
  "land submodules agent-land refuses today"), the cause is the design, not slips. Five of the twelve land fixes were
  about pins, all from one run on 2026-11-05. The simpler design would land each repository on its own and move pins
  as ordinary commits. Platform would then land submodules first and commit the pins itself. That is a ⏸ Decision for
  Darrion, if it comes to that; not yet.
- **The queue.** Of the 28 open actions (clearhead's count, 2026-11-07), several are speculative (telemetry, duckdb queries, pasta, an egress proxy,
  vmspawn, tmux sessions). Feature growth is what moved the sandbox from 10 to 21 commands, so I will prune the queue
  before adding any command.

## What the steward does next

1. =gate-shellcheck: add shellcheck to the gate, and fix or justify its warnings.
2. =drop-usage: once the facilitator agrees, delete `agent-usage`.
3. Merge `agent-reconcile` into `lib/` the next time those files change.
4. Prune the speculative actions with the facilitator.

## The shell-specific findings

So the 5 + 3 split can be audited (review notes on the 11 landings since 2026-10-25, `git notes --ref=review`):

- Clear (5): `agent-land:319` pipeline status hid a load failure; `agent-review-status:66` `set -e` exited with
  jq's status; `agent-answer:44` noclobber still opens a non-regular target; `raise-hand.test.sh:165` the shell opens
  a redirection before `cat` runs; `agent-review-status:40` an `if x=$(cmd)` idiom (nit).
- Partial (3): `agent-questions.sh:53` checked a file, then reread it by name (blocking); `agent-answer:60` a relative
  path resolved inside the session's directory (blocking); `agent-land:84` a glob too loose for a commit scope (nit).
- The other 51 are logic, design, docs or tests: for example, the pin detection (`agent-land:258`, `:263`, both
  blocking) and the completion path (blocking).

## Critique

gpt-6.1-sol (pi, openai) reviewed this page read-only on 2026-11-07, in run 20261107-173137/1. Its verdict was land
after fixes, with no rebuild agreed. It checked every line count in this repository and ran the gate, and all 20
test files passed. It could not check host-only numbers (callers, runs, transcripts). Its findings, all taken:

- The shell share was presented as a bound on what a rewrite saves, and shellcheck as covering that share. Both
  claims are now softened (The answer).
- Deleting `agent-usage` was unconditional although the usage evidence leaves out pi and terminal use. It is now
  conditional on the facilitator.
- "sh cannot hold a file descriptor" was wrong; the real limits are `O_NOFOLLOW`, `fstat` and `openat`.
- Nits: four weeks, not five; usage landed 2026-10-13; the 9 workspaces outside the six repositories; the size
  scope. All corrected, and the finding list above was added so the split can be audited.

It also suggested a missed alternative: extract the review record (`agent-verdict`, `agent-show`, `agent-review.jq`,
302 lines) into its own git review tool. It judged that this moves the complexity rather than removing it, and I agree.
=verdicts-as-approvals is the place to revisit it.

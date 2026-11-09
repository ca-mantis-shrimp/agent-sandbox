# Does the sandbox earn its complexity?

The steward's answer, 2026-11-07, to Darrion's question that day: "do we like the tool? its functionality justifies the
complexity? theres no better architecture staring at me?" (=earns-its-keep). Darrion added: "always think what would
the ideal version of this tool look like". So the page starts from the ideal version and measures today's tool against it.
Measured from this repository, `~/Products`, `/var/lib/agent-runs`, `~/.local/state/workflows` and the Claude
transcripts on this host. Every number below says how it was measured. A guess is labelled as one.

## The ideal version

The ideal sandbox does five jobs and nothing else:

1. **Isolate.** It runs one agent on one prompt in a declared systemd unit, over a pinned image. Network and spend
   are bounded, and no credential enters but the model's own.
2. **Run and record.** Each session leaves one record (outcome, commits, closing message, structured report) that any
   driver can wait on and read. A session can ask its launcher a question.
3. **Carry.** Git is the only output channel: commits come back as bundles, fetched without running Git in agent-written
   clones.
4. **Gate and land.** It merges into a candidate, gates the candidate under the same isolation, and advances the real
   branches only on green.
5. **Keep the review with the code.** The review conversation and the verdicts are append-only git records on the
   landed commit (Decisions 1–4).

Everything else belongs to someone else. Sequencing belongs to the drivers (Dagu's workflows, platform's
`clearhead-work`, a person with `dispatch`). Credentials, timers and installation belong to the host. Accounting
belongs to whoever measures.

## Today's tool against it

**It is close to the ideal, and it earns its complexity. No rebuild is warranted.** Lines by job (`wc -l`, the unit and
completions included). Each whole file is assigned to its main job, so the sizes are approximate: `agents/session` also records, `agent-systemd.sh` also isolates, and `agent-runs.sh` serves several jobs.

| Job | Today | Lines |
| --- | --- | ---: |
| 1 Isolate | `agent@.service`, `agents/session`, `agent-layer`, host extension, `agent-doctor` | 599 |
| 2 Run and record | `agent-new`, `-run`, `-result`, `-reconcile`, `-stop`, `-status`, `-retire`, `agent-systemd.sh`; questions 228 | 912 |
| 3 Carry | `agents/export`, `agent-harvest` | 118 |
| 4 Gate and land | `agent-land` | 457 |
| 5 Review record | `agent-verdict`, `agent-show`, `agent-review.jq` | 302 |
| Shared | `agent-runs.sh`, the `agent` dispatcher and completions | 424 |
| Driver helpers | `agent-fix`, `agent-review-status` | 169 |
| None of the five | `agent-usage` 236, `agent-mailbox` 43 | 279 |

- **Outside the ideal: 279 lines (9%).** `agent-usage` is accounting and `agent-mailbox` is an ssh inbox; neither is a
  sandbox job. Both are delete-or-move candidates below.
- **Driver logic kept here: 169 lines (5%).** `agent-fix` builds a fix prompt, and `agent-review-status` turns a
  verdict into an exit code. In the ideal they belong to drivers, but three drivers share them. They stay, and
  no more loop logic comes in.
- **Bigger than the ideal within a job.** Landing is mostly multi-repo submodule landing: 16 of the 59 findings and 12
  fix commits for 457 lines. Platform uses it: 15 submodule merges since 2026-10-01. Running and recording is the
  largest job (912). It is the record any driver reads, and the next section shows that Dagu does not hold the same
  state. I have not measured how much smaller an ideal version of these jobs would be, so I give no number.
- **Use.** 126 workspaces, 453 sessions and 92 gated landings in four weeks (`/var/lib/agent-runs`, 2026-10-10 to
  2026-11-07). Three repositories call it from code (assistant, meta-analysis, platform). Six repositories ran work
  in it: srr 52 workspaces, agent-sandbox 32, platform 18, assistant 7, meta-analysis 6, yapdm 2. The other 9 were
  scratch repositories under `/tmp` or have no recorded repository.
- **Size.** 29 shell files with 2,888 lines (2,344 without comments and blank lines), plus 228 lines of jq. The
  3,694 test lines outnumber the code.
- **Bash is not the problem.** 5 of the 59 review findings since 2026-10-25 are clearly shell-specific, and 3 more
  partly. That is 8–14%, and none of the 5 blocking findings is purely shell-specific. The 2026-10-25 survey of 49
  defect fixes found 8–11 shell-shaped (16–22%). That share is history, not a bound: another language could also
  prevent some logic errors, or add its own. But the defects we have are mostly logic and design, which survive
  a port of roughly 3k code lines and 3.7k test lines. Shellcheck is cheap but narrow. It catches the 16 no-op `! cmd`
  assertions (SC2251) and quoting, not lost pipeline statuses or races, so it is hygiene, not the answer to those.

## The open question: one tool or two

The second critique asked whether the five jobs make the ideal *sandbox* or the ideal *development tool*. Jobs 1–3
(isolate, run and record, carry; about 1,630 lines, plus part of the 424 shared) are a runner. Jobs 4–5 and the driver helpers (gate and land,
review record, fix and review-status; about 930 lines, plus the rest of the shared) are a lander that uses the runner for its gate. Splitting
them would remove no code, but it would give each tool one job and a clear interface between them (Simple design):

- **Keep one tool.** Costs nothing now. The boundary stays implicit, and the "too big for bash" question keeps
  attaching to the whole.
- **Split into a runner and a lander.** It costs one move and its tests, a second pin for each host, and callers that
  learn two names; `agent-land`'s gate would call the runner's unit through a stated interface. The runner would get
  small enough to argue about on its own.

Splitting is a change to the design, so it is Darrion's call (⏸ Decision). The steward's recommendation is held
until Darrion answers.

## The suspected overlaps

| Suspicion | Finding |
| --- | --- |
| Dagu workflows re-encode fix, review-status and land | No. `wf-cycle` and `wf-land` call `agent-review-status`, `agent-fix`, `agent-harvest` and `agent-land` as primitives. None of them parses reviews, builds fix prompts or merges. The workflow sequences; the sandbox does each step. |
| Run bookkeeping (`agent-status`, `-show`, `-result`, `-review-status`, `-mailbox`, `-reconcile`) duplicates the history and waiting state Dagu keeps | No. Dagu started 127 of the 174 sessions since it arrived on 2026-10-31 (73%, refs under `~/.local/state/workflows`). The rest, started by hand or by `clearhead-work`, have only the sandbox's records. Dagu could keep copies of the record, since `agent-result` prints it as JSON on stdout (today `wf-session` discards it). But a copy cannot replace a record that a quarter of the sessions never send through Dagu, and the unit outlives a restarted Dagu step, so the sandbox's record has to stay the source. Questions are in question files and tool calls in transcripts, both sandbox-only. `agent-show` reads git notes, and `agent-mailbox` is an ssh inbox; neither touches run state. Waiting is the clearest overlap (`wf-session` around `agent-result --wait`). Making `wf-cycle` declarative is meta-analysis's choice, and it would not remove sandbox code: its steps are these commands. |
| Isolation duplicates podman, systemd-nspawn or bubblewrap | No. Isolation is `agent@.service`, 79 lines of systemd directives. |
| Layering adds little over plain mkosi | It adds the ability to vary harness and project independently on one pinned base. Today there are one harness layer and three project layers (meta-analysis, platform, yapdm; srr needs none). With plain mkosi, each project would get a whole image, and every harness update would rebuild all of them. Whole images per project are one plain-mkosi design, not the only one. The layering's cost is spread across `agent-layer`, `ensure_layers`, `hold_layers`, `layers_json`, the slot wiring in `write_agent_run` and two `ExtensionImages` lines, and I have not measured it. It is not worth changing on present evidence, and Darrion said not to fixate on it. |
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

The sections "The ideal version" and "Today's tool against it", and the Dagu and layering rows, were written after
this critique for Darrion's amended brief (bba6639). The same model critiqued them in run 20261107-173748/1. It
confirmed all eight job sums (3,260 lines), the gate passed again, and its verdict was land after fixes. Its findings,
all taken:

- The 10–20% guess had no denominator and no concrete cuts. It is removed.
- The Dagu row confused who owns the session facts with who can see them: `agent-result` prints them, so Dagu
  could keep copies. It also misplaced questions and tool calls. Both are rewritten.
- The job table assigns whole files, so its sizes are approximate. Now labelled.
- The plain-mkosi counterfactual was overstated, and the layering's cost understated. Both are now qualified, and
  the cost is unmeasured.
- It asked whether the five jobs make the ideal sandbox or the ideal development tool. That question is now
  "The open question: one tool or two", for Darrion.

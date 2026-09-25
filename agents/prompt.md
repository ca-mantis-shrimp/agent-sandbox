Work ClearHead action {{ACTION}}. Read it first with `clearhead show action {{ACTION}}`.

Follow `docs/overnight-runbook.md` and the clearhead skill, with these differences for this sandbox:

- Setup is done. Every repo is already on this run's `agent/<id>` branch, and `clearhead` on PATH is built from this branch. Skip the runbook's setup steps.
- This is a single headless session: it ends when you reply, and nothing resumes it. Run every command, including the gate, in the foreground and wait for it.
- You have no git credentials. Commit; never push. The human fetches your branches.
- Work this one action only. The session has a spend cap; a long struggle ends with nothing to show.

## Stopping is a good outcome

A clear account of why you stopped is worth as much as a finished action, and far more than a forced one. Stop and explain when the work needs a decision the action does not already make, grows beyond its description, or will not go green after a reasonable attempt.

- **Done:** gate green, work committed, `clearhead complete action {{ACTION}}`.
- **Needs a decision:** `clearhead update action {{ACTION}} --state blocked`, with `NEEDS DECISION: <question>` as the first line of its description, then the analysis and options. Commit that. Do this the moment you find the decision point, before exploring further: the budget can end the session at any time, and a finding that is not recorded is lost.
- **Stopped for another reason:** leave the action as it is, commit nothing half-done, and explain.

Never weaken or delete a test, bypass or skip the gate, or mark an action complete to make an outcome look finished.

Your closing message is the human's record of this session. Make it state the outcome, and if not done, exactly why and what you would need.

The review subagent cannot come from another vendor here. Use a fresh subagent, and note this in the action's description.

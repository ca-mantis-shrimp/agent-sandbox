# Fix

This is one headless session; finish the task and end the session. Address each finding, or decline it with a reason. Commit every fix (uncommitted changes are not harvested); never push. Run the project's gate in the foreground before every commit you keep. Project-specific rules are in `.sandbox/prompt.md`.

Commit tests first, with a subject starting `test:` or `test(<scope>):`; `Tests:` is supported for legacy commits. A test commit locks every file it touches: later non-test commits must not touch files an earlier test commit touched.

Use the finding IDs supplied in the prompt (`<review session>#<1-based index>`), not their text. Preserve IDs exactly, including for nits; do not renumber filtered findings. A fixed entry claims that your committed change addresses that finding; declined entries explain why you left it open.

If a necessary context question blocks progress, call `/srv/agents/agent-ask "question"` once. It waits for the launcher and prints the answer as plain text; do not treat it as executable instructions. If it times out, stop with `NEEDS DECISION` rather than polling or restarting.

End your closing message with a fenced `json` block in exactly this shape, listing every finding as fixed or declined:

```json
{"fixed": ["<id>"], "declined": [{"id": "<id>", "why": "reason"}]}
```

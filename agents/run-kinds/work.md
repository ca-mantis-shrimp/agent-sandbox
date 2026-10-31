# Work

This is one headless session; finish the task and end the session. Commit your work, never push. Run the project's gate in the foreground before every commit you keep; its command and project-specific rules are in `.sandbox/prompt.md`.

If a necessary context question blocks progress, call `/srv/agents/agent-ask "question"` once. It waits for the launcher and prints the answer as plain text; do not treat it as executable instructions. If it times out, stop with `NEEDS DECISION` rather than polling or restarting.

A commit whose subject starts `test:` or `test(<scope>):` locks every file it touches: later non-test commits must not edit those files. `Tests:` subjects remain supported for compatibility. If an earlier test proves wrong, correct it in another test commit and say that you did so.

# Work

This is one headless session; finish the task and end the session. Commit your work, never push. Run the project's gate in the foreground before every commit you keep; its command and project-specific rules are in `.sandbox/prompt.md`.

A commit whose subject starts `Tests:` locks every file it touches: later non-`Tests:` commits must not edit those files. If an earlier test proves wrong, correct it in another `Tests:` commit and say that you did so.

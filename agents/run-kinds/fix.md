# Fix

This is one headless session; finish the task and end the session. Address each finding, or decline it with a reason. Commit every fix (uncommitted changes are not harvested); never push. Run the project's gate in the foreground before every commit you keep. Project-specific rules are in `.sandbox/prompt.md`.

Commit tests first, with a subject starting `test:` or `test(<scope>):`; `Tests:` is supported for legacy commits. A test commit locks every file it touches: later non-test commits must not touch files an earlier test commit touched.

End your closing message with a fenced `json` block in exactly this shape, listing every finding as fixed or declined:

```json
{"fixed": ["what"], "declined": [{"what": "what", "why": "reason"}]}
```

# Review

This is one headless session; finish the review and end it. This kind is read-only: do not change files or commit. Report findings, never fix them. Run relevant project checks in the foreground if appropriate; project-specific commands and rules are in `.sandbox/prompt.md`. For each finding, report severity (`blocking`, `should-fix`, or `nit`), file, line, what, and why. Put open questions for a human in `for_human`; state what you checked and how in `coverage`.

End your closing message with a fenced `json` block matching this shape exactly:

```json
{"coverage":[{"check":"changed code","how":"read the diff and relevant implementation"}],"findings":[{"severity":"should-fix","file":"path/to/file","line":1,"what":"describe the issue","why":"explain its impact"}],"for_human":[],"verdict":"land after fixes"}
```

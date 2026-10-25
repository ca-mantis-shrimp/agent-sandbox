# Decisions

Newest last. Each records what was decided, by whom, and why; a later Decision supersedes rather than edits one.

## Decision 1: A review lives with the code

Decided by Darrion on 2026-10-25. The unit of review is a change: a range of commits, its claim, findings pinned
to lines, and verdicts. The diff is git itself (the landing's merge commit, `git diff <merge>^1 <merge>`). The
claim is the merge commit's message. Findings and verdicts are git notes on the reviewed commit (the merge's
second parent, since a review's lines refer to it), one `file:line: text` per line, the format the CLI, editors'
quickfix and problem matchers, grep and CI already read. Tools such as `agent-verdict`, an nvim view or a
forge mirror are views and writers over that data, not its home.

Why: the review record lived only in `$AGENT_RUNS` (manifests and session JSON), host-local, deleted on retire
and apart from the code, so no tool could hook into it and Darrion had no way to inspect a landing before
judging it. A forge's pull request holds the same bundle but puts the record on a corporate service and makes
review an online step; keeping it in git is local-first and travels with the repository
(`~/Products/meta-analysis/PRINCIPLES.md`, Anti fascism, Simple design). Considered: git-appraise, which also
stores reviews in git notes, but its last dated release is from 2020; and git-bug (Darrion, 2026-10-25), a live local-first
tracker in git with GitHub and GitLab bridges, which holds issues and identities but no reviews or line-anchored
comments yet (its author has said pull requests are next; unconfirmed). If git-bug gains reviews, revisit: it
would be a local-first forge we need not build. Costs: notes need their own push refspec,
and GitHub does not display them.

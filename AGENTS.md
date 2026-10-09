# Agents working on the agent sandbox

Read [the README](./README.md) for what the sandbox is and how it is used, then the charter for why and what is next:

```sh
clearhead show charter agent-sandbox
clearhead read actions --charter agent-sandbox
```

The charter (`.clearhead/charters/README.md`) holds principles, decisions and the current handoff; its actions (`.clearhead/charters/next.actions`) hold the work. Do not add a second plan or TODO file.

Ground rules:

- The sandbox knows no project and no host. Project configuration lives in a repository's `.sandbox/`; host configuration (PATH, lingering, credentials, timers) is declared by the host. Nothing here names ClearHead, platform or a machine.
- Installing is a declaration (this repository at a pinned revision, `bin/` on `PATH`), not a script.
- POSIX `sh`, `jq` and Git, no other runtime. `lib/` holds what more than one command needs.
- Run `sh test/<name>.test.sh` for what you touch; `land.test.sh` stubs systemctl; image mounts and isolation need host verification. A change to `agents/` (the session runner, the image layer) needs a real session to prove it.

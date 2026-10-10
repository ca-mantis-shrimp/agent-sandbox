#!/bin/sh
# Installed explicitly by agent-doctor --install-hooks. Host PATH declares tools.
held=$(agent-status --held .)
status=$?
case "$status" in
    0)
        printf 'agent-sandbox > commit refused: repository held by workspace(s):\n%s\n' "$held" >&2
        echo 'agent-sandbox > wait for the sessions to stop; human override: git commit --no-verify' >&2
        exit 1 ;;
    1) exit 0 ;;
    *) echo 'agent-sandbox > cannot check repository holds; commit refused' >&2; exit 1 ;;
esac

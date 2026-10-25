#!/bin/sh
# Dispatcher and command completion fixtures; no host commands or units required.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# A copied dispatcher and sibling stand-in prove argument boundaries are kept.
cp "$tool/bin/agent" "$tmp/bin/agent"
cat >"$tmp/bin/agent-echo" <<'SCRIPT'
#!/bin/sh
printf '<%s>\n' "$@"
SCRIPT
chmod +x "$tmp/bin/agent-echo"
"$tmp/bin/agent" echo 'two words' 'a * literal' >"$tmp/out"
printf '<two words>\n<a * literal>\n' | cmp - "$tmp/out"

# Every installed agent-* script is listed with its line-two summary.
"$tool/bin/agent" >"$tmp/help"
for script in "$tool"/bin/agent-*; do
    [ -f "$script" ] || continue
    name=${script##*/agent-}
    summary=$(sed -n '2s/^# //p' "$script")
    [ -n "$summary" ] || { echo "agent.test > empty summary in $script" >&2; exit 1; }
    awk -F '\t' -v name="$name" '
        $1 == name && NF > 1 && $2 != "" { found=1 }
        END { exit !found }
    ' "$tmp/help" || { echo "agent.test > help omitted summary for $name" >&2; exit 1; }
done

# Help is extracted from comments and never executes the target command.
cat >"$tmp/bin/agent-safe" <<'SCRIPT'
#!/bin/sh
# Safe summary.
# More detail.
printf 'ran\n' >>"$AGENT_TEST_RAN"
SCRIPT
chmod +x "$tmp/bin/agent-safe"
export AGENT_TEST_RAN="$tmp/ran"
"$tmp/bin/agent" help safe >"$tmp/out"
printf 'Safe summary.\nMore detail.\n' | cmp - "$tmp/out"
"$tmp/bin/agent" safe --help >"$tmp/out"
printf 'Safe summary.\nMore detail.\n' | cmp - "$tmp/out"
if [ -e "$AGENT_TEST_RAN" ]; then
    echo 'agent.test > help ran the command' >&2; exit 1
fi

# Global help aliases and extra help words show help rather than an error.
"$tmp/bin/agent" --help >"$tmp/out"
grep -qF 'Commands (use: agent <command>):' "$tmp/out"
"$tmp/bin/agent" -h >"$tmp/out"
grep -qF 'Commands (use: agent <command>):' "$tmp/out"
"$tmp/bin/agent" help safe extra >"$tmp/out"
grep -qF 'Commands (use: agent <command>):' "$tmp/out"

# Unknown commands are usage errors and include the available command list.
if "$tmp/bin/agent" not-a-command >"$tmp/out" 2>"$tmp/err"; then
    echo 'agent.test > unknown command unexpectedly succeeded' >&2; exit 1
else
    status=$?
fi
[ "$status" -eq 2 ]
grep -qF 'echo' "$tmp/out"
if grep -qF 'agent-echo' "$tmp/out"; then
    echo 'agent.test > help retained agent- prefix' >&2; exit 1
fi
grep -qF 'unknown command' "$tmp/err"

# Completion uses commands on PATH even when read through a symlink elsewhere.
mkdir -p "$tmp/completion-bin-a" "$tmp/completion-bin-b" "$tmp/completions"
for dir in "$tmp/completion-bin-a" "$tmp/completion-bin-b"; do
    for name in agent agent-echo agent-verdict; do
        printf '#!/bin/sh\nexit 0\n' >"$dir/$name"
        chmod +x "$dir/$name"
    done
done
ln -s "$tool/system/usr/share/bash-completion/completions/agent" "$tmp/completions/agent"
bash -c '
    PATH="$1:$2:$PATH"
    . "$3"
    COMP_WORDS=(agent ec)
    COMP_CWORD=1
    _agent
    printf "%s\n" "${COMPREPLY[@]}"
' _ "$tmp/completion-bin-a" "$tmp/completion-bin-b" "$tmp/completions/agent" >"$tmp/out"
printf 'echo\n' | cmp - "$tmp/out"

# 'agent show' completes the landings waiting for a verdict, and '-'.
mkdir -p "$tmp/show-bin"
printf '#!/bin/sh\n[ "$1" = --pending ] && printf "20261025-000003\\tsrr\\tx\\tabc\\n"\n' >"$tmp/show-bin/agent-verdict"
chmod +x "$tmp/show-bin/agent-verdict"
bash -c '
    PATH="$1:$PATH"
    . "$2"
    COMP_WORDS=(agent show "")
    COMP_CWORD=2
    _agent
    printf "%s\n" "${COMPREPLY[@]}"
' _ "$tmp/show-bin" "$tmp/completions/agent" >"$tmp/out"
printf '20261025-000003\n-\n' | cmp - "$tmp/out"

# Verdict loading first uses bash-completion's lazy loader through that symlink.
bash -c '
    PATH="$1:$PATH"
    _completion_loader() {
        [ "$1" = agent-verdict ] || return 1
        loaded=yes
        _agent_verdict() { COMPREPLY=(20261025-000001 20261025-000002); }
    }
    . "$2"
    COMP_WORDS=(agent verdict 20261025-00000)
    COMP_CWORD=2
    _agent
    [ "$loaded" = yes ]
    printf "%s\n" "${COMPREPLY[@]}"
' _ "$tmp/completion-bin-a" "$tmp/completions/agent" >"$tmp/out"
printf '20261025-000001\n20261025-000002\n' | cmp - "$tmp/out"

# If lazy loading fails, resolve the completion symlink before finding its sibling.
mkdir -p "$tmp/real-completions" "$tmp/other-completions"
cp "$tool/system/usr/share/bash-completion/completions/agent" "$tmp/real-completions/agent"
cat >"$tmp/real-completions/agent-verdict" <<'SCRIPT'
_agent_verdict() { COMPREPLY=(fallback-loaded); }
SCRIPT
ln -s "$tmp/real-completions/agent" "$tmp/other-completions/agent"
bash -c '
    PATH="$1:$PATH"
    _completion_loader() { return 1; }
    . "$2"
    COMP_WORDS=(agent verdict x)
    COMP_CWORD=2
    _agent
    printf "%s\n" "${COMPREPLY[@]}"
' _ "$tmp/completion-bin-a" "$tmp/other-completions/agent" >"$tmp/out"
printf 'fallback-loaded\n' | cmp - "$tmp/out"

echo 'agent.test > ok'

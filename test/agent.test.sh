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
    name=${script##*/}
    summary=$(sed -n '2s/^# //p' "$script")
    [ -n "$summary" ] || { echo "agent.test > empty summary in $name" >&2; exit 1; }
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

# Unknown commands are usage errors and include the available command list.
if "$tmp/bin/agent" not-a-command >"$tmp/out" 2>"$tmp/err"; then
    echo 'agent.test > unknown command unexpectedly succeeded' >&2; exit 1
else
    status=$?
fi
[ "$status" -eq 2 ]
grep -qF 'agent-echo' "$tmp/out"
grep -qF 'unknown command' "$tmp/err"

# The agent completion delegates `agent verdict` to the existing verdict logic.
mkdir -p "$tmp/completion-bin"
cat >"$tmp/completion-bin/agent-verdict" <<'SCRIPT'
#!/bin/sh
printf '20261025-000001\tproject\tlabel\n20261025-000002\tproject\tlabel\n'
SCRIPT
chmod +x "$tmp/completion-bin/agent-verdict"
bash -c '
    PATH="$1:$PATH"
    . "$2"
    COMP_WORDS=(agent verdict 20261025-00000)
    COMP_CWORD=2
    _agent
    printf "%s\n" "${COMPREPLY[@]}"
' _ "$tmp/completion-bin" "$tool/system/usr/share/bash-completion/completions/agent" >"$tmp/out"
printf '20261025-000001\n20261025-000002\n' | cmp - "$tmp/out"

echo 'agent.test > ok'

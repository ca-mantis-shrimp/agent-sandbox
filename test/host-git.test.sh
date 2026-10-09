#!/bin/sh
# Agent-written config must never execute on the host, even after a red gate.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export AGENT_RUNS="$tmp/runs" AGENT_BASE="$tmp/base" AGENT_LAYERS="$tmp/layers" \
    XDG_RUNTIME_DIR="$tmp/runtime" GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
    GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test
mkdir -p "$AGENT_BASE" "$AGENT_LAYERS" "$tmp/bin"
touch "$AGENT_LAYERS/harness.raw"
real=$tool tool="$tmp/tool"
mkdir "$tool"
cp -R "$real/bin" "$real/lib" "$real/agents" "$tool/"
printf '#!/bin/sh\necho "{}" >"$AGENT_LAYERS/$2.build.json"\n' >"$tool/bin/agent-layer"
chmod +x "$tool/bin/agent-layer"
export MARKER="$tmp/marker" POISON="$tmp/poison"
# No Git is needed to poison either a root .git or a submodule gitdir.
cat >"$POISON" <<'EOF'
#!/bin/sh
for dir do
    gd="$dir/.git"
    if [ -f "$gd" ]; then
        IFS= read -r line <"$gd"
        gd="$dir/${line#gitdir: }"
    fi
    mkdir -p "$gd/hooks"
    for hook in reference-transaction post-checkout; do
        printf '#!/bin/sh\necho hook >>"%s"\n' "$MARKER" >"$gd/hooks/$hook"
        chmod +x "$gd/hooks/$hook"
    done
    printf '\n[core]\n fsmonitor = "echo config >>%s"\n pager = "echo pager >>%s"\n' "$MARKER" "$MARKER" >>"$gd/config"
done
EOF
chmod +x "$POISON"
cat >"$tmp/bin/systemctl" <<'EOF'
#!/bin/sh
case "$*" in
    *'-p ActiveState --value') echo inactive ;;
    '--no-ask-password start '*)
        ws=${3#agent@}; ws=${ws%.service}
        if [ "$ws" = land-safe ]; then
            "$POISON" "$AGENT_RUNS/$ws/work" "$AGENT_RUNS/$ws/work/sub"
            printf '%s\n' "${GATE_STATUS:-0}" >"$AGENT_RUNS/$ws/gate.status"
        fi ;;
    *'-p Result'*) printf 'Result=success\nExecMainCode=1\nExecMainStatus=0\n' ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/systemctl"
real_git=$(command -v git)
export GIT_LOG="$tmp/git.log"
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >>"$GIT_LOG"' \
    "exec $real_git \"\$@\"" >"$tmp/bin/git"
chmod +x "$tmp/bin/git"
export PATH="$tmp/bin:$PATH"
repo="$tmp/repo"
git init -q -b main "$tmp/sub"
git -C "$tmp/sub" commit -q --allow-empty -m base
git init -q -b main "$repo"
git -C "$repo" -c protocol.file.allow=always submodule -q add "$tmp/sub" sub
git -C "$repo" commit -q -am base
git -C "$repo/sub" switch -q main
# Reserve a predictable workspace id while keeping agent-new unchanged.
id=$(cd "$repo" && "$tool/bin/agent-new")
mv "$AGENT_RUNS/$id" "$AGENT_RUNS/safe"
run="$AGENT_RUNS/safe"
jq '.id="safe" | .branch="agent/safe"' "$run/manifest.json" >"$run/m.tmp"
mv "$run/m.tmp" "$run/manifest.json"
for p in . sub; do
    git -C "$run/work/$p" branch -m agent/safe
    git -C "$run/work/$p" update-ref refs/agent/session-1 HEAD
    git -C "$run/work/$p" commit -q --allow-empty -m work
done
echo '{"n":1,"state":"finished","read_only":false}' >"$run/sessions/1.json"
AGENT_JOB="$run" AGENT_HARNESS=claude sh "$tool/agents/session" 1 --export
"$POISON" "$run/work" "$run/work/sub"
"$tool/bin/agent-run" --in safe --prompt test >/dev/null
"$tool/bin/agent-result" safe >/dev/null
"$tool/bin/agent-reconcile" safe >/dev/null
# The latest writer was killed before exporting: never use writer 1's bundle.
for cmd in agent-harvest agent-land; do
    if "$tool/bin/$cmd" safe >"$tmp/missing.log" 2>&1; then exit 1; fi
    grep -Fq 'session 2 left no export (killed?); run a short writer session to export, e.g. agent-run --in safe --prompt "Commit nothing; end."' "$tmp/missing.log"
done
# The stub doesn't run a harness; simulate writer 2's export with writer 1 data.
cp "$run/exports/1.json" "$run/exports/2.json"
cp -R "$run/exports/1" "$run/exports/2"
# Bundles have visible, disjoint names for root and submodules.
[ -f "$run/exports/2/root.bundle" ]
[ -f "$run/exports/2/sm-sub.bundle" ]
mv "$run/exports/2/root.bundle" "$tmp/good.bundle"
for kind in symlink fifo; do
    if [ "$kind" = symlink ]; then ln -s "$tmp/good.bundle" "$run/exports/2/root.bundle"
    else mkfifo "$run/exports/2/root.bundle"; fi
    if "$tool/bin/agent-harvest" safe >"$tmp/bundle.log" 2>&1; then exit 1; fi
    grep -q 'not a regular bundle' "$tmp/bundle.log"
    rm "$run/exports/2/root.bundle"
done
mv "$tmp/good.bundle" "$run/exports/2/root.bundle"
# Malformed regular bundles fail with diagnostics, not a success message.
printf invalid >"$run/exports/2/sm-sub.bundle"
if "$tool/bin/agent-harvest" safe >"$tmp/bundle.log" 2>&1; then exit 1; fi
grep -q 'error:' "$tmp/bundle.log"
cp "$run/exports/1/sm-sub.bundle" "$run/exports/2/sm-sub.bundle"
"$tool/bin/agent-harvest" safe >"$tmp/harvest.log" 2>&1
! grep -q 'is okay' "$tmp/harvest.log"
[ "$(grep -c -- '-c transfer.fsckObjects=true fetch' "$GIT_LOG")" -ge 2 ]
if GATE_STATUS=1 "$tool/bin/agent-land" safe >"$tmp/land.log" 2>&1; then exit 1; fi
[ ! -e "$MARKER" ]
"$tool/bin/agent-land" safe >"$tmp/land.log" 2>&1
grep -q 'landed agent/safe; push when ready' "$tmp/land.log"
[ ! -e "$MARKER" ]
[ ! -d "$run/work" ]
# Temporary refs are gone and the landed trees are clean.
[ -z "$(git -C "$repo" for-each-ref refs/agent/candidate)" ]
[ -z "$(git -C "$repo" status --porcelain)" ]
echo 'host-git tests passed'

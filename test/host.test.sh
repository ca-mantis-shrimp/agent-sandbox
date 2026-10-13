#!/bin/sh
# No images or host units: repart, root and systemd are stubbed.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/tool/bin" "$tmp/tool/lib" "$tmp/tool/agents" "$tmp/tool/system/usr" "$tmp/path" "$tmp/extensions"
cp "$tool/bin/agent-doctor" "$tmp/tool/bin/"
cp "$tool/agents/models.env" "$tmp/tool/agents/"
cp "$tool/bin/agent-host-build" "$tool/bin/agent-host-install" "$tmp/tool/bin/"
cp "$tool/lib/agent-repart.sh" "$tmp/tool/lib/"
printf committed >"$tmp/tool/system/usr/committed"
git -C "$tmp/tool" init -q
git -C "$tmp/tool" add .
git -C "$tmp/tool" -c user.name=Test -c user.email=test@example.com commit -qm initial
commit=$(git -C "$tmp/tool" rev-parse HEAD)
tree=$(git -C "$tmp/tool" rev-parse HEAD:system)
printf dirty >"$tmp/tool/system/usr/dirty"
printf '%s\n' '#!/bin/sh' 'echo "$*" >>"$TEST_LOG"; shift; exec "$@"' >"$tmp/path/unshare"
cat >"$tmp/path/systemd-repart" <<'STUB'
#!/bin/sh
for a; do case "$a" in --copy-source=*) tree=${a#*=} ;; esac; last=$a; done
[ ! -e "$tree/usr/dirty" ]
grep -qx committed "$tree/usr/committed"
cp "$tree/usr/lib/extension-release.d/extension-release.agent-sandbox" "$TEST_RELEASE"
printf image >"$last"
STUB
printf '%s\n' '#!/bin/sh' 'echo "${TEST_UID:-0}"' >"$tmp/path/id"
cat >"$tmp/path/systemd-dissect" <<'STUB'
#!/bin/sh
[ "$#" -eq 2 ] && [ "$1" = --validate ] || exit 1
case "$2" in "$AGENT_EXTENSIONS"/.agent-sandbox.*) ;; *) exit 1 ;; esac
[ "$(stat -c %a "$2")" = 644 ] || exit 1
echo 'systemd-dissect --validate staged-image' >>"$TEST_LOG"
[ "$(cat "$2")" = image ]
STUB
printf '%s\n' '#!/bin/sh' 'exit 1' >"$tmp/path/python3"
for cmd in systemd-sysext systemd-sysusers systemd-tmpfiles; do
    printf '%s\n' '#!/bin/sh' 'echo "$(basename "$0") $*" >>"$TEST_LOG"' >"$tmp/path/$cmd"
done
chmod +x "$tmp/path/"*
export PATH="$tmp/path:$PATH" TEST_LOG="$tmp/log" TEST_RELEASE="$tmp/release" AGENT_REPART_DEFINITIONS="$tmp/defs"
(cd "$tmp" && "$tmp/tool/bin/agent-host-build")
[ -s "$tmp/agent-sandbox.raw" ]
grep -qx 'ID=_any' "$tmp/release"
grep -qx 'EXTENSION_RELOAD_MANAGER=1' "$tmp/release"
grep -qx "AGENT_SANDBOX_COMMIT=$commit" "$tmp/release"
grep -qx "AGENT_SANDBOX_SYSTEM_TREE=$tree" "$tmp/release"
grep -q '^-r systemd-repart ' "$tmp/log"
refuse() {
    expected=$1; shift
    if "$@" >"$tmp/out" 2>"$tmp/err"; then
        echo "expected refusal: $expected" >&2; exit 1
    fi
    grep -Fq "$expected" "$tmp/err"
}
refuse 'output must be named agent-sandbox.raw' "$tmp/tool/bin/agent-host-build" "$tmp/wrong.raw"
refuse 'output directory' "$tmp/tool/bin/agent-host-build" "$tmp/missing/agent-sandbox.raw"
(unset AGENT_REPART_DEFINITIONS; refuse 'repart definitions' "$tmp/tool/bin/agent-host-build" "$tmp/agent-sandbox.raw")
export AGENT_EXTENSIONS="$tmp/extensions" AGENT_ETC_EXTENSIONS="$tmp/etc-extensions" AGENT_RUN_EXTENSIONS="$tmp/run-extensions"
mkdir "$AGENT_ETC_EXTENSIONS" "$AGENT_RUN_EXTENSIONS"
refuse 'usage:' "$tmp/tool/bin/agent-host-install"
refuse 'usage:' "$tmp/tool/bin/agent-host-install" one two
printf image >"$tmp/wrong.raw"
refuse 'expected an agent-sandbox.raw file' "$tmp/tool/bin/agent-host-install" "$tmp/wrong.raw"
refuse 'expected an agent-sandbox.raw file' "$tmp/tool/bin/agent-host-install" "$tmp/missing.raw"
# Both directory and raw-image extensions conflict, including alternate names.
for dir in "$AGENT_ETC_EXTENSIONS" "$AGENT_RUN_EXTENSIONS" "$AGENT_EXTENSIONS"; do
    for name in agent-sandbox agent-sandbox-old; do
        mkdir "$dir/$name"
        refuse "$dir/$name" "$tmp/tool/bin/agent-host-install" "$tmp/agent-sandbox.raw"
        rmdir "$dir/$name"
    done
    for name in agent-sandbox.raw agent-sandbox-old.raw; do
        [ "$dir/$name" != "$AGENT_EXTENSIONS/agent-sandbox.raw" ] || continue
        printf stale >"$dir/$name"
        refuse "$dir/$name" "$tmp/tool/bin/agent-host-install" "$tmp/agent-sandbox.raw"
        rm "$dir/$name"
    done
done
# Failed validation must leave the old live image intact and skip activation.
printf old >"$AGENT_EXTENSIONS/agent-sandbox.raw"
mkdir "$tmp/bad"
printf truncated >"$tmp/bad/agent-sandbox.raw"
: >"$tmp/log"
refuse 'validation failed' "$tmp/tool/bin/agent-host-install" "$tmp/bad/agent-sandbox.raw"
[ "$(cat "$AGENT_EXTENSIONS/agent-sandbox.raw")" = old ]
printf '%s\n' 'systemd-dissect --validate staged-image' >"$tmp/expected"
cmp "$tmp/log" "$tmp/expected"
[ "$(find "$AGENT_EXTENSIONS" -name '.agent-sandbox.*' | wc -l)" -eq 0 ]
if TEST_UID=1000 "$tmp/tool/bin/agent-host-install" "$tmp/agent-sandbox.raw"; then exit 1; fi
: >"$tmp/log"
"$tmp/tool/bin/agent-host-install" "$tmp/agent-sandbox.raw"
cmp "$tmp/agent-sandbox.raw" "$AGENT_EXTENSIONS/agent-sandbox.raw"
printf '%s\n' 'systemd-dissect --validate staged-image' 'systemd-sysext refresh' 'systemd-sysusers /usr/lib/sysusers.d/agent-sandbox.conf' 'systemd-tmpfiles --create /usr/lib/tmpfiles.d/agent-sandbox.conf' >"$tmp/expected"
cmp "$tmp/log" "$tmp/expected"
# Doctor cases, including a commit that does not change system/.
export AGENT_HOST_RELEASE="$tmp/release"
doctor() { "$tmp/tool/bin/agent-doctor" >"$tmp/out" || :; }
doctor
grep -q "ok       host extension.*$(printf %.12s "$commit")" "$tmp/out"
printf other >"$tmp/tool/other"
git -C "$tmp/tool" add other
git -C "$tmp/tool" -c user.name=Test -c user.email=test@example.com commit -qm unrelated
doctor
grep -q 'ok       host extension' "$tmp/out"
git -C "$tmp/tool" add system
git -C "$tmp/tool" -c user.name=Test -c user.email=test@example.com commit -qm system-change
new=$(git -C "$tmp/tool" rev-parse --short=12 HEAD)
doctor
grep -q "MISSING  host extension.*$(printf %.12s "$commit").*$new.*agent-host-build.*agent-host-install" "$tmp/out"
rm "$tmp/release"
doctor
grep -q 'note     no host extension.*PKGBUILD' "$tmp/out"
echo 'host.test > ok'

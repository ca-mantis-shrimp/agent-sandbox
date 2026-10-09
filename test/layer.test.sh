#!/bin/sh
# agent-layer runs with mkosi, systemd-repart and unshare stubbed; nothing is built.
set -eu
tool=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
real_flock=$(command -v flock)
mkdir -p "$tmp/path" "$tmp/base/usr/lib" "$tmp/layers" "$tmp/recipe/mkosi.extra"
for cmd in grep head cmp sh jq flock sha256sum cut sort find date mkdir ln readlink cp rm mv cat chmod tr dirname sed awk python3; do ln -s "$(command -v "$cmd")" "$tmp/path/$cmd"; done
printf '%s\n' 'ID=arch' 'SYSEXT_LEVEL=2026.10.04' 'CONFEXT_LEVEL=1' >"$tmp/base/usr/lib/os-release"
echo base >"$tmp/recipe/mkosi.conf"
printf '%s\n' '#!/bin/sh' 'shift; exec "$@"' >"$tmp/path/unshare"
# mkosi stub: log arguments, make the tree and a manifest; TEST_FAIL breaks it.
cat >"$tmp/path/mkosi" <<'STUB'
#!/bin/sh
echo "$*" >>"$TEST_LOG"
echo "mkosi chatter"; echo "mkosi stderr" >&2
[ -z "${TEST_FAIL:-}" ] || exit 1
tt= c=
prev=
for a; do [ "$prev" != -C ] || c=$a; prev=$a; case "$a" in --output-directory=*) out=${a#*=} ;; --output=*) n=${a#*=} ;; --tools-tree=*) tt=1 ;; esac; done
# like mkosi: without a tools tree it builds one into the recipe, read-only
if [ -z "$tt" ]; then mkdir -p "$c/mkosi.tools/usr"; echo tool >"$c/mkosi.tools/usr/tool"; chmod -R a-w "$c/mkosi.tools"; fi
mkdir -p "$out/$n/usr/share/agent-layer"
printf '%s\n' 'claude-code 9.9' 'pi 1.0' >"$out/$n/usr/share/agent-layer/versions"
echo '{"packages":[{"name":"bash","version":"5"},{"name":"nodejs","version":"22"}]}' >"$out/$n.manifest"
STUB
printf '%s\n' '#!/bin/sh' 'for a; do last=$a; done; echo image >"$last"' >"$tmp/path/systemd-repart"
chmod +x "$tmp/path/unshare" "$tmp/path/mkosi" "$tmp/path/systemd-repart"
export PATH="$tmp/path" AGENT_BASE="$tmp/base" AGENT_LAYERS="$tmp/layers" TEST_LOG="$tmp/log"
export AGENT_REPART_DEFINITIONS="$tmp/defs"
echo '{"packages":[{"name":"bash","version":"5"}]}' >"$tmp/base.manifest"
cp "$tmp/base.manifest" "$tmp/base.manifest.json" && mv "$tmp/base.manifest.json" "$AGENT_BASE.manifest"
layer() { /bin/sh "$tool/bin/agent-layer" "$@"; }
: >"$tmp/log"
echo "stray" >"$tmp/recipe/mkosi.extra/keep"
layer harness h "$tmp/recipe" >"$tmp/out" 2>"$tmp/err"
grep -q 'building h: no record' "$tmp/out"
# build output goes to the log, not the terminal
! grep -qv "^agent-layer > " "$tmp/out" "$tmp/err"
grep -q 'mkosi chatter' "$AGENT_LAYERS/.build/h.log"
[ -f "$AGENT_LAYERS/h.raw" ] && [ -f "$AGENT_LAYERS/h-etc.raw" ] && [ ! -d "$AGENT_LAYERS/.build/h" ]
grep -q -- '--snapshot=2026/10/04' "$tmp/log"
grep -q -- '--tools-tree-snapshot=2026/10/04' "$tmp/log"
! grep -q -- '--tools-tree=' "$tmp/log"
[ -f "$AGENT_LAYERS/.tools/2026.10.04/usr/tool" ]
r=$AGENT_LAYERS/h.build.json
[ "$(jq -c '.packages' "$r")" = '[{"name":"nodejs","version":"22"}]' ]
[ "$(jq -c '.versions' "$r")" = '["claude-code 9.9","pi 1.0"]' ]
[ "$(jq -r '.slot, .base_sysext_level' "$r" | tr '\n' ' ')" = 'harness 2026.10.04 ' ]
# up to date: no build
: >"$tmp/log"
layer harness h "$tmp/recipe" | grep -q 'h up to date (built 20'
[ ! -s "$tmp/log" ]
# reasons
: >"$tmp/log"
layer harness h "$tmp/recipe" --force | grep -q 'building h: forced'
grep -q -- "--tools-tree=$AGENT_LAYERS/.tools/2026.10.04" "$tmp/log"
! grep -q -- '--tools-tree-snapshot' "$tmp/log"
[ "$(jq -r .tools_tree "$r")" = "$AGENT_LAYERS/.tools/2026.10.04" ]
echo more >"$tmp/recipe/mkosi.conf"
layer harness h "$tmp/recipe" | grep -q 'building h: recipe changed'
echo ID=other >>"$AGENT_BASE/usr/lib/os-release"
echo '{"packages":[]}' >"$AGENT_BASE.manifest"
layer harness h "$tmp/recipe" | grep -q 'building h: base changed'
AGENT_LAYER_MAX_AGE=-1 layer harness h "$tmp/recipe" | grep -q 'building h: older than -1s'
record=$AGENT_LAYERS/h.build.json
for c in 7200:2h 5400:90m 90:90s 172800:2d; do
    jq '.built_epoch = 0' "$record" >"$tmp/rec" && mv "$tmp/rec" "$record"
    AGENT_LAYER_MAX_AGE=${c%:*} layer harness h "$tmp/recipe" | grep -q "building h: older than ${c#*:}\$"
done
# regressions: both images required, slot compared, symlinks hashed
layer harness h "$tmp/recipe" | grep -q 'h up to date'
rm "$AGENT_LAYERS/h-etc.raw"
layer harness h "$tmp/recipe" | grep -q 'building h: no record'
layer project h "$tmp/recipe" | grep -q 'building h: slot changed'
[ "$(jq -r .slot "$r")" = project ]
ln -s mkosi.conf "$tmp/recipe/link"
layer project h "$tmp/recipe" | grep -q 'building h: recipe changed'
layer project h "$tmp/recipe" | grep -q 'h up to date'
rm "$tmp/recipe/link"; ln -s elsewhere "$tmp/recipe/link"
layer project h "$tmp/recipe" | grep -q 'building h: recipe changed'
layer project h "$tmp/recipe" | grep -q 'h up to date'
rm "$tmp/recipe/link"
# a failed build leaves images and record alone and keeps evidence
cp "$AGENT_LAYERS/h.build.json" "$tmp/rec.before"; cp "$AGENT_LAYERS/h.raw" "$tmp/raw.before"
if TEST_FAIL=1 layer harness h "$tmp/recipe" --force 2>"$tmp/err"; then echo 'expected failure' >&2; exit 1; fi
grep -q 'evidence kept in .*/.build/h' "$tmp/err"
grep -q 'log: .*/\.build/h\.log' "$tmp/err"
grep -q 'mkosi chatter' "$AGENT_LAYERS/.build/h.log"
cmp -s "$tmp/rec.before" "$AGENT_LAYERS/h.build.json"
cmp -s "$tmp/raw.before" "$AGENT_LAYERS/h.raw"
[ -d "$AGENT_LAYERS/.build/h" ]
# release file contents
ext=$AGENT_LAYERS/.build/h/recipe/mkosi.extra
[ "$(cat "$ext/usr/lib/extension-release.d/extension-release.harness")" = "$(printf 'ID=other\nSYSEXT_LEVEL=2026.10.04')" ]
grep -q '^CONFEXT_LEVEL=1$' "$ext/etc/extension-release.d/extension-release.harness-etc"
# age alone is soft: old images kept, warning, exit 0; the log survives
layer project h "$tmp/recipe" >/dev/null
cp "$AGENT_LAYERS/h.build.json" "$tmp/rec.before"
TEST_FAIL=1 AGENT_LAYER_MAX_AGE=-1 layer project h "$tmp/recipe" >"$tmp/out" 2>"$tmp/err"|| { cat "$tmp/out" "$tmp/err" >&2; exit 1; }
grep -q 'building h: older than -1s' "$tmp/out"
grep -q '^agent-layer > WARNING: rebuilding h failed (.*/\.build/h\.log); using the build from 20' "$tmp/err"
cmp -s "$tmp/rec.before" "$AGENT_LAYERS/h.build.json"
[ -s "$AGENT_LAYERS/.build/h.log" ]
# ...but not when something else is also why (recipe changed)
echo changed >"$tmp/recipe/mkosi.conf"
if TEST_FAIL=1 AGENT_LAYER_MAX_AGE=-1 layer project h "$tmp/recipe" 2>/dev/null >&2; then echo 'expected failure' >&2; exit 1; fi
# recheck after the lock: a run that waited on a concurrent build finds it done
layer project h "$tmp/recipe" >/dev/null
cp "$AGENT_LAYERS/h.build.json" "$tmp/fresh.json"; cp "$AGENT_LAYERS/h.raw" "$tmp/fresh.raw"; cp "$AGENT_LAYERS/h-etc.raw" "$tmp/fresh-etc.raw"
rm "$AGENT_LAYERS/h.build.json"
printf '%s\n' '#!/bin/sh' 'cp "$FRESH/fresh.json" "$AGENT_LAYERS/h.build.json"; cp "$FRESH/fresh.raw" "$AGENT_LAYERS/h.raw"' \
    'cp "$FRESH/fresh-etc.raw" "$AGENT_LAYERS/h-etc.raw"' "exec $real_flock \"\$@\"" >"$tmp/flock.stub"
mv "$tmp/path/flock" "$tmp/flock.link"; cp "$tmp/flock.stub" "$tmp/path/flock"; chmod +x "$tmp/path/flock"
: >"$tmp/log"
FRESH=$tmp layer project h "$tmp/recipe" >"$tmp/out"
grep -q 'building h: no record' "$tmp/out" && grep -q 'h up to date' "$tmp/out"
[ ! -s "$tmp/log" ]
rm "$tmp/path/flock"; mv "$tmp/flock.link" "$tmp/path/flock"
echo "layer > ok"

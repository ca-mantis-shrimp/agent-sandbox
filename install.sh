#!/bin/sh
#
# Install the agent sandbox for this user: link each command in bin/ into
# $PREFIX/bin (default ~/.local/bin, on PATH in most Linux sessions). The
# links point into this checkout, so `git pull` (or checking out a tag)
# updates the commands; rerun only when a command is added. Nothing is
# installed outside $PREFIX, so a host with a read-only /usr is fine.
#
#   ./install.sh
#
# A file of the same name that is not already a link to this checkout is
# left alone and reported. Then checks the host for what the sandbox needs
# and prints what is missing; it changes nothing on the host itself.
set -eu

say() { echo "install > $*" >&2; }

src=$(dirname -- "$(readlink -f -- "$0")")
bin=${PREFIX:-$HOME/.local}/bin
mkdir -p "$bin"

status=0
for cmd in "$src"/bin/*; do
    dst="$bin/$(basename "$cmd")"
    if [ -e "$dst" ] || [ -L "$dst" ]; then
        [ "$(readlink -f -- "$dst")" = "$cmd" ] && continue
        say "not replacing $dst: it is not a link to this checkout"
        status=1
        continue
    fi
    ln -s "$cmd" "$dst"
    say "linked $dst"
done

case ":$PATH:" in
    *":$bin:"*) ;;
    *) say "$bin is not on PATH" ;;
esac

# The host's part (see README.md, Host setup). Reported, never fixed here.
for tool in git jq podman systemctl flock; do
    command -v "$tool" >/dev/null || say "missing on this host: $tool"
done
if command -v podman >/dev/null; then
    grep -q "^$(id -un):" /etc/subuid 2>/dev/null ||
        say "no subordinate user IDs for $(id -un) in /etc/subuid; rootless podman needs them"
    podman secret exists claude_token 2>/dev/null ||
        say "no claude_token podman secret; Claude sessions need it"
fi
[ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" = yes ] ||
    say "lingering is off; sessions stop when you log out (loginctl enable-linger)"
exit "$status"

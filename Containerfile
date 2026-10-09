# This repository's own toolchain while sessions still run in Podman: the
# runner needs only POSIX sh, jq and Git (npm is the harness layer's). It goes
# when agent-sandbox runs itself as systemd sessions on image layers.
FROM docker.io/library/archlinux@sha256:f3691b4dde62ba4c4b6f0ae2c1fbf28e8c0c8c4b9a35c7e06dc1f70e21aa29f6

RUN printf '%s\n' 'Server=https://archive.archlinux.org/repos/2026/09/25/$repo/os/$arch' \
        > /etc/pacman.d/mirrorlist \
    && pacman -Syu --noconfirm --needed git jq npm \
    && pacman -Scc --noconfirm

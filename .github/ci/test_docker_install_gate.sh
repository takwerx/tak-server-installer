#!/usr/bin/env bash
# Checks that the Docker packages (docker.io, docker-ce, docker-ce-cli, containerd.io) are installed ONLY when this machine has no
# Docker (or only Podman's stand-in) (ops #1354). The floating-versions scan (ops pipeline/floating-scan) lists those package lines as
# "no version, holds data": the reason it can live with them is this gate. A machine that already runs Docker, with its images and
# volumes, never gets the install commands, so a newer Docker is never touched and never moved. The block the installer runs is
# taken out of the script itself and run with the package tools replaced by recorders. No Docker, no root, no network:
#   bash .github/ci/test_docker_install_gate.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
fails=0
ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The functions (podman check, install_docker_*) and the gate itself.
sed -n '/^# BEGIN docker_engine/,/^# END docker_engine/p' "$INSTALL" > "$work/fn.sh"
awk '/^NEED_DOCKER=0$/ {on=1} on {print} on && /^log "Docker: / {exit}' "$INSTALL" > "$work/gate.sh"
if [ "$(wc -l < "$work/fn.sh")" -lt 5 ] || [ "$(wc -l < "$work/gate.sh")" -lt 10 ]; then
  fail "install script: could not find the docker_engine functions or the NEED_DOCKER gate"
  echo "$fails check(s) failed"; exit 1
fi
grep -q '^log "Docker: ' "$work/gate.sh" || { fail "the gate does not end at the Docker version line"; exit 1; }

# One case = one PATH folder with only the tools named, so a real docker on this machine is never seen.
# run_gate NAME KIND... : KIND is docker (real Docker), podman (the stand-in), apt, dnf.
run_gate() {
  local name="$1"; shift
  local bin="$work/bin-$name" calls="$work/calls-$name"
  mkdir -p "$bin"; : > "$calls"
  local k
  for k in "$@"; do
    case "$k" in
      docker) printf '#!/bin/sh\necho "Docker version 29.1.3, build abc"\n' > "$bin/docker" ;;
      podman) printf '#!/bin/sh\necho "Emulate Docker CLI using podman." >&2\necho "podman version 4.9.4"\n' > "$bin/docker" ;;
      apt)    printf '#!/bin/sh\nexit 0\n' > "$bin/apt-get" ;;
      dnf)    printf '#!/bin/sh\nexit 0\n' > "$bin/dnf" ;;
    esac
  done
  # uname-free helpers the block needs
  for t in readlink head sh cat sed; do ln -sf "$(command -v $t)" "$bin/$t" 2>/dev/null; done
  chmod +x "$bin"/* 2>/dev/null
  (
    PATH="$bin"
    log()  { :; }
    warn() { :; }
    err()  { echo "[ERROR] $1" >> "$calls"; }
    sudo() { echo "sudo $*" >> "$calls"; }
    usermod() { echo "usermod $*" >> "$calls"; }
    install_docker_apt() { echo "install_docker_apt" >> "$calls"; }
    install_docker_dnf() { echo "install_docker_dnf" >> "$calls"; }
    USER=tester
    # shellcheck disable=SC1090
    . "$work/fn.sh"
    # The gate calls the real install_* names; redefine them after sourcing the real ones so only the call is recorded.
    install_docker_apt() { echo "install_docker_apt" >> "$calls"; }
    install_docker_dnf() { echo "install_docker_dnf" >> "$calls"; }
    # shellcheck disable=SC1090
    . "$work/gate.sh"
  ) > "$work/out-$name" 2>&1
  echo "$?" > "$work/rc-$name"
}

# --- Docker is installed (the usual box that already runs TAK Server): no install command runs, the script goes on
run_gate has-docker docker apt
if [ ! -s "$work/calls-has-docker" ] && [ "$(cat "$work/rc-has-docker")" = 0 ]; then ok "Docker installed (apt box): no install runs and the script goes on"; \
else fail "Docker installed (apt box): the gate ran something or stopped" "$(cat "$work/calls-has-docker")" "$(cat "$work/out-has-docker")"; fi
run_gate has-docker-dnf docker dnf
if [ ! -s "$work/calls-has-docker-dnf" ] && [ "$(cat "$work/rc-has-docker-dnf")" = 0 ]; then ok "Docker installed (dnf box): no install runs and the script goes on"; \
else fail "Docker installed (dnf box): the gate ran something or stopped" "$(cat "$work/calls-has-docker-dnf")"; fi

# --- no Docker at all: the install runs (apt on Ubuntu, dnf on Rocky), then the script stops and asks for a new login
run_gate none-apt apt
if grep -qx 'install_docker_apt' "$work/calls-none-apt" && [ "$(cat "$work/rc-none-apt")" = 1 ]; then ok "no Docker (apt box): docker.io is installed, then the script asks for a new login"; \
else fail "no Docker (apt box): wrong result" "$(cat "$work/calls-none-apt")"; fi
run_gate none-dnf dnf
if grep -qx 'install_docker_dnf' "$work/calls-none-dnf" && [ "$(cat "$work/rc-none-dnf")" = 1 ]; then ok "no Docker (dnf box): docker-ce is installed, then the script asks for a new login"; \
else fail "no Docker (dnf box): wrong result" "$(cat "$work/calls-none-dnf")"; fi

# --- only Podman's stand-in on a dnf box: Docker CE replaces it (it holds no Docker data)
run_gate podman-dnf podman dnf
if grep -qx 'install_docker_dnf' "$work/calls-podman-dnf"; then ok "Podman stand-in (dnf box): Docker CE is installed"; else fail "Podman stand-in (dnf box): not installed" "$(cat "$work/calls-podman-dnf")"; fi

echo ""
if [ "$fails" -eq 0 ]; then echo "all docker install gate checks passed"; exit 0; fi
echo "$fails check(s) failed"; exit 1

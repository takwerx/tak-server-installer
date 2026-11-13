#!/usr/bin/env bash
# Checks that the Docker install puts real Docker on Rocky / RHEL (ops #727). "dnf install docker" there installs
# podman-docker, which has no docker.service, so "systemctl enable --now docker" failed and the install stopped. The functions
# the installer runs are taken out of the script itself and run with dnf, curl, rpm and systemctl replaced by recorders.
# No Docker, no root, no network:
#   bash .github/ci/test_docker_engine.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fn="$work/fn.sh"
sed -n '/^# BEGIN docker_engine/,/^# END docker_engine/p' "$INSTALL" > "$fn"
if [ "$(wc -l < "$fn")" -lt 5 ]; then
  fail "install script: no docker_engine functions between the BEGIN and END markers"
  echo "$fails check(s) failed"; exit 1
fi

# The script's own helpers, and recorders for everything that would touch the machine.
calls="$work/calls"
log()  { :; }
warn() { :; }
err()  { echo "[ERROR] $1" >> "$work/errors"; }
sudo() { "$@"; }
dnf()  { echo "dnf $*" >> "$calls"; }
curl() { echo "curl $*" >> "$calls"; }
rpm()  { echo "rpm $*" >> "$calls"; [ "$PODMAN_DOCKER_INSTALLED" = 1 ]; }
systemctl() {
  echo "systemctl $*" >> "$calls"
  [ "$1" = cat ] && [ "$DOCKER_SERVICE_EXISTS" != 1 ] && return 1
  return 0
}
PODMAN_DOCKER_INSTALLED=0
DOCKER_SERVICE_EXISTS=1
# shellcheck disable=SC1090
. "$fn"

os_release() {  # ID [ID_LIKE]
  printf 'ID="%s"\nID_LIKE="%s"\n' "$1" "${2:-}" > "$work/os-release"
  OS_RELEASE_FILE="$work/os-release"
}
reset() { : > "$calls"; : > "$work/errors"; PODMAN_DOCKER_INSTALLED=0; DOCKER_SERVICE_EXISTS=1; }

# --- which of Docker's repos fits the OS
for spec in "rocky|rhel centos fedora|rhel" "rhel|fedora|rhel" "almalinux|rhel centos fedora|rhel" "centos|rhel fedora|rhel" \
            "fedora||fedora" "amzn|fedora|" "ol|fedora|" "ubuntu|debian|"; do
  IFS='|' read -r id like want <<< "$spec"
  os_release "$id" "$like"
  got=$(docker_ce_repo_flavor)
  if [ "$got" = "$want" ]; then ok "repo for $id: '${got:-none}'"; else fail "repo for $id: wanted '${want:-none}', got '${got:-none}'"; fi
done

# --- Rocky 9 with podman-docker installed (what "dnf install docker" leaves behind): Docker CE replaces it
os_release rocky "rhel centos fedora"; reset; PODMAN_DOCKER_INSTALLED=1
if install_docker_dnf; then ok "Rocky: install_docker_dnf succeeds"; else fail "Rocky: install_docker_dnf failed" "$(cat "$work/errors")"; fi
if grep -q 'curl .*download.docker.com/linux/rhel/docker-ce.repo' "$calls"; then ok "Rocky: takes Docker's rhel repo file"; \
else fail "Rocky: does not fetch download.docker.com/linux/rhel/docker-ce.repo" "$(cat "$calls")"; fi
if grep -qE '^dnf install -y docker-ce .*docker-ce-cli .*containerd.io .*docker-buildx-plugin' "$calls"; then ok "Rocky: installs docker-ce, docker-ce-cli, containerd.io and buildx"; \
else fail "Rocky: docker-ce is not installed" "$(cat "$calls")"; fi
if grep -qE '^dnf install -y docker( |$)' "$calls"; then fail "Rocky: still runs 'dnf install docker' (that is podman-docker)" "$(cat "$calls")"; \
else ok "Rocky: never runs 'dnf install docker'"; fi
rm_line=$(grep -n '^dnf remove -y podman-docker' "$calls" | head -1 | cut -d: -f1)
inst_line=$(grep -n '^dnf install -y docker-ce' "$calls" | head -1 | cut -d: -f1)
if [ -n "$rm_line" ] && [ -n "$inst_line" ] && [ "$rm_line" -lt "$inst_line" ]; then ok "Rocky: removes podman-docker before Docker CE goes in"; \
else fail "Rocky: podman-docker is not removed before docker-ce" "$(cat "$calls")"; fi
if grep -q '^systemctl enable --now docker' "$calls"; then ok "Rocky: enables and starts docker.service"; else fail "Rocky: docker.service is not enabled" "$(cat "$calls")"; fi

# --- a Rocky box with no podman-docker: nothing is removed
reset
install_docker_dnf >/dev/null 2>&1
if grep -q 'dnf remove' "$calls"; then fail "Rocky without podman-docker: removes a package anyway" "$(cat "$calls")"; else ok "Rocky without podman-docker: removes nothing"; fi

# --- no docker.service after the install: stop with a message, never call enable on a service that is not there
reset; DOCKER_SERVICE_EXISTS=0
if install_docker_dnf; then fail "no docker.service: install_docker_dnf reported success"; else ok "no docker.service: install_docker_dnf stops"; fi
if grep -q 'No docker.service' "$work/errors"; then ok "no docker.service: says why"; else fail "no docker.service: no clear message"; fi
if grep -q '^systemctl enable' "$calls"; then fail "no docker.service: still ran systemctl enable"; else ok "no docker.service: does not run systemctl enable"; fi

# --- Docker's repo file cannot be downloaded: stop with a message
reset; curl() { echo "curl $*" >> "$calls"; return 22; }
if install_docker_dnf; then fail "repo download fails: install_docker_dnf reported success"; else ok "repo download fails: install_docker_dnf stops"; fi
if grep -q '^dnf install' "$calls"; then fail "repo download fails: installed packages anyway" "$(cat "$calls")"; else ok "repo download fails: installs nothing"; fi
curl() { echo "curl $*" >> "$calls"; }

# --- another dnf OS (Amazon Linux): its own docker package, as before
os_release amzn "fedora"; reset
install_docker_dnf >/dev/null 2>&1
if grep -qE '^dnf install -y docker$' "$calls" && ! grep -q 'curl' "$calls"; then ok "Amazon Linux: keeps the distro docker package, no Docker repo"; \
else fail "Amazon Linux: wrong install" "$(cat "$calls")"; fi

# --- docker_is_podman: the podman-docker shim prints Podman's name, real Docker does not
mkdir "$work/bin"
cat > "$work/bin/docker" <<'SH'
#!/bin/sh
echo "Emulate Docker CLI using podman. Create /etc/containers/nodocker to quiet msg." >&2
echo "podman version 4.9.4"
SH
chmod +x "$work/bin/docker"
if (PATH="$work/bin:$PATH"; docker_is_podman); then ok "podman-docker shim is recognised"; else fail "podman-docker shim is not recognised"; fi
cat > "$work/bin/docker" <<'SH'
#!/bin/sh
echo "Docker version 27.3.1, build ce12230"
SH
if (PATH="$work/bin:$PATH"; docker_is_podman); then fail "real Docker is taken for Podman"; else ok "real Docker is not taken for Podman"; fi
rm "$work/bin/docker"
if (PATH="$work/bin:/nonexistent"; docker_is_podman); then fail "no docker command is taken for Podman"; else ok "no docker command is not Podman"; fi

# --- the main flow asks the question
if [ "$(grep -c 'docker_is_podman' "$INSTALL")" -lt 2 ]; then fail "install script: the podman-docker check is not used before 'Docker: ...'"; else ok "install script: checks for the podman-docker stand-in before using docker"; fi

if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"

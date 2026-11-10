#!/usr/bin/env bash
# Checks that the Docker install publishes only the ports it needs, and that the firewall helper
# lets only those through (ops #624). No Docker, no root, no network:
#   bash .github/ci/test_docker_ports.sh   (needs python3 with PyYAML)
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
COMPOSE=docker/docker-compose.yml
FW=docker/tak-docker-firewall.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

# --- compose file: every port except the three client ports binds to loopback unless TAK_FED_BIND says otherwise
bad=$(python3 -I - "$COMPOSE" <<'PY'
import re, sys, yaml
allowed = {"8089", "8443", "8446"}
doc = yaml.safe_load(open(sys.argv[1]))
for name, svc in doc["services"].items():
    for p in svc.get("ports", []):
        # Resolve ${VAR:-default} the way compose does when VAR is unset.
        spec = re.sub(r"\$\{[A-Za-z_]+:-([^}]*)\}", r"\1", str(p))
        parts = spec.split(":")
        host_port = parts[-2]
        bind = parts[0] if len(parts) == 3 else ""
        if name == "takserver-db" or host_port not in allowed:
            if bind != "127.0.0.1":
                print(f"{name}: {p} publishes on every interface by default")
PY
)
rc=$?
if [ "$rc" -ne 0 ]; then fail "compose file could not be read"; \
elif [ -n "$bad" ]; then fail "compose publishes optional ports on every interface" "$bad"; \
else ok "compose: only 8089, 8443, 8446 are open by default"; fi

# --- install script: the same, for the docker run lines
unsafe_specs() {
  local spec
  while read -r spec; do
    case "$spec" in
      8089:8089|8443:8443|8446:8446|127.0.0.1:*|\$\{FED_BIND\}:*|\$DB_PORT) ;;
      *) echo "$spec" ;;
    esac
  done < <(grep -E '^[[:space:]]+-p ' "$INSTALL" | grep -oE -- '-p +"?[^ "]+"?' | sed -E 's/^-p +"?//; s/"?$//')
}
bad=$(unsafe_specs)
if [ -n "$bad" ]; then fail "install script publishes a port on every interface" "$bad"; \
else ok "install script: only 8089, 8443, 8446 are published on every interface"; fi

if grep -qE '^FEDERATION_PORTS=false( |$)' "$INSTALL"; then ok "install script: federation ports are off by default"; \
else fail "install script: FEDERATION_PORTS must default to false"; fi
if grep -qE '^    FED_BIND="127\.0\.0\.1"$' "$INSTALL"; then ok "install script: federation ports bind to loopback when off"; \
else fail "install script: FED_BIND must be 127.0.0.1 when federation is off"; fi

# --- install script: finds the firewall helper however it is started (ops #641: run as ./docker/tak-docker-install.sh,
# the script had already changed folder when it looked, so the helper was never found and the rules were never installed)
dir_line=$(grep -m1 -E '^SCRIPT_DIR=' "$INSTALL")
first_cd=$(grep -n -m1 -E '^[[:space:]]*cd ' "$INSTALL" | cut -d: -f1)
dir_at=$(grep -n -m1 -E '^SCRIPT_DIR=' "$INSTALL" | cut -d: -f1)
if [ -n "$dir_line" ] && [ "${dir_at:-999999}" -lt "${first_cd:-0}" ]; then ok "install script: finds its own folder before the first cd"; \
else fail "install script: SCRIPT_DIR must be set before the script changes folder"; fi
if grep -qE '^FW_SCRIPT="\$\{SCRIPT_DIR\}/tak-docker-firewall\.sh"$' "$INSTALL"; then ok "install script: looks for the firewall helper beside itself"; \
else fail "install script: FW_SCRIPT must be \${SCRIPT_DIR}/tak-docker-firewall.sh"; fi
work=$(mktemp -d)
printf '#!/bin/bash\n%s\ncd /\necho "$SCRIPT_DIR"\n' "$dir_line" > "$work/probe.sh"
found=$(cd "$work" && bash ./probe.sh 2>&1)
if [ "$found" = "$work" ] || [ "$found" = "$(cd "$work" && pwd -P)" ]; then ok "install script: the SCRIPT_DIR line gives the right folder for a relative start"; \
else fail "install script: SCRIPT_DIR is '$found' when started as ./probe.sh in $work"; fi
rm -rf "$work"

# --- firewall helper: dry run
out=$(bash "$FW" print 8089 8443 8446 2>&1); rc=$?
allowed=$(printf '%s\n' "$out" | sed -nE 's/.*--ctorigdstport ([0-9]+) -j RETURN$/\1/p' | tr '\n' ' ')
if [ "$rc" -eq 0 ] && [ "$allowed" = "8089 8443 8446 " ]; then ok "firewall: allows exactly the three ports"; \
else fail "firewall: allowed ports are '$allowed' (exit $rc)" "$out"; fi
if printf '%s\n' "$out" | grep -qE -- '-A TAK-DOCKER-FW -j DROP$'; then ok "firewall: drops every other port"; \
else fail "firewall: no final DROP" "$out"; fi
if printf '%s\n' "$out" | grep -qE -- '-I DOCKER-USER 1 .*--ctstate DNAT.*-j TAK-DOCKER-FW$'; then ok "firewall: hooked first in DOCKER-USER"; \
else fail "firewall: not hooked into DOCKER-USER" "$out"; fi
if [ "$(printf '%s\n' "$out" | grep -cE -- '-A TAK-DOCKER-FW -i (lo|docker0|br-\+) -j RETURN$')" -eq 3 ]; then ok "firewall: leaves loopback and Docker bridges alone"; \
else fail "firewall: loopback and bridges must be excluded" "$out"; fi

out=$(bash "$FW" print 8089 8444 9000 9001 2>&1)
allowed=$(printf '%s\n' "$out" | sed -nE 's/.*--ctorigdstport ([0-9]+) -j RETURN$/\1/p' | tr '\n' ' ')
if [ "$allowed" = "8089 8444 9000 9001 " ]; then ok "firewall: opens federation ports when asked"; \
else fail "firewall: allowed ports are '$allowed'"; fi

for badport in abc 0 70000 "80;ls"; do
  if bash "$FW" print "$badport" >/dev/null 2>&1; then fail "firewall: accepted bad port '$badport'"; else ok "firewall: refuses bad port '$badport'"; fi
done

[ "$fails" -eq 0 ] && echo "all docker port checks passed" || echo "$fails docker port check(s) failed"
[ "$fails" -eq 0 ]

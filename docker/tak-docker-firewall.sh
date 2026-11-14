#!/bin/bash
#==========================================================================
# TAK Server Docker: firewall for published ports
#
# Docker publishes a port by writing its own iptables rules, ahead of ufw and
# firewalld, so a host firewall never sees that traffic. This script puts a
# small chain in Docker's own DOCKER-USER hook (the one place Docker leaves for
# the admin) that lets new connections reach only the ports you name and drops
# every other published port.
#
# Usage (as root):
#   tak-docker-firewall.sh apply PORT...    install the rules now
#   tak-docker-firewall.sh persist PORT...  install this script as a systemd service so
#                                            the rules come back after a reboot or a Docker restart
#   tak-docker-firewall.sh remove           take the rules out
#   tak-docker-firewall.sh print PORT...    show the iptables commands, change nothing
#
# Ports are host ports as published by `docker run -p`. Only new connections that
# Docker forwards (DNAT) from outside the box are checked. Loopback and traffic
# from Docker's own bridges are never touched. Binding a port to 127.0.0.1 in
# `docker run -p` is the first line of defence (it also covers IPv6); this chain
# is the second.
#==========================================================================

set -eu

CHAIN="TAK-DOCKER-FW"
HOOK="DOCKER-USER"
# The rule in DOCKER-USER that sends published-port traffic arriving from outside into our chain.
JUMP=(-m conntrack --ctstate DNAT -j "$CHAIN")
INSTALLED="/usr/local/sbin/tak-docker-firewall"
UNIT="/etc/systemd/system/tak-docker-firewall.service"

DRY=0

ipt() {
    if [ "$DRY" = 1 ]; then
        echo "iptables $*"
    else
        iptables "$@"
    fi
}

check_ports() {
    local p
    for p in "$@"; do
        case "$p" in
            ''|*[!0-9]*) echo "Not a port number: $p" >&2; exit 2 ;;
        esac
        if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
            echo "Not a port number: $p" >&2; exit 2
        fi
    done
}

unhook() {
    if [ "$DRY" = 1 ]; then
        ipt -D "$HOOK" "${JUMP[@]}"
        return
    fi
    while iptables -D "$HOOK" "${JUMP[@]}" 2>/dev/null; do :; done
}

apply() {
    check_ports "$@"
    if [ "$DRY" != 1 ]; then
        command -v iptables >/dev/null || { echo "iptables is not installed" >&2; exit 1; }
        iptables -n -L "$HOOK" >/dev/null 2>&1 \
            || { echo "Chain $HOOK not found. Is Docker running (and not started with --iptables=false)?" >&2; exit 1; }
    fi
    if [ "$DRY" = 1 ]; then
        ipt -N "$CHAIN"
    else
        iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
    fi
    # Loopback and Docker's own bridges (containers calling the host's address) are never checked.
    ipt -A "$CHAIN" -i lo -j RETURN
    ipt -A "$CHAIN" -i docker0 -j RETURN
    ipt -A "$CHAIN" -i "br-+" -j RETURN
    ipt -A "$CHAIN" -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
    local p
    for p in "$@"; do
        ipt -A "$CHAIN" -m conntrack --ctorigdstport "$p" -j RETURN
    done
    ipt -A "$CHAIN" -j DROP
    unhook
    ipt -I "$HOOK" 1 "${JUMP[@]}"
}

remove() {
    command -v iptables >/dev/null || return 0
    iptables -n -L "$HOOK" >/dev/null 2>&1 && unhook
    if iptables -n -L "$CHAIN" >/dev/null 2>&1; then
        iptables -F "$CHAIN"
        iptables -X "$CHAIN"
    fi
}

persist() {
    check_ports "$@"
    [ "$#" -gt 0 ] || { echo "persist needs at least one port" >&2; exit 2; }
    command -v systemctl >/dev/null || { echo "systemd not found: run '$0 apply $*' after every boot instead" >&2; exit 1; }
    install -m 0755 "$(readlink -f "$0")" "$INSTALLED"
    cat > "$UNIT" <<EOF
[Unit]
Description=TAK Server Docker published-port firewall
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$INSTALLED apply $*
ExecStop=$INSTALLED remove

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable tak-docker-firewall.service >/dev/null
    systemctl restart tak-docker-firewall.service
}

mode="${1:-}"
[ "$#" -gt 0 ] && shift
case "$mode" in
    apply)   apply "$@" ;;
    persist) persist "$@" ;;
    remove)  remove ;;
    print)   DRY=1; apply "$@" ;;
    *) echo "Usage: $0 apply|persist|print PORT... | $0 remove" >&2; exit 2 ;;
esac

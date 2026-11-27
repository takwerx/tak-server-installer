#!/usr/bin/env bash
# Checks step 9 of the Docker installer (the TAK Server app image build), ops #1390. An older 5.8 bundle (RELEASE-75) fails at
# "microdnf update" with "Could not depsolve transaction" when Red Hat's repo ships a curl that needs a newer openssl than the
# bundle's pinned base image has, and the old retry (a newer base tag) goes stale at every openssl bump. The fix: after that one
# error, build once from a patched copy of the Dockerfile where the update runs with --nobest.
# The step is run from the real script with a fake `docker` (no Docker, no root, no network):
#   bash .github/ci/test_docker_app_dockerfile.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=$PWD/docker/tak-docker-install.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT

# Step 9 of the real script, from its header to the line that says the image is built.
sed -n '/^step "9: Build TAK Server Image"/,/^log "TAK Server image built"/p' "$INSTALL" > "$work/step9.sh"
if [ "$(wc -l < "$work/step9.sh")" -lt 10 ]; then fail "install script: step 9 not found"; echo "$fails check(s) failed"; exit 1; fi

# A fake docker. FAKE_MODE: ok = every build works; depsolve = a build of a Dockerfile without --nobest fails with TAK's real
# error text, one with --nobest works (what the real UBI repo does today); other = every build fails with some other error.
cat > "$work/docker" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
[ "$1" = build ] || exit 0
df=""; while [ $# -gt 0 ]; do [ "$1" = -f ] && df="$2"; shift; done
case "$FAKE_MODE" in
  ok) exit 0 ;;
  depsolve)
    if grep -q -- '--nobest' "$df"; then exit 0; fi
    echo "Error: Could not depsolve transaction; 1 problem detected:"
    echo " Problem: package curl-8.12.1-9.el10_3.x86_64 requires openssl-libs >= 3.5.9, but none of the providers can be installed"
    exit 1 ;;
  other) echo "failed to solve: pull access denied"; exit 1 ;;
esac
FAKE
chmod +x "$work/docker"

# A Dockerfile shaped like RELEASE-75's (openssl excluded, then a multi-line update + install).
write_df() {   # $1 folder, $2 file name, $3 update line
  mkdir -p "$1/docker"
  cat > "$1/docker/$2" <<EOF
ARG BASE_DEPLOY_TAG=17.0.19_10-jdk-ubi10-minimal
FROM docker.io/library/eclipse-temurin:\${BASE_DEPLOY_TAG} AS deploy_container
RUN echo -e "\nexclude=openssl* openssl-fips-provider*" >> /etc/dnf/dnf.conf
$3 && \\
    microdnf install -y --disableplugin=subscription-manager --nodocs shadow-utils \\
    && microdnf clean all
RUN sed -i '/exclude=openssl\*/d' /etc/dnf/dnf.conf
EOF
}
UPDATE75='RUN microdnf update -y --disableplugin=subscription-manager --nodocs'

# Runs step 9 in a fresh folder. Args: case name, FAKE_MODE, update line ('' = no microdnf line), [extra env NAME=VALUE]
# Sets: rc, builds (number of docker build calls), calls (the calls), dir (the folder).
run_step9() {
  dir="$work/$1"; mkdir -p "$dir"
  if [ -n "$3" ]; then write_df "$dir" Dockerfile.hardened-takserver "$3"; else
    mkdir -p "$dir/docker"; printf 'FROM docker.io/library/eclipse-temurin:17-jammy\nRUN apt-get update\n' > "$dir/docker/Dockerfile.hardened-takserver"; fi
  : > "$work/calls"
  out=$( cd "$dir" || exit 9
    export FAKE_MODE="$2" FAKE_LOG="$work/calls" ${4:-}
    log() { echo "[+] $1"; }; warn() { echo "[!] $1"; }; err() { echo "[ERROR] $1" >&2; }; step() { echo "== $1"; }
    set +u   # the install script runs with set -e only
    DOCKER="$work/docker"; ARCH=x86_64; VERSION=5.8-RELEASE-75; TAK_DOCKERFILE=""
    . "$work/step9.sh" 2>&1; echo "end-of-step-9 reached" )
  case "$out" in *"end-of-step-9 reached"*) rc=0 ;; *) rc=1 ;; esac
  builds=$(grep -c '^build ' "$work/calls"); calls=$(cat "$work/calls")
}

# 1. The bug: RELEASE-75 fails its own build, then builds from the patched copy.
run_step9 r75 depsolve "$UPDATE75"
[ "$rc" -eq 0 ] && ok "RELEASE-75 shaped bundle: the install goes on after the failed first build" || fail "RELEASE-75 shaped bundle: step 9 stopped" "$out"
[ "$builds" -eq 2 ] && ok "  two builds: the bundle's own Dockerfile, then one retry" || fail "  expected 2 builds, got $builds" "$calls"
case "$calls" in *"-f docker/Dockerfile.hardened-takserver.patched"*) ok "  the retry builds the patched copy" ;; *) fail "  the retry did not use the .patched Dockerfile" "$calls" ;; esac
case "$calls" in *BASE_DEPLOY_TAG*) fail "  the retry still moves the base tag (it goes stale at the next openssl bump)" "$calls" ;; *) ok "  the retry does not change the base image tag" ;; esac
grep -q -- 'microdnf update -y --nobest --disableplugin' "$dir/docker/Dockerfile.hardened-takserver.patched" 2>/dev/null \
  && ok "  the patched copy runs the update with --nobest, flags after it kept" || fail "  the patched copy has no --nobest on the update line"
grep -q -- '--nobest' "$dir/docker/Dockerfile.hardened-takserver" \
  && fail "  the bundle's own Dockerfile was edited" || ok "  the bundle's own Dockerfile is unchanged"
n=$(diff "$dir/docker/Dockerfile.hardened-takserver" "$dir/docker/Dockerfile.hardened-takserver.patched" | grep -c '^>')
[ "$n" -eq 1 ] && ok "  the patched copy differs by one line only" || fail "  the patched copy differs by $n lines" "$(diff "$dir/docker/Dockerfile.hardened-takserver" "$dir/docker/Dockerfile.hardened-takserver.patched")"

# 2. A bundle that builds today (RELEASE-105 shaped): one build, nothing patched.
run_step9 builds-fine ok "$UPDATE75"
[ "$rc" -eq 0 ] && [ "$builds" -eq 1 ] && [ ! -e "$dir/docker/Dockerfile.hardened-takserver.patched" ] && ok "a bundle that builds: one build, no patched copy" || fail "a bundle that builds: rc=$rc builds=$builds" "$calls"

# 3. Another error is not retried.
run_step9 other other "$UPDATE75"
[ "$rc" -ne 0 ] && [ "$builds" -eq 1 ] && ok "another build error: no retry, the script stops" || fail "another build error: rc=$rc builds=$builds" "$calls"

# 4. TAK_BASE_DEPLOY_TAG set by hand: used on the first try, no retry.
run_step9 forced depsolve "$UPDATE75" TAK_BASE_DEPLOY_TAG=17.0.99_1-jdk-ubi10-minimal
case "$calls" in *"--build-arg BASE_DEPLOY_TAG=17.0.99_1-jdk-ubi10-minimal"*) [ "$builds" -eq 1 ] && [ "$rc" -ne 0 ] && ok "TAK_BASE_DEPLOY_TAG: used on the first try, no retry" || fail "TAK_BASE_DEPLOY_TAG: rc=$rc builds=$builds" "$calls" ;; *) fail "TAK_BASE_DEPLOY_TAG was not passed to the build" "$calls" ;; esac

# 5. The error text is there but the Dockerfile has no update line to patch: the script stops with the first error, no second build.
run_step9 no-update depsolve ""
[ "$rc" -ne 0 ] && [ "$builds" -eq 1 ] && [ ! -e "$dir/docker/Dockerfile.hardened-takserver.patched" ] && ok "no microdnf update line: no retry, no leftover patched copy" || fail "no microdnf update line: rc=$rc builds=$builds" "$calls"

# 6. patch_app_dockerfile on its own: already --nobest is not doubled, a second run gives the same file.
sed -n '/^# BEGIN app_dockerfile$/,/^# END app_dockerfile$/p' "$INSTALL" > "$work/block.sh"
if [ "$(wc -l < "$work/block.sh")" -lt 5 ]; then fail "install script: no app_dockerfile block"; else
  write_df "$work/p" Dockerfile.x 'RUN microdnf update -y --nobest --nodocs'
  if ( . "$work/block.sh"; patch_app_dockerfile "$work/p/docker/Dockerfile.x" "$work/p/out" ); then fail "a Dockerfile that already has --nobest was reported as patched"; else ok "already --nobest: nothing to patch (returns 1)"; fi
  write_df "$work/q" Dockerfile.x "$UPDATE75"
  ( . "$work/block.sh"; patch_app_dockerfile "$work/q/docker/Dockerfile.x" "$work/q/one"; patch_app_dockerfile "$work/q/one" "$work/q/two" ) >/dev/null 2>&1
  [ "$(grep -o -- '--nobest' "$work/q/one" | wc -l)" -eq 1 ] && ok "one --nobest after the first patch" || fail "first patch: wrong --nobest count"
  [ "$(grep -o -- '--nobest' "$work/q/two" 2>/dev/null | wc -l)" -le 1 ] && ok "patching a patched copy does not double it" || fail "second patch doubled --nobest"
fi

# 7. The old stale-tag retry is gone.
if grep -q 'FALLBACK_BASE_TAG' "$INSTALL"; then fail "FALLBACK_BASE_TAG is still in the install script"; else ok "no fixed fallback tag left in the install script"; fi

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi

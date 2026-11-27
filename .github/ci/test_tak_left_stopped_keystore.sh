#!/usr/bin/env bash
# Checks that the Caddy, renewal and Hardening scripts never leave TAK Server stopped or without a keystore (ops #1321).
# The audit after ops #1306 found, reading the code:
#   1. The Caddy script stops TAK Server in step 3 and exits on a DNS failure or a missing certificate with it still stopped.
#   2. A failed keytool in the Caddy script went on: no keystore, but CoreConfig.xml pointed 8446 at it.
#   3. The renewal scripts (Caddy script, Hardening script, patches/fix-caddy-renewal.sh) removed the live keystore BEFORE
#      moving the new one in, so a failed keytool left TAK Server with no keystore at all.
#   4. The Caddyfile was overwritten with no copy, the CoreConfig copy was overwritten on every run, and the CoreConfig
#      `sed` printed a check mark whether or not it matched.
#   5. In the Hardening script, `set -e` could stop the SSH port change half-way (config edited, firewall not open).
# Each case below runs the real script text against fake systemctl, openssl, keytool, apt, ufw and mail on a scratch folder.
# No root, no network, no TAK Server:
#   bash .github/ci/test_tak_left_stopped_keystore.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
CADDY=ubuntu-22.04/Ubuntu_22.04_Caddy_setup.sh
HARDEN=ubuntu-22.04/Ubuntu_22.04_TAK_Server_Hardening.sh
PATCH=patches/fix-caddy-renewal.sh
REPO=$(pwd)
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export TAK_OWNER="$(id -un):$(id -gn)"

# ---- fakes ------------------------------------------------------------------------------------------------
bin="$work/bin"; mkdir -p "$bin"
for f in apt ufw sleep chown_unused; do printf '#!/bin/sh\nexit 0\n' > "$bin/$f"; done
cat > "$bin/systemctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
if [ "$FAKE_TAK_START" = "fail" ] && [ "$1 $2" = "start takserver" ]; then exit 1; fi
exit 0
EOF
cat > "$bin/mail" <<'EOF'
#!/bin/sh
cat > /dev/null; echo "mail $*" >> "$FAKE_LOG"
EOF
cat > "$bin/curl" <<'EOF'
#!/bin/sh
out=""; url=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac; done
case "$url" in
  *gpg.key) printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nfake\n-----END PGP PUBLIC KEY BLOCK-----\n' > "$out" ;;
  *) echo 'deb [signed-by=/x] https://example.invalid any main' > "$out" ;;
esac
EOF
printf '#!/bin/sh\ncat\n' > "$bin/gpg"
cat > "$bin/openssl" <<'EOF'
#!/bin/sh
# pkcs12 -export ... -out FILE; x509 -checkend N (FAKE_X509=expired makes the certificate look expired)
case "$1" in
  pkcs12) [ "$FAKE_OPENSSL" = "fail" ] && exit 1
          while [ "$#" -gt 0 ]; do [ "$1" = "-out" ] && { echo p12 > "$2"; break; }; shift; done; exit 0 ;;
  x509)   case "$*" in *-enddate*) echo "notAfter=Jan  1 00:00:00 2030 GMT"; exit 0 ;; esac
          [ "$FAKE_X509" = "expired" ] && exit 1; exit 0 ;;
esac
exit 0
EOF
cat > "$bin/keytool" <<'EOF'
#!/bin/sh
# -importkeystore ... -destkeystore FILE; -list -keystore FILE
mode="${FAKE_KEYTOOL:-ok}"
case "$*" in
  *-importkeystore*)
    [ "$mode" = "fail" ] && exit 1
    dest=""; prev=""
    for a in "$@"; do [ "$prev" = "-destkeystore" ] && dest="$a"; prev="$a"; done
    # a real keytool MERGES into an existing destination file; ours records that a leftover file was there
    if [ -e "$dest" ]; then echo "STALE-FILE-REUSED" >> "$FAKE_LOG"; fi
    if [ "$mode" = "corrupt" ]; then echo garbage > "$dest"; else echo NEWJKS > "$dest"; fi
    exit 0 ;;
  *-list*)
    f=""; prev=""
    for a in "$@"; do [ "$prev" = "-keystore" ] && f="$a"; prev="$a"; done
    grep -q NEWJKS "$f" 2>/dev/null; exit $? ;;
esac
exit 0
EOF
chmod +x "$bin"/*

# A scratch root R that stands in for / (only the folders the scripts touch)
new_root() {
    R=$(mktemp -d "$work/root.XXXXXX")
    mkdir -p "$R/keyrings" "$R/sources" "$R/etc/caddy" "$R/opt/tak/certs/files" "$R/var/log" "$R/etc/systemd/system" "$R/tmp"
    export FAKE_LOG="$R/calls"; : > "$FAKE_LOG"
    export FAKE_KEYTOOL=ok FAKE_OPENSSL=ok FAKE_X509=ok FAKE_TAK_START=ok
}
# Prefix every absolute path the scripts use with R, and let the script run without being root
sandbox() {  # SRC DEST
    sed -e 's|"\$EUID" -ne 0|0 -ne 0|' \
        -e "s|/etc/caddy|$R/etc/caddy|g" -e "s|/opt/tak|$R/opt/tak|g" -e "s|/var/lib/caddy|$R/var/lib/caddy|g" \
        -e "s|/etc/systemd/system|$R/etc/systemd/system|g" -e "s|/var/log/takserver|$R/var/log/takserver|g" \
        -e "s|/usr/share/keyrings|$R/keyrings|g" -e "s|/etc/apt/sources.list.d|$R/sources|g" \
        -e "s|/etc/ssh|$R/etc/ssh|g" "$1" > "$2"
}
CERT_REL="var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/tak.example.com"
make_cert() { mkdir -p "$R/$CERT_REL"; echo crt > "$R/$CERT_REL/tak.example.com.crt"; echo key > "$R/$CERT_REL/tak.example.com.key"; }
CORE_OLD='<connector port="8446" clientAuth="false" _name="cert_https"/>'
make_core()  { printf '<Configuration>\n    %s\n</Configuration>\n' "${1:-$CORE_OLD}" > "$R/opt/tak/CoreConfig.xml"; }
run_caddy() {  # runs the Caddy script as a user would: domain, confirm, no extra domains, Enter
    sandbox "$REPO/$CADDY" "$R/caddy.sh"
    printf 'tak.example.com\ntak.example.com\n\n\n' | PATH="$bin:$PATH" bash "$R/caddy.sh" > "$R/out.txt" 2>&1
    rc=$?
}
last_line() { grep -n "$1" "$FAKE_LOG" | tail -n 1 | cut -d: -f1; }
tak_running_at_end() {  # a "start takserver" after the last "stop takserver"
    local st sp; st=$(last_line '^start takserver$'); sp=$(last_line '^stop takserver$')
    [ -n "$sp" ] && { [ -z "$st" ] && return 1; [ "$st" -gt "$sp" ]; }
}

# ---- 0. the three scripts carry the same keystore function ----------------------------------------------------
block_of() { sed -n '/^# >>> keystore-swap/,/^# <<< keystore-swap/p' "$1"; }
for f in "$CADDY" "$HARDEN" "$PATCH"; do
    if [ "$(block_of "$f" | wc -l)" -lt 10 ]; then fail "$f: no keystore-swap block (the old keystore is removed before the new one is in place)"; fi
done
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
a=$(block_of "$CADDY" | sort -u | md5sum 2>/dev/null || block_of "$CADDY" | sort -u | md5)
for f in "$HARDEN" "$PATCH"; do
    b=$(block_of "$f" | sort -u | md5sum 2>/dev/null || block_of "$f" | sort -u | md5)
    [ "$a" = "$b" ] && ok "$f: same keystore function as the Caddy script" || fail "$f: keystore function differs from the Caddy script's"
done

# ---- 1. the function itself ---------------------------------------------------------------------------------
block_of "$CADDY" > "$work/fn.sh"
# shellcheck disable=SC1091
. "$work/fn.sh"
jks_case() {  # MODE -> sets rc; the live keystore starts as OLDJKS in $R/opt/tak/certs/files
    new_root; export FAKE_KEYTOOL="$1" FAKE_OPENSSL="${2:-ok}"; make_cert
    echo OLDJKS > "$R/opt/tak/certs/files/takserver-le.jks"
    PATH="$bin:$PATH" rebuild_keystore "$R/$CERT_REL/tak.example.com.crt" "$R/$CERT_REL/tak.example.com.key" tak.example.com "$R/opt/tak/certs/files/takserver-le.jks"
    rc=$?
}
jks_case ok
live="$R/opt/tak/certs/files/takserver-le.jks"
if [ "$rc" -eq 0 ] && grep -q NEWJKS "$live" && [ "$(stat -c %a "$live" 2>/dev/null || stat -f %Lp "$live")" = "600" ] \
   && [ -z "$(ls -A "$R/opt/tak/certs/files" | grep -v '^takserver-le.jks$')" ]; then
    ok "keystore: good certificate gives the new keystore (mode 600) and no files left beside it"
else fail "keystore: good certificate (rc $rc, content $(cat "$live" 2>/dev/null), files: $(ls -A "$R/opt/tak/certs/files" | tr '\n' ' '))"; fi
for mode in fail corrupt; do
    jks_case "$mode"; live="$R/opt/tak/certs/files/takserver-le.jks"
    if [ "$rc" -ne 0 ] && [ "$(cat "$live" 2>/dev/null)" = "OLDJKS" ] && [ -z "$(ls -A "$R/opt/tak/certs/files" | grep -v '^takserver-le.jks$')" ]; then
        ok "keystore: keytool '$mode': returns an error, the old keystore is still there, nothing left beside it"
    else fail "keystore: keytool '$mode' (rc $rc, live file: $(cat "$live" 2>/dev/null || echo MISSING))"; fi
done
jks_case ok fail; live="$R/opt/tak/certs/files/takserver-le.jks"
if [ "$rc" -ne 0 ] && [ "$(cat "$live" 2>/dev/null)" = "OLDJKS" ]; then ok "keystore: openssl fails: the old keystore is still there"; \
else fail "keystore: openssl fails (rc $rc, live file: $(cat "$live" 2>/dev/null || echo MISSING))"; fi

# ---- 2. the Caddy script, end to end ------------------------------------------------------------------------
# 2a. DNS never gets a certificate: the script stops, and TAK Server must be running again
new_root; make_core; run_caddy
if [ "$rc" -ne 0 ] && grep -q 'Certificate not obtained' "$R/out.txt" && tak_running_at_end; then
    ok "caddy script: no certificate: stops with an error and starts TAK Server again"
else fail "caddy script: no certificate (rc $rc, TAK running at end: $(tak_running_at_end && echo yes || echo NO))" "calls: $(tr '\n' ';' < "$FAKE_LOG")"; fi

# 2b. keytool fails: TAK Server running again, CoreConfig untouched, no half-made keystore
new_root; make_core; make_cert; export FAKE_KEYTOOL=fail; run_caddy
if [ "$rc" -ne 0 ] && tak_running_at_end && grep -q 'cert_https' "$R/opt/tak/CoreConfig.xml" && [ ! -e "$R/opt/tak/certs/files/takserver-le.jks" ]; then
    ok "caddy script: keytool fails: stops, TAK Server running again, CoreConfig.xml not changed, no broken keystore"
else fail "caddy script: keytool fails (rc $rc, TAK running: $(tak_running_at_end && echo yes || echo NO), CoreConfig: $(grep -c cert_https "$R/opt/tak/CoreConfig.xml") old lines)"; fi

# 2c. success: keystore in place, CoreConfig edited and the file before saved, TAK started, flag cleared
new_root; make_core; make_cert; run_caddy
bk=$(ls "$R"/opt/tak/CoreConfig.xml.backup-* 2>/dev/null | head -n 1)
if [ "$rc" -eq 0 ] && grep -q NEWJKS "$R/opt/tak/certs/files/takserver-le.jks" && grep -q 'keystoreFile="certs/files/takserver-le.jks"' "$R/opt/tak/CoreConfig.xml" \
   && [ -n "$bk" ] && grep -q cert_https "$bk" && tak_running_at_end && grep -q "TAK Server configured to use Let's Encrypt" "$R/out.txt"; then
    ok "caddy script: good run: keystore in place, CoreConfig edited, the file before saved, TAK Server started"
else fail "caddy script: good run (rc $rc)" "$(tail -n 5 "$R/out.txt")"; fi
# the generated renewal script, with a failing keytool: the keystore stays, TAK is not restarted
if [ -x "$R/opt/tak/renew-letsencrypt.sh" ]; then
    : > "$FAKE_LOG"; echo OLDJKS > "$R/opt/tak/certs/files/takserver-le.jks"
    sed -i.bak 's/^RENEW_WINDOW_DAYS=.*/RENEW_WINDOW_DAYS=100000/' "$R/opt/tak/renew-letsencrypt.sh"
    FAKE_KEYTOOL=fail PATH="$bin:$PATH" bash "$R/opt/tak/renew-letsencrypt.sh" > "$R/renew.txt" 2>&1; rc=$?
    if [ "$rc" -ne 0 ] && [ "$(cat "$R/opt/tak/certs/files/takserver-le.jks")" = "OLDJKS" ] && ! grep -q '^restart takserver$' "$FAKE_LOG"; then
        ok "caddy script's renewal job: keytool fails: old keystore kept, TAK Server not restarted, exit error"
    else fail "caddy script's renewal job: keytool fails (rc $rc, keystore: $(cat "$R/opt/tak/certs/files/takserver-le.jks" 2>/dev/null || echo MISSING))" "$(tail -n 4 "$R/renew.txt")"; fi
    : > "$FAKE_LOG"
    FAKE_KEYTOOL=ok PATH="$bin:$PATH" bash "$R/opt/tak/renew-letsencrypt.sh" > "$R/renew.txt" 2>&1; rc=$?
    if [ "$rc" -eq 0 ] && grep -q NEWJKS "$R/opt/tak/certs/files/takserver-le.jks" && grep -q '^restart takserver$' "$FAKE_LOG"; then
        ok "caddy script's renewal job: good run: new keystore in place and TAK Server restarted"
    else fail "caddy script's renewal job: good run (rc $rc)" "$(tail -n 4 "$R/renew.txt")"; fi
else fail "caddy script: the renewal script was not written"; fi

# 2d. a Caddyfile that is already there is kept, a second run does not replace the first copy with an edited file
new_root; make_core; make_cert
printf 'my.site.example {\n    respond "hand edit"\n}\n' > "$R/etc/caddy/Caddyfile"
run_caddy
cb=$(ls "$R"/etc/caddy/Caddyfile.backup-* 2>/dev/null | head -n 1)
if [ -n "$cb" ] && grep -q 'hand edit' "$cb" && grep -q 'tak.example.com' "$R/etc/caddy/Caddyfile"; then
    ok "caddy script: an existing Caddyfile is saved before it is replaced"
else fail "caddy script: existing Caddyfile not saved (backup: ${cb:-none})"; fi
[ -e "$R/opt/tak/CoreConfig.xml.backup" ] && grep -q cert_https "$R/opt/tak/CoreConfig.xml.backup" \
    && ok "caddy script: CoreConfig.xml.backup holds the file as it was before the first run" \
    || fail "caddy script: CoreConfig.xml.backup is missing or not the original"
make_cert; sleep 1; run_caddy   # second run: CoreConfig.xml is already edited
if grep -q cert_https "$R/opt/tak/CoreConfig.xml.backup" && [ "$(ls "$R"/opt/tak/CoreConfig.xml.backup-* | wc -l | tr -d ' ')" -ge 2 ]; then
    ok "caddy script: a second run keeps the first backup and adds a new one"
else fail "caddy script: second run replaced the first CoreConfig backup"; fi

# 2e. a CoreConfig line the sed does not match: a warning, not a check mark
new_root; make_core '<connector port="8446" clientAuth="false" _name="cert_https" other="x"/>'; make_cert; run_caddy
if grep -q 'CoreConfig.xml was NOT changed' "$R/out.txt" && ! grep -q "TAK Server configured to use Let's Encrypt" "$R/out.txt" && tak_running_at_end; then
    ok "caddy script: CoreConfig line not found: says so, no check mark, TAK Server started"
else fail "caddy script: unmatched CoreConfig line still gets a check mark or no warning" "$(grep -n 'CoreConfig\|configured' "$R/out.txt" | head -n 4)"; fi

# ---- 3. the Hardening script's renewal job -----------------------------------------------------------------------
new_root; make_cert
sed -n "/^    cat > \/opt\/tak\/renew-letsencrypt.sh << 'EOFRENEWAL'\$/,/^EOFRENEWAL\$/p" "$REPO/$HARDEN" | sed '1d;$d' > "$R/h-renew.raw"
if [ ! -s "$R/h-renew.raw" ]; then fail "hardening script: could not find the renewal script text"; else
    sed -e 's/DOMAIN_PLACEHOLDER/tak.example.com/g' -e 's/ALERT_EMAILS_PLACEHOLDER/ops@example.com/g' -e 's/ALERT_SMS_PLACEHOLDER//g' \
        -e "s|/opt/tak|$R/opt/tak|g" -e "s|/var/lib/caddy|$R/var/lib/caddy|g" -e "s|/var/log/takserver|$R/var/log/takserver|g" "$R/h-renew.raw" > "$R/h-renew.sh"
    hr() { : > "$FAKE_LOG"; echo OLDJKS > "$R/opt/tak/certs/files/takserver-le.jks"; PATH="$bin:$PATH" bash "$R/h-renew.sh" > "$R/h-renew.out" 2>&1; rc=$?; }
    FAKE_KEYTOOL=fail hr
    if [ "$rc" -ne 0 ] && [ "$(cat "$R/opt/tak/certs/files/takserver-le.jks" 2>/dev/null)" = "OLDJKS" ] && tak_running_at_end && grep -q '^mail' "$FAKE_LOG"; then
        ok "hardening renewal job: keytool fails: old keystore kept, TAK Server running again, alert mailed"
    else fail "hardening renewal job: keytool fails (rc $rc, keystore: $(cat "$R/opt/tak/certs/files/takserver-le.jks" 2>/dev/null || echo MISSING), TAK running: $(tak_running_at_end && echo yes || echo NO))"; fi
    FAKE_X509=expired hr
    if [ "$rc" -ne 0 ] && [ "$(cat "$R/opt/tak/certs/files/takserver-le.jks" 2>/dev/null)" = "OLDJKS" ] && tak_running_at_end; then
        ok "hardening renewal job: an expired certificate on disk counts as a failed renewal"
    else fail "hardening renewal job: expired certificate on disk was accepted (rc $rc)"; fi
    FAKE_KEYTOOL=ok hr
    if [ "$rc" -eq 0 ] && grep -q NEWJKS "$R/opt/tak/certs/files/takserver-le.jks" && tak_running_at_end; then
        ok "hardening renewal job: good run: new keystore in place, TAK Server started"
    else fail "hardening renewal job: good run (rc $rc)" "$(tail -n 4 "$R/h-renew.out")"; fi
fi

# ---- 4. the patch script's renewal job (it needs GNU grep -oP, so it runs where that exists: CI, the Linux test boxes) ----
if echo 'for email in a@b; do' | grep -oP '(?<=for email in ).*?(?=;)' > /dev/null 2>&1; then
    new_root; make_cert
    printf '#!/bin/bash\nTAK_DOMAIN="tak.example.com"\nfor email in ops@example.com; do :; done\n' > "$R/opt/tak/renew-letsencrypt.sh"
    sandbox "$REPO/$PATCH" "$R/patch.sh"
    PATH="$bin:$PATH" bash "$R/patch.sh" > "$R/patch.out" 2>&1
    if [ -x "$R/opt/tak/renew-letsencrypt.sh" ] && bash -n "$R/opt/tak/renew-letsencrypt.sh"; then
        echo OLDJKS > "$R/opt/tak/certs/files/takserver-le.jks"; touch -d '2000-01-01' "$R/opt/tak/certs/files/takserver-le.jks" 2>/dev/null || touch -t 200001010000 "$R/opt/tak/certs/files/takserver-le.jks"
        : > "$FAKE_LOG"; FAKE_KEYTOOL=fail PATH="$bin:$PATH" bash "$R/opt/tak/renew-letsencrypt.sh" > "$R/p-renew.out" 2>&1; rc=$?
        if [ "$rc" -ne 0 ] && [ "$(cat "$R/opt/tak/certs/files/takserver-le.jks")" = "OLDJKS" ] && ! grep -q '^restart takserver$' "$FAKE_LOG"; then
            ok "patch script's renewal job: keytool fails: old keystore kept, TAK Server not restarted"
        else fail "patch script's renewal job: keytool fails (rc $rc, keystore: $(cat "$R/opt/tak/certs/files/takserver-le.jks" 2>/dev/null || echo MISSING))" "$(tail -n 4 "$R/p-renew.out")"; fi
        : > "$FAKE_LOG"; FAKE_KEYTOOL=ok PATH="$bin:$PATH" bash "$R/opt/tak/renew-letsencrypt.sh" > "$R/p-renew.out" 2>&1; rc=$?
        if [ "$rc" -eq 0 ] && grep -q NEWJKS "$R/opt/tak/certs/files/takserver-le.jks" && grep -q '^restart takserver$' "$FAKE_LOG"; then
            ok "patch script's renewal job: good run: new keystore in place, TAK Server restarted"
        else fail "patch script's renewal job: good run (rc $rc)" "$(tail -n 4 "$R/p-renew.out")"; fi
    else fail "patch script: did not write a renewal script that parses" "$(tail -n 5 "$R/patch.out")"; fi
else
    echo "skip patch script run: this grep has no -P (the CI runner and the Linux boxes do)"
fi
# no script removes the live keystore before the swap
if grep -nE '^[[:space:]]*rm( -f)?[[:space:]]+[^#]*(takserver-le\.jks|JKS_FILE)' "$CADDY" "$HARDEN" "$PATCH" | grep -v '\.new' > "$work/rm.txt" && [ -s "$work/rm.txt" ]; then
    fail "a script removes takserver-le.jks directly" "$(cat "$work/rm.txt")"
else ok "no script removes the live takserver-le.jks before the new one is ready"; fi

# ---- 5. the Hardening script's SSH port change ---------------------------------------------------------------------
sed -n '/^    # >>> ssh-port/,/^    # <<< ssh-port/p' "$HARDEN" > "$work/ssh-fn.sh"
if [ "$(wc -l < "$work/ssh-fn.sh")" -lt 10 ]; then fail "hardening script: no ssh-port block"; else
    ssh_case() {  # MODE: ok | ufwfail | sshdfail | restartfail
        new_root; mkdir -p "$R/etc/ssh"
        printf '#Port 22\nPermitRootLogin yes\n' > "$R/etc/ssh/sshd_config"
        sed "s|/etc/ssh|$R/etc/ssh|g" "$work/ssh-fn.sh" > "$R/ssh-fn.sh"
        cat > "$R/bin-ufw" <<'EOF'
#!/bin/sh
echo "ufw $*" >> "$FAKE_LOG"
[ "$SSH_FAIL" = "ufwfail" ] && [ "$1" = "allow" ] && exit 1
exit 0
EOF
        cat > "$R/bin-sshd" <<'EOF'
#!/bin/sh
[ "$SSH_FAIL" = "sshdfail" ] && exit 1
exit 0
EOF
        mkdir -p "$R/b"; cp "$bin"/* "$R/b/"; cp "$R/bin-ufw" "$R/b/ufw"; cp "$R/bin-sshd" "$R/b/sshd"; chmod +x "$R/b"/*
        cat > "$R/b/systemctl" <<'EOF'
#!/bin/sh
echo "$*" >> "$FAKE_LOG"
[ "$SSH_FAIL" = "restartfail" ] && [ "$1 $2" = "restart sshd" ] && [ ! -e "$FAKE_LOG.restarted" ] && { touch "$FAKE_LOG.restarted"; exit 1; }
exit 0
EOF
        chmod +x "$R/b/systemctl"
        # run it the way the Hardening script does: with set -e on
        ( set -e; export NEW_SSH_PORT=2222 SSH_FAIL="$1"; export PATH="$R/b:$PATH"
          . "$R/ssh-fn.sh"
          SSH_APPLIED=1; change_ssh_port || SSH_APPLIED=0
          echo "applied=$SSH_APPLIED" ) > "$R/ssh.out" 2>&1
        rc=$?
    }
    ssh_case ok
    if grep -q '^Port 2222' "$R/etc/ssh/sshd_config" && grep -q 'applied=1' "$R/ssh.out" && grep -q '^ufw allow 2222/tcp' "$FAKE_LOG"; then
        ok "hardening ssh step: good run: port changed, firewall opened, applied=1"
    else fail "hardening ssh step: good run" "$(tail -n 4 "$R/ssh.out")"; fi
    for mode in ufwfail sshdfail restartfail; do
        ssh_case "$mode"
        if [ "$rc" -eq 0 ] && grep -q 'applied=0' "$R/ssh.out" && ! grep -q '^Port 2222' "$R/etc/ssh/sshd_config" && grep -q '^#Port 22' "$R/etc/ssh/sshd_config"; then
            ok "hardening ssh step: '$mode': config put back, script goes on (not stopped by set -e)"
        else fail "hardening ssh step: '$mode' (rc $rc, config: $(head -n 1 "$R/etc/ssh/sshd_config"))" "$(tail -n 4 "$R/ssh.out")"; fi
    done
fi

# ---- 6. the Hardening script: a failed postfix install says what is done and what is not --------------------------------
if grep -q '^email_setup_failed()' "$HARDEN" && grep -q 'if ! apt install -y postfix mailutils; then' "$HARDEN" \
   && grep -A1 'if ! apt install -y postfix mailutils; then' "$HARDEN" | grep -q email_setup_failed; then
    sed -n '/^email_setup_failed() {/,/^}/p' "$HARDEN" > "$work/esf.sh"
    new_root; mkdir -p "$R/etc/ssh"; echo 'Port 2222' > "$R/etc/ssh/sshd_config"; sed -i.bak "s|/etc/ssh|$R/etc/ssh|g" "$work/esf.sh"
    ( . "$work/esf.sh"; email_setup_failed "test" ) > "$R/esf.out" 2>&1; rc=$?
    if [ "$rc" -ne 0 ] && grep -q 'What is done' "$R/esf.out" && grep -q 'port 2222' "$R/esf.out" && grep -q 'run this script again' "$R/esf.out"; then
        ok "hardening script: failed postfix install stops with a message: SSH port, what is done and not, what to do next"
    else fail "hardening script: postfix failure message" "$(cat "$R/esf.out")"; fi
else fail "hardening script: a failed postfix install is not caught"; fi

# ---- 7. the PostgreSQL guard dog sees a database that is down although the postgresql unit says active (ops #1321) --------
# On Ubuntu `postgresql` is a wrapper unit: it stays "active" while the cluster (postgresql@18-main) is stopped. The fake
# systemctl says "active" for it the whole time, as the real one did on the test box; only pg_isready tells the truth.
sed -n "/^cat > \/opt\/tak-guarddog\/tak-db-watch.sh << 'EOFDB'\$/,/^EOFDB\$/p" "$HARDEN" | sed '1d;$d' > "$work/db-watch.raw"
if [ ! -s "$work/db-watch.raw" ]; then fail "hardening script: could not find the PostgreSQL guard dog text"; else
    db_case() {  # DB_STATE (up|down|restart-works) -> sets rc; $R/mails counts the alert mails
        new_root; mkdir -p "$R/state" "$R/log" "$R/b"; cp "$bin"/* "$R/b/"
        sed -e 's/ALERT_EMAIL_PLACEHOLDER/ops@example.com/g' -e "s|/var/lib/takguard|$R/state|g" -e "s|/var/log/takguard|$R/log|g" "$work/db-watch.raw" > "$R/db-watch.sh"
        echo "$1" > "$R/dbstate"
        cat > "$R/b/pg_isready" <<EOF
#!/bin/sh
[ "\$(cat "$R/dbstate")" = "up" ]
EOF
        cat > "$R/b/systemctl" <<EOF
#!/bin/sh
echo "\$*" >> "\$FAKE_LOG"
# the wrapper unit: always active, the way the real one is
[ "\$1" = "restart" ] && [ "\$(cat "$R/dbstate")" = "restart-works" ] && echo up > "$R/dbstate"
exit 0
EOF
        cat > "$R/b/mail" <<EOF
#!/bin/sh
cat > /dev/null; echo mail >> "$R/mails"
EOF
        chmod +x "$R/b"/*
        PATH="$R/b:$PATH" bash "$R/db-watch.sh" > "$R/db.out" 2>&1; rc=$?
    }
    db_case up
    if [ "$rc" -eq 0 ] && [ ! -e "$R/mails" ] && ! grep -q '^restart' "$FAKE_LOG"; then ok "db guard dog: database up: no mail, no restart"; \
    else fail "db guard dog: database up (rc $rc)"; fi
    db_case down
    if [ -e "$R/mails" ] && grep -q '^restart postgresql' "$FAKE_LOG"; then ok "db guard dog: database down but the postgresql unit says active: mails and restarts it"; \
    else fail "db guard dog: database down, unit says active: no alert and no restart (the Ubuntu wrapper-unit fault)" "calls: $(tr '\n' ';' < "$FAKE_LOG")"; fi
    db_case restart-works
    if [ -e "$R/mails" ] && grep -q 'restarted successfully' "$R/log/restarts.log" 2>/dev/null; then ok "db guard dog: restart brings the database back: logged as restarted successfully"; \
    else fail "db guard dog: restart that works is not logged as success" "$(cat "$R/log/restarts.log" 2>/dev/null)"; fi
    if grep -q '/var/lib/pgsql' "$work/db-watch.raw"; then fail "db guard dog: the mail still names the Rocky log path /var/lib/pgsql (Ubuntu keeps it in /var/log/postgresql)"; \
    else ok "db guard dog: the mail names the Ubuntu log path"; fi
fi

# ---- 8. the guide names the database TAK Server really has (cot), not takserver (ops #1321) ------------------------------
if grep -nE '(pg_dump|psql)[^|]* takserver([[:space:]]|$)|psql -l [|] grep takserver' DEPLOYMENT-GUIDE.md | grep -v 'docker exec' > "$work/guide.txt" && [ -s "$work/guide.txt" ]; then
    fail "DEPLOYMENT-GUIDE.md: a database command still names a database called takserver (TAK Server's is cot)" "$(head -n 5 "$work/guide.txt")"
else ok "DEPLOYMENT-GUIDE.md: no database command names a database called takserver"; fi

[ "$fails" -eq 0 ] && echo "all TAK-left-stopped and keystore checks passed" || echo "$fails TAK-left-stopped / keystore check(s) failed"
[ "$fails" -eq 0 ]

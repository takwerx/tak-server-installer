#!/usr/bin/env bash
# Checks that the Docker install sets up certificate enrollment on 8446 (ops #703). Without a <certificateSigning> block in
# CoreConfig.xml, 8446 answers /Marti/api/tls/config with HTTP 500 and ATAK users cannot enroll with a username and password.
# No Docker, no root, no network. Needs GNU sed (the CI runner has it) and python3:
#   bash .github/ci/test_docker_enrollment.sh
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 2
INSTALL=docker/tak-docker-install.sh
fails=0

ok()   { echo "ok   $1"; }
fail() { echo "FAIL $1"; shift; [ "$#" -gt 0 ] && printf '     %s\n' "$@"; fails=$((fails + 1)); }

SED=sed
if ! sed --version >/dev/null 2>&1; then
  command -v gsed >/dev/null && SED=gsed || { echo "needs GNU sed (on a Mac: brew install gnu-sed)"; exit 2; }
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- the function the installer runs, taken out of the script itself
fn="$work/fn.sh"
sed -n '/^# BEGIN enable_enrollment/,/^# END enable_enrollment/p' "$INSTALL" > "$fn"
if [ "$(wc -l < "$fn")" -lt 5 ]; then fail "install script: no enable_enrollment function between the BEGIN and END markers"; echo "$fails check(s) failed"; exit 1; fi
# GNU sed under the name sed, and the script's err helper
mkdir "$work/bin"; ln -s "$(command -v $SED)" "$work/bin/sed"
export PATH="$work/bin:$PATH"
err() { echo "[ERROR] $1" >&2; }
# shellcheck disable=SC1090
. "$fn"

# --- a CoreConfig.xml shaped like the one in takserver-docker-hardened-5.8 (same lines, shortened): the certificateSigning
# block is only a comment, there is no <vbm/> line, the truststore is truststore-root.jks
cfg="$work/CoreConfig.xml"
cat > "$cfg" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<Configuration xmlns="http://bbn.com/marti/xml/config"
               xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
               xsi:schemaLocation="CoreConfig.xsd">
    <network tomcatMaxPool="300" esyncEnableCache="1" multicastTTL="5">
        <input _name="stdssl" protocol="tls" port="8089" coreVersion="2"/>
        <connector port="8443" _name="https"/>
        <connector port="8446" clientAuth="false" _name="cert_https"/>
    </network>
    <auth>
        <File location="UserAuthenticationFile.xml"/>
    </auth>
    <security>
        <tls context="TLSv1.2"
             keymanager="SunX509"
             keystore="JKS" keystoreFile="/opt/tak/certs/files/takserver.jks" keystorePass="atakatak"
             truststore="JKS" truststoreFile="/opt/tak/certs/files/truststore-root.jks" truststorePass="atakatak">
        </tls>
    </security>

    <!--

    <certificateSigning CA="{TAKServer | MicrosoftCA}">
        <certificateConfig>
            <nameEntries>
                <nameEntry name="O" value="Test Org Name"/>
                <nameEntry name="OU" value="Test Org Unit Name"/>
            </nameEntries>
        </certificateConfig>
        <TAKServerCAConfig
            keystore="JKS"
            keystoreFile="certs/files/intermediate-signing.jks"
            keystorePass="atakatak"
            validityDays="30"
            signatureAlg="SHA256WithRSA" />
    </certificateSigning>

    -->

</Configuration>
XML

check() {   # prints what is wrong with the config, nothing when it is right
python3 -I - "$1" "$2" "$3" "$4" <<'PY'
import sys
import xml.etree.ElementTree as ET
cfg, ica, org, ou = sys.argv[1:5]
ns = "{http://bbn.com/marti/xml/config}"
try:
    root = ET.parse(cfg).getroot()
except ET.ParseError as e:
    print("CoreConfig.xml is not well-formed XML: %s" % e); sys.exit(0)
cs = root.findall(ns + "certificateSigning")
if len(cs) != 1:
    print("expected exactly one active <certificateSigning> block, found %d" % len(cs)); sys.exit(0)
cs = cs[0]
if cs.get("CA") != "TAKServer":
    print("certificateSigning CA is %r, expected TAKServer" % cs.get("CA"))
names = {n.get("name"): n.get("value") for n in cs.iter(ns + "nameEntry")}
if names != {"O": org, "OU": ou}:
    print("nameEntries are %r, expected O=%s OU=%s" % (names, org, ou))
ca = cs.find(ns + "TAKServerCAConfig")
if ca is None:
    print("no <TAKServerCAConfig> in the certificateSigning block"); sys.exit(0)
if ca.get("keystoreFile") != "/opt/tak/certs/files/%s-signing.jks" % ica:
    print("signing keystore is %r, expected /opt/tak/certs/files/%s-signing.jks" % (ca.get("keystoreFile"), ica))
if ca.get("keystorePass") != "atakatak":
    print("signing keystore password is not the makeCert.sh default")
tls = root.find(ns + "security").find(ns + "tls")
if tls.get("truststoreFile") != "/opt/tak/certs/files/truststore-%s.jks" % ica:
    print("truststore is %r, expected /opt/tak/certs/files/truststore-%s.jks" % (tls.get("truststoreFile"), ica))
PY
}

# --- on the untouched file the check must fail (this is what shipped before the fix)
bad=$(check "$cfg" Yankee1-Intermediate NSW CTT)
if [ -n "$bad" ]; then ok "an untouched CoreConfig.xml has no enrollment (the check can fail)"; else fail "the check passes on a CoreConfig.xml with no enrollment block"; fi

# --- after the installer's function
enable_enrollment "$cfg" Yankee1-Intermediate NSW CTT
bad=$(check "$cfg" Yankee1-Intermediate NSW CTT)
if [ -z "$bad" ]; then ok "enable_enrollment: signing block, organisation, signing keystore and truststore are set"; else fail "enable_enrollment: CoreConfig.xml is wrong afterwards" "$bad"; fi

# --- the commented example must be left alone, and running it again must not add a second block
enable_enrollment "$cfg" Yankee1-Intermediate NSW CTT
bad=$(check "$cfg" Yankee1-Intermediate NSW CTT)
if [ -z "$bad" ]; then ok "enable_enrollment: running it twice leaves one block"; else fail "enable_enrollment: a second run changed the result" "$bad"; fi
if grep -q 'Test Org Name' "$cfg"; then ok "enable_enrollment: the commented example is untouched"; else fail "enable_enrollment: the commented example was changed"; fi

# --- a missing file is an error, not a silent pass
if enable_enrollment "$work/nope.xml" X Y Z 2>/dev/null; then fail "enable_enrollment: a missing CoreConfig.xml was not reported"; else ok "enable_enrollment: a missing CoreConfig.xml is an error"; fi

# --- the installer calls it, with an intermediate CA made first and before TAK Server restarts
line_of() { grep -n -m1 -E -- "$1" "$INSTALL" | cut -d: -f1; }
l_root=$(line_of 'makeRootCa\.sh')
l_int=$(line_of 'makeCert\.sh ca \$\{INTERMEDIATE_CA_NAME\}')
l_srv=$(line_of 'makeCert\.sh server ')
l_cli=$(line_of 'makeCert\.sh client ')
l_call=$(line_of '^enable_enrollment tak/CoreConfig\.xml ')
l_rst=$(line_of 'configureInDocker\.sh"$')
if [ -n "$l_int" ] && [ -n "$l_root" ] && [ -n "$l_srv" ] && [ -n "$l_cli" ] && [ "$l_root" -lt "$l_int" ] && [ "$l_int" -lt "$l_srv" ] && [ "$l_int" -lt "$l_cli" ]; then
  ok "install script: the intermediate CA is made after the root CA and before the server and admin certificates"
else
  fail "install script: it must run makeCert.sh ca \${INTERMEDIATE_CA_NAME} after makeRootCa.sh and before the server and admin certificates" "root=$l_root intermediate=$l_int server=$l_srv client=$l_cli"
fi
if [ -n "$l_call" ] && [ -n "$l_rst" ] && [ -n "$l_int" ] && [ "$l_int" -lt "$l_call" ] && [ "$l_call" -lt "$l_rst" ]; then
  ok "install script: enrollment is enabled after the intermediate CA exists and before TAK Server restarts"
else
  fail "install script: enable_enrollment must be called after the intermediate CA is made and before the restart" "intermediate=$l_int call=$l_call restart=$l_rst"
fi
if grep -qE '^INTERMEDIATE_CA_NAME=' "$INSTALL"; then ok "install script: INTERMEDIATE_CA_NAME is set"; else fail "install script: INTERMEDIATE_CA_NAME is not set"; fi

[ "$fails" -eq 0 ] && echo "all docker enrollment checks passed" || echo "$fails docker enrollment check(s) failed"
[ "$fails" -eq 0 ]

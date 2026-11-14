#!/usr/bin/env bash
# install-takx.sh - wrapper around the TAKX install4j shell installer.
#
# Run it from the same folder as takx-unix-jdk*-<version>.sh.
#   * On arm64 (or with --system-java) it skips the bundled x64 JRE and uses a
#     system JDK 17.
#   * Installs headless/unattended by default (use --gui or --console to change).
#   * Writes a varfile so each variant gets its own install dir and data dir,
#     and NO symlinks in /usr/local/bin unless you ask for them.
#
# Run with --help for all options.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- defaults -------------------------------------------------------------
INSTALLER=""
VARIANT=""
PREFIX=""
INSTALL_DIR=""
DATA_DIR=""
SYMLINK_DIR=""          # empty = no symlinks
MENU=false              # desktop menu entries / program group
DESKTOP_LINK=false
MODE="auto"             # auto | quiet | console | gui
SYSTEM_JAVA=auto        # auto | yes | no
JAVA_HOME_ARG=""
TEMP_DIR=""
OVERWRITE=false
DRY_RUN=false
KEEP_TEMP=false
EXTRA_ARGS=()

usage() {
cat <<'EOF'
install-takx.sh - install TAKX from its install4j .sh installer, headless,
                  on x86_64 or arm64, without clobbering other variants.

USAGE
  ./install-takx.sh [options] [-- extra installer args]

  Run it from the folder containing the takx-*.sh installer (or use
  --installer). Start with --dry-run to see exactly what would happen.

WHAT IT DOES
  1. Locates the installer .sh.
  2. On arm64 (or with --system-java) skips the bundled x64 JRE and finds a
     system JDK 17. The installer requires exactly Java 17; 11/21 are rejected.
  3. Writes a temporary varfile that sets the install dir, a per-variant data
     dir, and turns OFF the /usr/local/bin symlinks, menu entries and desktop
     link, so installing several variants never overwrites one another.
  4. Runs the installer unattended (-q -console) unless told otherwise.

SELECTION
  --installer FILE     Installer .sh to use.
                       Default: the only takx-*.sh in this script's folder.
  --variant NAME       Name used to build default paths, e.g. takx-civ.
                       Default: read from the installer itself
                       (applicationShortName-buildFlavor, e.g. takx-civ);
                       falls back to this folder's name if unreadable.

LOCATIONS
  --prefix DIR         Parent for default paths. Default: /opt
  --dir DIR            Install directory.
                       Default: PREFIX/VARIANT
  --data-dir DIR       Project data directory (database, users, etc).
                       Default: PREFIX/VARIANT-data
                       (The installer's own default, /usr/local/TAKX, is shared
                       by every variant - that is why this is overridden.)
  --symlink-dir DIR    Create launcher symlinks in DIR.
                       Default: none. The installer would otherwise use
                       /usr/local/bin and variants would overwrite each other.
  --menu               Create desktop menu entries. Default: off.
  --desktop-link       Create a desktop link. Default: off.

JAVA
  --system-java        Skip the bundled JRE; use a system JDK 17.
                       Default on arm64/aarch64.
  --bundled-java       Force the bundled JRE (it is x64: fails on arm64).
  --java-home DIR      JDK 17 to use (implies --system-java).
                       Otherwise searched in order: INSTALL4J_JAVA_HOME,
                       JAVA_HOME, /usr/lib/jvm/*, /opt/java*, java on PATH.

MODE
  --quiet, -q          Unattended, no prompts (default). Needs no display.
  --console, -c        Text-mode wizard; answer prompts in the terminal.
                       Use this if --quiet skips an option you need to set.
  --gui                Graphical wizard (needs a display).
  --overwrite          Overwrite existing files when unattended.

MISC
  --temp-dir DIR       Where the ~400 MB payload is extracted.
                       Use if /tmp is small.
  --keep-temp          Keep the extracted files after a run (debugging).
  --no-sudo            Do not re-run under sudo (the installer will then fail
                       unless you are already root).
  --dry-run            Print the varfile and command; install nothing.
  -h, --help           Show this help.
  -- ARGS...           Everything after -- is passed to the installer as-is
                       (e.g. -- -Vsome.var=value, -- -splash TAKX).

EXAMPLES
  Preview, no changes:
    ./install-takx.sh --dry-run

  Default unattended install (arm64 auto-detected):
    ./install-takx.sh

  Custom location (still installs as root - see below):
    ./install-takx.sh --prefix /srv/tak

  Specific JDK, specific paths:
    sudo ./install-takx.sh --java-home /usr/lib/jvm/java-17-openjdk-arm64 \
         --dir /opt/takx-civ-5.8.0 --data-dir /var/lib/takx-civ

  Answer prompts yourself, but still skip the symlinks and stay headless:
    sudo ./install-takx.sh --console

  Want a command on PATH for just this variant:
    sudo ./install-takx.sh --symlink-dir /opt/takx-civ/bin

NOTES
  * The installer refuses to run unless it is root ("You must be logged in
    as root"). The script therefore re-runs itself with sudo automatically
    (you will get a sudo password prompt). --dry-run never needs root.
    --no-sudo disables the automatic re-run.
  * Exit status is the installer's. Failed runs: retry with --keep-temp, and
    send the output.
  * On arm64, if the install dir ends up with an x64 jre/ folder, the script
    prints the command to replace it with a link to your arm64 JDK.
EOF
}

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ---- args -----------------------------------------------------------------
ORIG_ARGS=("$@")
NO_SUDO=false
while [ $# -gt 0 ]; do
  case "$1" in
    --installer)    INSTALLER="${2:?}"; shift 2;;
    --variant)      VARIANT="${2:?}"; shift 2;;
    --prefix)       PREFIX="${2:?}"; shift 2;;
    --dir)          INSTALL_DIR="${2:?}"; shift 2;;
    --data-dir)     DATA_DIR="${2:?}"; shift 2;;
    --symlink-dir)  SYMLINK_DIR="${2:?}"; shift 2;;
    --menu)         MENU=true; shift;;
    --desktop-link) DESKTOP_LINK=true; shift;;
    --system-java)  SYSTEM_JAVA=yes; shift;;
    --bundled-java) SYSTEM_JAVA=no; shift;;
    --java-home)    JAVA_HOME_ARG="${2:?}"; SYSTEM_JAVA=yes; shift 2;;
    --quiet|-q)     MODE=quiet; shift;;
    --console|-c)   MODE=console; shift;;
    --gui)          MODE=gui; shift;;
    --overwrite)    OVERWRITE=true; shift;;
    --temp-dir)     TEMP_DIR="${2:?}"; shift 2;;
    --keep-temp)    KEEP_TEMP=true; shift;;
    --dry-run)      DRY_RUN=true; shift;;
    --no-sudo)      NO_SUDO=true; shift;;
    -h|--help)      usage; exit 0;;
    --)             shift; EXTRA_ARGS=("$@"); break;;
    *)              die "unknown option: $1 (see --help)";;
  esac
done

# ---- find the installer ---------------------------------------------------
if [ -z "$INSTALLER" ]; then
  shopt -s nullglob
  # exclude this script
  candidates=()
  for f in "$HERE"/takx-*.sh; do candidates+=("$f"); done
  shopt -u nullglob
  [ "${#candidates[@]}" -eq 1 ] || die "expected exactly one takx-*.sh in $HERE (found ${#candidates[@]}); use --installer FILE"
  INSTALLER="${candidates[0]}"
fi
[ -f "$INSTALLER" ] || die "installer not found: $INSTALLER"
grep -aq 'INSTALL4J' "$INSTALLER" || die "$INSTALLER does not look like an install4j installer"
INSTALLER="$(cd "$(dirname "$INSTALLER")" && pwd)/$(basename "$INSTALLER")"

# ---- read variant info embedded in the installer --------------------------
# The .sh ends with a gzipped tar whose i4jparams.conf holds buildFlavor
# (e.g. civ), applicationShortName (takx) and releaseVersion (5.8.0).
read_embedded() {  # $1 = variable name -> value (empty if unavailable)
  local n
  n="$(grep -a -m1 -o 'tail -c [0-9][0-9]*' "$INSTALLER" 2>/dev/null | awk '{print $3}')" || true
  [ -n "$n" ] || return 0
  { tail -c "$n" "$INSTALLER" | gunzip 2>/dev/null | tar xOf - i4jparams.conf 2>/dev/null; } 2>/dev/null \
    | tr -d '\r' | grep -a -m1 "<variable name=\"$1\" value=" \
    | sed -n 's/.*value="\([^"]*\)".*/\1/p' || true
}
EMB_FLAVOR="" EMB_NAME="" EMB_VERSION=""
if [ -z "$VARIANT" ] || true; then
  EMB_NAME="$(read_embedded applicationShortName || true)"
  EMB_FLAVOR="$(read_embedded buildFlavor || true)"
  EMB_VERSION="$(read_embedded releaseVersion || true)"
fi

# ---- variant / paths ------------------------------------------------------
VARIANT_SRC="--variant"
if [ -z "$VARIANT" ]; then
  if [ -n "$EMB_NAME" ] && [ -n "$EMB_FLAVOR" ]; then
    VARIANT="$EMB_NAME-$EMB_FLAVOR"; VARIANT_SRC="installer metadata"
  else
    VARIANT="$(basename "$HERE" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._\n-' '-')"
    VARIANT_SRC="folder name (installer metadata unreadable)"
  fi
fi
VARIANT="$(printf '%s' "$VARIANT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9._-' '-' | sed 's/-*$//')"
if [ -z "$PREFIX" ]; then
  PREFIX=/opt
fi
[ -n "$INSTALL_DIR" ] || INSTALL_DIR="$PREFIX/$VARIANT"
[ -n "$DATA_DIR" ]    || DATA_DIR="$PREFIX/$VARIANT-data"

# ---- architecture / java --------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
  aarch64|arm64|armv8*) IS_ARM=true;;
  *)                    IS_ARM=false;;
esac
if [ "$SYSTEM_JAVA" = auto ]; then
  if $IS_ARM; then SYSTEM_JAVA=yes; else SYSTEM_JAVA=no; fi
fi

java_major() {  # prints major version of the java binary at $1, or nothing
  local out
  out="$("$1" -version 2>&1 | head -n1)" || return 0
  # openjdk version "17.0.17" ... / java version "1.8.0_x"
  out="$(printf '%s' "$out" | sed -n 's/.*version "\([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
  set -- $out
  if [ "${1:-}" = 1 ]; then echo "${2:-}"; else echo "${1:-}"; fi
}

find_java17() {
  local cand j
  local cands=()
  [ -n "$JAVA_HOME_ARG" ]        && cands+=("$JAVA_HOME_ARG")
  [ -n "${INSTALL4J_JAVA_HOME:-}" ] && cands+=("$INSTALL4J_JAVA_HOME")
  [ -n "${JAVA_HOME:-}" ]        && cands+=("$JAVA_HOME")
  for j in /usr/lib/jvm/*17* /usr/lib/jvm/*/ /opt/java/*17* /opt/jdk*17* /usr/local/*17*; do
    [ -d "$j" ] && cands+=("${j%/}")
  done
  if command -v java >/dev/null 2>&1; then
    cands+=("$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")")
  fi
  for cand in "${cands[@]}"; do
    [ -x "$cand/bin/java" ] || continue
    if [ "$(java_major "$cand/bin/java")" = 17 ]; then
      echo "$cand"; return 0
    fi
  done
  return 1
}

JAVA17=""
if [ "$SYSTEM_JAVA" = yes ]; then
  JAVA17="$(find_java17)" || die "no Java 17 found. Install a JDK 17 (e.g. 'sudo apt install openjdk-17-jdk') or pass --java-home DIR.
The installer requires exactly Java 17."
  [ -x "$JAVA17/bin/javac" ] || echo "WARNING: $JAVA17 has no javac (JRE only?). If the installer fails, install a full JDK 17." >&2
  if $IS_ARM && [ -f "$JAVA17/bin/java" ]; then
    file "$JAVA17/bin/java" 2>/dev/null | grep -qiE 'x86-64|x86_64' && die "$JAVA17 is an x86-64 JDK on an arm machine"
  fi
fi

# ---- mode -----------------------------------------------------------------
if [ "$MODE" = auto ]; then
  MODE=quiet      # unattended by default: repeatable, works with no display
fi

# ---- root --------------------------------------------------------------------
# The installer itself aborts with "You must be logged in as root", so re-run
# this script under sudo (a dry run never needs root).
if [ "$(id -u)" -ne 0 ] && ! $DRY_RUN && ! $NO_SUDO; then
  command -v sudo >/dev/null 2>&1 || die "the installer must run as root and sudo is not available"
  info "installer requires root - re-running with sudo"
  exec sudo "$0" "${ORIG_ARGS[@]}"
fi

# ---- permissions check ----------------------------------------------------
check_writable() {  # nearest existing ancestor must be writable
  local p="$1"
  while [ ! -e "$p" ]; do p="$(dirname "$p")"; done
  [ -w "$p" ]
}
for d in "$INSTALL_DIR" "$DATA_DIR"; do
  $DRY_RUN && break
  check_writable "$d" || die "cannot write to $d - run with sudo, or choose --prefix/--dir/--data-dir under your home"
done
if [ -n "$SYMLINK_DIR" ] && ! $DRY_RUN; then
  check_writable "$SYMLINK_DIR" || die "cannot write symlinks to $SYMLINK_DIR - run with sudo or pick another --symlink-dir"
fi

# ---- varfile --------------------------------------------------------------
VARFILE="$(mktemp "${TMPDIR:-/tmp}/takx-install.XXXXXX.varfile")"
trap 'rm -f "$VARFILE"' EXIT
{
  echo "# generated by install-takx.sh for variant: $VARIANT"
  echo "sys.languageId=en"
  echo "sys.installationDir=$INSTALL_DIR"
  echo "projectDataDir=$DATA_DIR"
  echo "# empty = do not create launcher symlinks (installer default is /usr/local/bin)"
  echo "sys.symlinkDir=$SYMLINK_DIR"
  if $MENU; then echo 'sys.programGroupDisabled$Boolean=false'; else echo 'sys.programGroupDisabled$Boolean=true'; fi
  echo "createDesktopLinkAction\$Boolean=$DESKTOP_LINK"
} > "$VARFILE"

# ---- assemble command -----------------------------------------------------
ARGS=()
case "$MODE" in
  quiet)   ARGS+=(-q -console);;
  console) ARGS+=(-c);;
  gui)     ;;
esac
ARGS+=(-varfile "$VARFILE")
[ "$MODE" = quiet ] && ARGS+=(-dir "$INSTALL_DIR")
$OVERWRITE && ARGS+=(-overwrite)
[ "${#EXTRA_ARGS[@]}" -gt 0 ] && ARGS+=("${EXTRA_ARGS[@]}")

ENVV=()
if [ "$SYSTEM_JAVA" = yes ]; then
  ENVV+=(INSTALL4J_DISABLE_BUNDLED_JRE=true "INSTALL4J_JAVA_HOME=$JAVA17")
fi
[ -n "$TEMP_DIR" ] && { mkdir -p "$TEMP_DIR"; ENVV+=("INSTALL4J_TEMP=$TEMP_DIR"); }
$KEEP_TEMP && ENVV+=(INSTALL4J_KEEP_TEMP=yes)

info "installer : $INSTALLER"
info "arch      : $ARCH  | java: ${JAVA17:-bundled JRE}"
info "variant   : $VARIANT  (from $VARIANT_SRC${EMB_VERSION:+, version $EMB_VERSION})"
info "install   : $INSTALL_DIR"
info "data dir  : $DATA_DIR"
info "symlinks  : ${SYMLINK_DIR:-none}"
info "menu/desktop: $MENU / $DESKTOP_LINK"
info "mode      : $MODE"
info "varfile   :"; sed 's/^/      /' "$VARFILE"
info "command   : ${ENVV[*]:-} sh $INSTALLER ${ARGS[*]}"

if $DRY_RUN; then
  info "dry run - nothing executed"
  exit 0
fi

rc=0
env "${ENVV[@]}" sh "$INSTALLER" "${ARGS[@]}" || rc=$?

if [ $rc -eq 0 ]; then
  info "done. Installed to $INSTALL_DIR"
  if $IS_ARM && [ -d "$INSTALL_DIR/jre" ]; then
    echo "NOTE: $INSTALL_DIR/jre exists. If it is x64, replace it with a symlink to $JAVA17:" >&2
    echo "      mv '$INSTALL_DIR/jre' '$INSTALL_DIR/jre.x64' && ln -s '$JAVA17' '$INSTALL_DIR/jre'" >&2
  fi
fi
exit $rc

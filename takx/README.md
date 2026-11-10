# TAKX installer wrapper

`install-takx.sh` installs TAKX (for example TAKX-CIV) from its install4j shell installer, `takx-unix-jdk*-<version>.sh`, on machines that are not x86-64, such as a Raspberry Pi 5 or another arm64 box. It also works on x86-64.

What it changes compared with running the installer directly:

- **arm64:** skips the installer's bundled x64 Java and uses a system JDK 17 instead. The installer accepts only Java 17, not 11 or 21.
- **Unattended:** installs with no prompts and no display by default (`--console` or `--gui` to change).
- **One folder per variant:** writes a varfile so each variant gets its own install dir (`/opt/<variant>`) and data dir (`/opt/<variant>-data`), and creates no `/usr/local/bin` symlinks, menu entries or desktop link. Installing several variants never overwrites one another.
- **Root:** the installer only runs as root, so the script re-runs itself with sudo. `--dry-run` never needs root.

## Usage

The script looks for the installer in its own folder. From this repo, point it at the installer instead:

```bash
./takx/install-takx.sh --installer /path/to/takx-unix-jdk17-<version>.sh --dry-run   # preview
./takx/install-takx.sh --installer /path/to/takx-unix-jdk17-<version>.sh             # install
```

Run `./takx/install-takx.sh --help` for every option (paths, Java, mode, temp dir).

## Java 17 on Debian 13 / Raspberry Pi OS (trixie)

Debian 13 ships Java 21 and has no `openjdk-17-jdk` package, so the script's `apt install` hint does not apply there. Install Eclipse Temurin 17 for aarch64 from [adoptium.net](https://adoptium.net) and pass its folder:

```bash
./takx/install-takx.sh --installer /path/to/takx-unix-jdk17-<version>.sh --java-home /path/to/jdk-17
```

Ubuntu 22.04/24.04 and Debian 12 still have `openjdk-17-jdk`.

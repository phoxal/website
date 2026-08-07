#!/bin/sh
# phoxal-cli installer
#
#   curl -fsSL https://phoxal.com/install.sh | sh
#
# Canonical source: https://github.com/phoxal/website (install.sh at repo
# root), served as https://phoxal.com/install.sh. Release assets are published
# by https://github.com/phoxal/phoxal-cli; the asset naming contract below is
# shared with `phoxal self upgrade` there.
#
# Options (environment variables):
#   PHOXAL_CLI_VERSION   pin a release, e.g. v0.4.0 (default: latest)
#   PREFIX               install prefix (default: /usr/local, falls back to
#                        ~/.local when not writable)
#
# Asset naming contract (shared with `phoxal self upgrade`):
#   archive   phoxal-<version-no-v>-<target>.tar.gz
#   binaries  phoxal-<target> and phoxald-<target>   (inside the archive)
#   checksum  <archive>.sha256               ("<hex>  <archive>")
#
# phoxal and phoxald are one product and install as an exact pair: the client
# builds and attaches, the daemon supervises the execution, and each refuses to
# work without a matching sibling. Both are verified present before either is
# installed, so a failure never leaves a half-installed pair behind.

set -eu

REPO="phoxal/phoxal-cli"
RELEASES="https://github.com/${REPO}/releases"

# --- output helpers ---------------------------------------------------------

if [ -t 2 ] && [ "${NO_COLOR:-}" = "" ] && [ "${TERM:-dumb}" != "dumb" ]; then
    bold=$(printf '\033[1m')
    dim=$(printf '\033[2m')
    red=$(printf '\033[31m')
    green=$(printf '\033[32m')
    yellow=$(printf '\033[33m')
    cyan=$(printf '\033[36m')
    reset=$(printf '\033[0m')
else
    bold='' dim='' red='' green='' yellow='' cyan='' reset=''
fi

step() {
    printf '%s\n' "${cyan}${bold}>${reset} ${bold}$*${reset}" >&2
}

info() {
    printf '%s\n' "  ${dim}$*${reset}" >&2
}

warn() {
    printf '%s\n' "${yellow}${bold}warn${reset} $*" >&2
}

fail() {
    printf '%s\n' "${red}${bold}error${reset} $*" >&2
    exit 1
}

# --- prerequisites ----------------------------------------------------------

if command -v curl >/dev/null 2>&1; then
    download_file() {
        curl -fsSL "$1" -o "$2"
    }
    latest_redirect_url() {
        curl -fsSLI -o /dev/null -w '%{url_effective}' "$1"
    }
elif command -v wget >/dev/null 2>&1; then
    download_file() {
        wget -qO "$2" "$1"
    }
    latest_redirect_url() {
        wget -q --max-redirect=10 --server-response --spider "$1" 2>&1 |
            sed -n 's/.*Location: \(.*\)/\1/p' | tail -n 1
    }
else
    fail "curl or wget is required"
fi

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        printf '%s\n' ""
    fi
}

# --- detect platform --------------------------------------------------------

detect_target() {
    os=$(uname -s)
    arch=$(uname -m)
    case "$os:$arch" in
        Darwin:arm64) printf '%s\n' "aarch64-apple-darwin" ;;
        Linux:x86_64) printf '%s\n' "x86_64-unknown-linux-gnu" ;;
        Linux:aarch64 | Linux:arm64) printf '%s\n' "aarch64-unknown-linux-gnu" ;;
        Darwin:x86_64)
            fail "Intel macOS is not supported yet (Apple Silicon, Linux x86_64, and Linux arm64 are)"
            ;;
        *)
            fail "unsupported platform ${os} ${arch} (supported: Apple Silicon macOS, Linux x86_64, Linux arm64)"
            ;;
    esac
}

# --- resolve version --------------------------------------------------------

resolve_version() {
    if [ "${PHOXAL_CLI_VERSION:-}" ]; then
        case "$PHOXAL_CLI_VERSION" in
            v*) printf '%s\n' "$PHOXAL_CLI_VERSION" ;;
            *) fail "PHOXAL_CLI_VERSION must start with v, for example v0.4.0" ;;
        esac
        return
    fi
    # GitHub serves /releases/latest as a redirect to /releases/tag/vX.Y.Z.
    # Following it and reading the final URL avoids the rate-limited API.
    final_url=$(latest_redirect_url "${RELEASES}/latest") ||
        fail "could not reach ${RELEASES}/latest"
    version=${final_url##*/}
    case "$version" in
        v*) printf '%s\n' "$version" ;;
        *) fail "could not determine the latest release tag (got '${final_url}')" ;;
    esac
}

# --- main -------------------------------------------------------------------

printf '%s\n' "" >&2
printf '%s\n' "  ${bold}phoxal-cli installer${reset}" >&2
printf '%s\n' "  ${dim}https://phoxal.com${reset}" >&2
printf '%s\n' "" >&2

step "Detecting platform"
target=$(detect_target)
info "$(uname -s) $(uname -m) -> ${target}"

step "Resolving version"
version=$(resolve_version)
info "${version}"

version_without_v=${version#v}
asset="phoxal-${version_without_v}-${target}.tar.gz"
url="${RELEASES}/download/${version}/${asset}"

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/phoxal-cli.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

step "Downloading ${asset}"
archive="$tmpdir/$asset"
download_file "$url" "$archive" || fail "download failed: ${url}"

step "Verifying checksum"
checksum_file="$tmpdir/$asset.sha256"
if download_file "$url.sha256" "$checksum_file" 2>/dev/null; then
    expected=$(cut -d' ' -f1 <"$checksum_file")
    actual=$(sha256_of "$archive")
    if [ -z "$actual" ]; then
        warn "no sha256sum/shasum on this host; skipping checksum verification"
    elif [ "$expected" != "$actual" ]; then
        fail "checksum mismatch for ${asset} (expected ${expected}, got ${actual})"
    else
        info "sha256 ok"
    fi
else
    warn "release ${version} does not publish checksums; skipping verification"
fi

step "Installing"
tar -xzf "$archive" -C "$tmpdir"
client="$tmpdir/phoxal-${target}"
daemon="$tmpdir/phoxald-${target}"
# Both halves are checked before anything is written: an archive missing one of
# them is a broken release, not a partial install to recover from.
[ -f "$client" ] || fail "release archive did not contain phoxal-${target}"
[ -f "$daemon" ] || fail "release archive did not contain phoxald-${target}"

prefix=${PREFIX:-/usr/local}
install_dir="$prefix/bin"
if ! { mkdir -p "$install_dir" 2>/dev/null && [ -w "$install_dir" ]; }; then
    install_dir="$HOME/.local/bin"
    mkdir -p "$install_dir" || fail "could not create $install_dir"
    info "$prefix/bin is not writable; using $install_dir"
fi

# The daemon goes first. A client without its daemon refuses to build or run
# and names the problem, while a daemon without its client is inert - so if the
# second copy fails, the first one left behind is the harmless half.
for pair in "phoxald:$daemon" "phoxal:$client"; do
    name=${pair%%:*}
    source=${pair#*:}
    destination="$install_dir/$name"
    cp "$source" "$destination" || fail "could not install to $destination"
    chmod 755 "$destination" || fail "could not chmod $destination"
    info "$destination"
done

printf '%s\n' "" >&2
printf '%s\n' "${green}${bold}✓${reset} ${bold}phoxal and phoxald ${version} installed${reset}" >&2

case ":$PATH:" in
    *":$install_dir:"*) ;;
    *)
        printf '%s\n' "" >&2
        warn "$install_dir is not on your PATH; add it to your shell profile:"
        printf '%s\n' "       export PATH=\"$install_dir:\$PATH\"" >&2
        ;;
esac

printf '%s\n' "" >&2
printf '%s\n' "  Get started:" >&2
printf '%s\n' "    ${cyan}phoxal --version${reset}" >&2
printf '%s\n' "    ${cyan}phoxal doctor${reset}" >&2
printf '%s\n' "" >&2

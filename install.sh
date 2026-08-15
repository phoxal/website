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
#   binary    phoxal-<target>                 (the archive's only entry)
#   checksum  <archive>.sha256               ("<hex>  <archive>")

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

# Normalize configured roots without resolving through a symlink or requiring
# the path to exist. Installation accepts no relative or unresolved segments.
normalize_root() {
    root_value=$1
    root_name=$2
    [ -n "$root_value" ] || fail "$root_name must not be empty"
    case "$root_value" in
        /*) ;;
        *) fail "$root_name must be an absolute path (got '$root_value')" ;;
    esac
    root_value=$(printf '%s\n' "$root_value" | sed 's://*:/:g')
    while [ "$root_value" != "/" ] && [ "${root_value%/}" != "$root_value" ]; do
        root_value=${root_value%/}
    done
    case "$root_value" in
        *//* | */./* | */../* | */. | */..)
            fail "$root_name contains unresolved path segments ('$root_value')"
            ;;
    esac
    printf '%s\n' "$root_value"
}

# Installation and legacy cleanup are confined to one absolute bin directory.
validate_install_dir() {
    case "$1" in
        /*/bin) ;;
        *) fail "refusing unsafe install directory '$1' (expected an absolute */bin path)" ;;
    esac
}

refuse_cross_install_shadowing() {
    other_dir=$1
    other_prefix=${other_dir%/bin}
    for other_name in phoxal phoxald; do
        other_path="$other_dir/$other_name"
        if [ -e "$other_path" ] || [ -L "$other_path" ]; then
            fail "$other_path would shadow this installation; remove it or rerun with PREFIX set to $other_prefix"
        fi
    done
}

prepare_fallback_dir() {
    fallback_dir=$1
    if [ -L "$fallback_dir" ]; then
        fail "refusing symlink install directory '$fallback_dir'; set PREFIX to the resolved directory instead"
    fi
    if [ -e "$fallback_dir" ] && [ ! -d "$fallback_dir" ]; then
        fail "install directory '$fallback_dir' is not a directory"
    fi
    mkdir -p "$fallback_dir" || fail "could not create $fallback_dir"
    [ -w "$fallback_dir" ] || fail "install directory '$fallback_dir' is not writable"
}

select_fallback_install_dir() {
    [ -n "${fallback_install_dir:-}" ] ||
        fail "HOME must be set to an absolute path when PREFIX is not writable"
    refuse_cross_install_shadowing "$requested_install_dir"
    prepare_fallback_dir "$fallback_install_dir"
    install_dir=$fallback_install_dir
    info "$requested_install_dir is not writable; using $install_dir"
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
printf '%s\n' "  ${bold}phoxal installer${reset}" >&2
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

prefix=$(normalize_root "${PREFIX:-/usr/local}" PREFIX)
requested_install_dir="${prefix%/}/bin"
validate_install_dir "$requested_install_dir"
fallback_install_dir=
if [ -n "${HOME:-}" ]; then
    home=$(normalize_root "$HOME" HOME)
    fallback_install_dir="${home%/}/.local/bin"
    validate_install_dir "$fallback_install_dir"
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/phoxal-cli.XXXXXX")
install_candidate=
cleanup() {
    if [ -n "${install_candidate:-}" ]; then
        rm -f "$install_candidate"
    fi
    rm -rf "$tmpdir"
}
trap cleanup 0
trap 'exit 1' 1 2 15

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
binary_name="phoxal-${target}"
archive_entries=$(tar -tzf "$archive") || fail "could not read release archive ${asset}"
case "$archive_entries" in
    "$binary_name") archive_member=$binary_name ;;
    "./$binary_name") archive_member="./$binary_name" ;;
    *) fail "release archive must contain exactly ${binary_name} at its root" ;;
esac
archive_description=$(tar -tvzf "$archive") || fail "could not inspect release archive ${asset}"
# The exact-one-member gate above makes this a check of the whole archive,
# rather than merely a check that its first listed member is regular.
case "$archive_description" in
    -*) ;;
    *) fail "release archive entry ${archive_member} is not a regular file" ;;
esac
payload_dir="$tmpdir/payload"
mkdir "$payload_dir" || fail "could not create the extraction directory"
tar -xzf "$archive" -C "$payload_dir" || fail "could not extract ${binary_name}"
client="$payload_dir/$binary_name"
[ -f "$client" ] && [ ! -L "$client" ] ||
    fail "release archive entry ${binary_name} is not a regular file"

if [ -L "$requested_install_dir" ]; then
    fail "refusing symlink install directory '$requested_install_dir'; set PREFIX to the resolved directory instead"
elif [ -d "$requested_install_dir" ]; then
    if [ -w "$requested_install_dir" ]; then
        install_dir=$requested_install_dir
    else
        select_fallback_install_dir
    fi
elif [ -e "$requested_install_dir" ]; then
    fail "install directory '$requested_install_dir' is not a directory; remove it or choose another PREFIX"
elif mkdir -p "$requested_install_dir" 2>/dev/null && [ -w "$requested_install_dir" ]; then
    install_dir=$requested_install_dir
else
    select_fallback_install_dir
fi

if [ -n "$fallback_install_dir" ] && [ "$install_dir" != "$fallback_install_dir" ]; then
    refuse_cross_install_shadowing "$fallback_install_dir"
fi

destination="$install_dir/phoxal"
if [ -e "$destination" ] && [ ! -f "$destination" ] && [ ! -L "$destination" ]; then
    fail "refusing to replace non-file destination $destination; remove it or choose another PREFIX"
fi

install_candidate=$(mktemp "$install_dir/.phoxal-install.XXXXXX") ||
    fail "could not create an installation candidate in $install_dir"
cp "$client" "$install_candidate" || fail "could not stage phoxal in $install_dir"
chmod 755 "$install_candidate" || fail "could not chmod the installation candidate"
cmp -s "$client" "$install_candidate" || fail "staged phoxal failed byte verification"

# Removing a destination symlink first prevents `mv` implementations from
# treating a symlink-to-directory as the target directory. Regular-file
# upgrades use one atomic same-directory rename; only this foreign-symlink
# replacement has a short unlink-before-rename window.
if [ -L "$destination" ]; then
    rm -f "$destination" || fail "could not replace destination symlink $destination"
elif [ -e "$destination" ] && [ ! -f "$destination" ]; then
    fail "refusing to replace non-file destination $destination"
fi
mv -f "$install_candidate" "$destination" || fail "could not install to $destination"
install_candidate=
[ -f "$destination" ] && [ ! -L "$destination" ] && [ -x "$destination" ] ||
    fail "installed phoxal is not an executable regular file"
cmp -s "$client" "$destination" || fail "installed phoxal failed byte verification"
info "$destination"

# The old installer owned this exact sibling. Remove it outright so upgrading
# cannot leave the retired daemon executable on PATH.
legacy_daemon="$install_dir/phoxald"
if [ -L "$legacy_daemon" ] || [ -f "$legacy_daemon" ]; then
    rm -f "$legacy_daemon" || fail "could not remove legacy $legacy_daemon"
    info "removed legacy $legacy_daemon"
elif [ -e "$legacy_daemon" ]; then
    warn "$legacy_daemon is not a file; preserving it"
fi

printf '%s\n' "" >&2
printf '%s\n' "${green}${bold}✓${reset} ${bold}phoxal ${version} installed${reset}" >&2

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

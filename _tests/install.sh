#!/bin/sh

set -eu

repo_root=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
temp_base=${TMPDIR:-/tmp}
test_root=$(mktemp -d "${temp_base%/}/phoxal-installer-test.XXXXXX")
cleanup() {
    chmod -R u+w "$test_root" 2>/dev/null || true
    rm -rf "$test_root"
}
trap cleanup 0
trap 'exit 1' 1 2 15

version=1.2.3
linux_target=x86_64-unknown-linux-gnu
darwin_target=aarch64-apple-darwin
fixtures="$test_root/fixtures"
fake_bin="$test_root/bin"
expected_payload="$test_root/expected-phoxal"
mkdir -p "$fixtures" "$fake_bin"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "phoxal 1.2.3"' >"$expected_payload"
chmod 755 "$expected_payload"

cp "$repo_root/_tests/fixtures/curl" "$repo_root/_tests/fixtures/uname" "$fake_bin/"
chmod 755 "$fake_bin/curl" "$fake_bin/uname"

fail_test() {
    printf '%s\n' "test failure: $*" >&2
    exit 1
}

archive_path() {
    printf '%s/phoxal-%s-%s.tar.gz\n' "$fixtures" "$version" "$1"
}

make_checksum() {
    checksum_archive=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$checksum_archive" >"$checksum_archive.sha256"
    else
        shasum -a 256 "$checksum_archive" >"$checksum_archive.sha256"
    fi
}

make_archive() (
    fixture_target=$1
    shape=$2
    fixture_archive=$(archive_path "$fixture_target")
    fixture_binary="phoxal-${fixture_target}"
    stage="$test_root/stage"
    rm -rf "$stage"
    mkdir -p "$stage"
    cp "$expected_payload" "$stage/$fixture_binary"
    case "$shape" in
        one) tar -czf "$fixture_archive" -C "$stage" "$fixture_binary" ;;
        dot) tar -czf "$fixture_archive" -C "$stage" "./$fixture_binary" ;;
        multiple)
            printf '%s\n' retired >"$stage/phoxald-${fixture_target}"
            tar -czf "$fixture_archive" -C "$stage" "$fixture_binary" "phoxald-${fixture_target}"
            ;;
        wrong-target)
            wrong_binary=phoxal-aarch64-unknown-linux-gnu
            mv "$stage/$fixture_binary" "$stage/$wrong_binary"
            tar -czf "$fixture_archive" -C "$stage" "$wrong_binary"
            ;;
        symlink)
            rm "$stage/$fixture_binary"
            ln -s "$test_root/archive-symlink-victim" "$stage/$fixture_binary"
            tar -czf "$fixture_archive" -C "$stage" "$fixture_binary"
            ;;
        hardlink | fifo)
            python3 - "$fixture_archive" "$fixture_binary" "$shape" <<'PY'
import sys
import tarfile

archive_path, member_name, shape = sys.argv[1:]
member = tarfile.TarInfo(member_name)
member.mode = 0o755
if shape == "hardlink":
    member.type = tarfile.LNKTYPE
    member.linkname = "/etc/passwd"
else:
    member.type = tarfile.FIFOTYPE
with tarfile.open(archive_path, "w:gz") as archive:
    archive.addfile(member)
PY
            ;;
        *) fail_test "unknown archive shape $shape" ;;
    esac
    make_checksum "$fixture_archive"
)

run_installer() (
    run_prefix=$1
    run_home=$2
    run_os=$3
    run_arch=$4
    if [ "$run_home" = __unset__ ]; then
        unset HOME
    else
        HOME=$run_home
        export HOME
    fi
    FAKE_UNAME_OS=$run_os
    FAKE_UNAME_ARCH=$run_arch
    FIXTURE_ROOT=$fixtures
    NO_COLOR=1
    PATH="$fake_bin:$PATH"
    PHOXAL_CLI_VERSION="v$version"
    PREFIX=$run_prefix
    export FAKE_UNAME_OS FAKE_UNAME_ARCH FIXTURE_ROOT NO_COLOR PATH
    export PHOXAL_CLI_VERSION PREFIX
    sh "$repo_root/install.sh"
)

must_succeed() (
    result_file=$1
    shift
    if ! run_installer "$@" >"$result_file" 2>&1; then
        sed -n '1,200p' "$result_file" >&2
        fail_test "installer unexpectedly failed"
    fi
)

must_fail() (
    result_file=$1
    shift
    if run_installer "$@" >"$result_file" 2>&1; then
        fail_test "installer unexpectedly succeeded"
    fi
)

assert_no_file_or_link() {
    if [ -e "$1" ] || [ -L "$1" ]; then
        fail_test "$1 unexpectedly exists"
    fi
}

# A valid release installs the exact bytes and removes the regular legacy
# sibling. The public result names only the one installed tool.
make_archive "$linux_target" one
install_root="$test_root/install"
mkdir -p "$install_root/bin"
printf '%s\n' legacy >"$install_root/bin/phoxald"
must_succeed "$test_root/install.out" "$install_root" "$test_root/home" Linux x86_64
cmp -s "$expected_payload" "$install_root/bin/phoxal" || fail_test "installed bytes differ"
[ -x "$install_root/bin/phoxal" ] || fail_test "installed phoxal is not executable"
[ "$("$install_root/bin/phoxal" --version)" = "phoxal 1.2.3" ] ||
    fail_test "installed phoxal produced unexpected output"
assert_no_file_or_link "$install_root/bin/phoxald"
grep -F "phoxal v${version} installed" "$test_root/install.out" >/dev/null ||
    fail_test "single-binary success message is missing"

# A checksum mismatch fails before creating the requested install tree.
bad_checksum_root="$test_root/bad-checksum"
printf '%s\n' '0000000000000000000000000000000000000000000000000000000000000000  archive' \
    >"$(archive_path "$linux_target").sha256"
must_fail "$test_root/bad-checksum.out" "$bad_checksum_root" "$test_root/home" Linux x86_64
[ ! -e "$bad_checksum_root" ] || fail_test "bad checksum mutated the install tree"
grep -F 'checksum mismatch' "$test_root/bad-checksum.out" >/dev/null ||
    fail_test "bad checksum failure was not reported"

# Only the expected regular root member is accepted.
for bad_shape in multiple wrong-target symlink hardlink fifo; do
    make_archive "$linux_target" "$bad_shape"
    bad_root="$test_root/archive-$bad_shape"
    must_fail "$test_root/$bad_shape.out" "$bad_root" "$test_root/home" Linux x86_64
    [ ! -e "$bad_root" ] || fail_test "$bad_shape archive mutated the install tree"
done

# A single optional ./ prefix is accepted without widening the member policy.
make_archive "$linux_target" dot
dot_root="$test_root/dot"
must_succeed "$test_root/dot.out" "$dot_root" "$test_root/home" Linux x86_64
cmp -s "$expected_payload" "$dot_root/bin/phoxal" || fail_test "./ archive installed wrong bytes"

# The atomic candidate replaces a destination symlink, never its victim, and
# legacy symlink cleanup also removes only the link.
make_archive "$linux_target" one
symlink_root="$test_root/destination-symlink"
mkdir -p "$symlink_root/bin"
victim="$test_root/victim"
legacy_victim="$test_root/legacy-victim"
printf '%s\n' preserve >"$victim"
printf '%s\n' preserve-legacy >"$legacy_victim"
ln -s "$victim" "$symlink_root/bin/phoxal"
ln -s "$legacy_victim" "$symlink_root/bin/phoxald"
must_succeed "$test_root/symlink-destination.out" "$symlink_root" "$test_root/home" Linux x86_64
[ ! -L "$symlink_root/bin/phoxal" ] || fail_test "destination symlink survived"
cmp -s "$expected_payload" "$symlink_root/bin/phoxal" || fail_test "symlink replacement bytes differ"
[ "$(sed -n '1p' "$victim")" = preserve ] || fail_test "destination symlink victim changed"
[ "$(sed -n '1p' "$legacy_victim")" = preserve-legacy ] ||
    fail_test "legacy symlink victim changed"
assert_no_file_or_link "$symlink_root/bin/phoxald"

# Replacing an ordinary file is byte-exact and leaves no candidate behind.
atomic_root="$test_root/atomic"
mkdir -p "$atomic_root/bin"
printf '%s\n' old >"$atomic_root/bin/phoxal"
must_succeed "$test_root/atomic.out" "$atomic_root" "$test_root/home" Linux x86_64
cmp -s "$expected_payload" "$atomic_root/bin/phoxal" || fail_test "atomic replacement bytes differ"
[ -z "$(find "$atomic_root/bin" -name '.phoxal-install.*' -print -quit)" ] ||
    fail_test "installation candidate was not cleaned"

# An existing non-file destination is foreign and rejected before replacement.
non_file_root="$test_root/non-file"
mkdir -p "$non_file_root/bin/phoxal"
must_fail "$test_root/non-file.out" "$non_file_root" "$test_root/home" Linux x86_64
[ -d "$non_file_root/bin/phoxal" ] || fail_test "non-file destination was mutated"

# A foreign legacy directory is preserved with a warning.
legacy_directory_root="$test_root/legacy-directory"
mkdir -p "$legacy_directory_root/bin/phoxald"
must_succeed "$test_root/legacy-directory.out" \
    "$legacy_directory_root" "$test_root/home" Linux x86_64
[ -d "$legacy_directory_root/bin/phoxald" ] || fail_test "legacy directory was removed"
grep -F 'is not a file; preserving it' "$test_root/legacy-directory.out" >/dev/null ||
    fail_test "legacy directory preservation was not reported"

# A non-writable requested bin falls back only when no exact requested-prefix
# executable can shadow the fallback installation.
fallback_prefix="$test_root/fallback-prefix"
fallback_home="$test_root/fallback-home"
mkdir -p "$fallback_prefix/bin"
chmod 555 "$fallback_prefix/bin"
must_succeed "$test_root/fallback.out" "$fallback_prefix" "$fallback_home" Linux x86_64
cmp -s "$expected_payload" "$fallback_home/.local/bin/phoxal" ||
    fail_test "fallback installed wrong bytes"
chmod 755 "$fallback_prefix/bin"

shadow_prefix="$test_root/shadow-prefix"
shadow_home="$test_root/shadow-home"
mkdir -p "$shadow_prefix/bin"
printf '%s\n' shadow >"$shadow_prefix/bin/phoxald"
chmod 555 "$shadow_prefix/bin"
must_fail "$test_root/shadow.out" "$shadow_prefix" "$shadow_home" Linux x86_64
[ ! -e "$shadow_home/.local" ] || fail_test "shadow refusal mutated the fallback tree"
[ "$(sed -n '1p' "$shadow_prefix/bin/phoxald")" = shadow ] ||
    fail_test "requested-prefix shadow was mutated"
chmod 755 "$shadow_prefix/bin"

# The mirror direction is guarded too: stale fallback binaries cannot shadow
# a successful requested-prefix installation.
reverse_prefix="$test_root/reverse-prefix"
reverse_home="$test_root/reverse-home"
mkdir -p "$reverse_prefix/bin" "$reverse_home/.local/bin"
printf '%s\n' old-client >"$reverse_home/.local/bin/phoxal"
printf '%s\n' retired >"$reverse_home/.local/bin/phoxald"
must_fail "$test_root/reverse-shadow.out" \
    "$reverse_prefix" "$reverse_home" Linux x86_64
[ ! -e "$reverse_prefix/bin/phoxal" ] ||
    fail_test "reverse shadow refusal installed a competing phoxal"
grep -F 'remove it or rerun with PREFIX' "$test_root/reverse-shadow.out" >/dev/null ||
    fail_test "reverse shadow refusal omitted remediation"

# Unsafe configured roots fail before mkdir, including HOME even when PREFIX
# would otherwise be writable.
(
    cd "$test_root"
    must_fail "$test_root/unsafe-prefix.out" relative-prefix "$test_root/home" Linux x86_64
)
[ ! -e "$test_root/relative-prefix" ] || fail_test "unsafe PREFIX was created"
unsafe_home_prefix="$test_root/unsafe-home-prefix"
mkdir -p "$unsafe_home_prefix/bin"
chmod 555 "$unsafe_home_prefix/bin"
must_fail "$test_root/unsafe-home.out" \
    "$unsafe_home_prefix" relative-home Linux x86_64
[ ! -e "$unsafe_home_prefix/bin/phoxal" ] ||
    fail_test "unsafe HOME allowed installation"
chmod 755 "$unsafe_home_prefix/bin"

# HOME is irrelevant when the requested prefix is already usable.
home_unset_root="$test_root/home-unset"
mkdir -p "$home_unset_root/bin"
(
    unset HOME
    must_succeed "$test_root/home-unset.out" \
        "$home_unset_root" __unset__ Linux x86_64
)
cmp -s "$expected_payload" "$home_unset_root/bin/phoxal" ||
    fail_test "HOME-unset requested-prefix install produced wrong bytes"

# Repeated and trailing separators are normalized before the bin path is
# created, rather than turning a harmless spelling difference into a failure.
normalized_root="$test_root/normalized"
must_succeed "$test_root/normalized.out" \
    "$test_root//normalized///" "$test_root//normalized-home///" Linux x86_64
cmp -s "$expected_payload" "$normalized_root/bin/phoxal" ||
    fail_test "normalized PREFIX installed wrong bytes"

# Darwin arm64 selects and installs the Darwin release member.
make_archive "$darwin_target" one
darwin_root="$test_root/darwin"
must_succeed "$test_root/darwin.out" "$darwin_root" "$test_root/home" Darwin arm64
cmp -s "$expected_payload" "$darwin_root/bin/phoxal" || fail_test "Darwin bytes differ"
grep -F 'Darwin arm64 -> aarch64-apple-darwin' "$test_root/darwin.out" >/dev/null ||
    fail_test "Darwin target was not reported"

printf '%s\n' 'installer tests passed'

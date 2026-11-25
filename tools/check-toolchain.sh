#!/bin/sh
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
version_file=${KRS_ODIN_VERSION_FILE:-$repo/ODIN_VERSION}
libgit2_floor=1.0

fail() {
    printf 'krs: %s\n' "$1" >&2
    exit 1
}

command -v odin >/dev/null || fail 'install Odin'
actual=$(odin version | sed 's/^odin version //')
actual_date=${actual%%:*}
actual_hash=${actual#*:}
expected=$(cat "$version_file")
expected_date=${expected%%:*}
expected_hash=${expected#*:}

case "$expected_hash" in
    "$actual_hash"*) hash_ok=1 ;;
    *) case "$actual_hash" in
        "$expected_hash"*) hash_ok=1 ;;
        *) hash_ok=0 ;;
    esac ;;
esac
if [ "$actual_date" != "$expected_date" ] || [ "$hash_ok" = 0 ]; then
    printf 'krs: warning: built with Odin %s; tested with %s (ODIN_VERSION)\n' \
        "$actual" "$expected" >&2
    if [ "${KRS_STRICT_TOOLCHAIN:-0}" = 1 ]; then
        exit 1
    fi
fi

command -v git >/dev/null || fail 'install git'
pkg-config --atleast-version="$libgit2_floor" libgit2 ||
    fail "install libgit2 $libgit2_floor or newer and make it available to pkg-config"
pkg-config --exists sqlite3 || fail 'install SQLite and make it available to pkg-config'
root=${ODIN_ROOT:-$(odin root)}
test -d "${root%/}/shared/kakunou" || fail "shared:kakunou is missing from ${root%/}/shared"

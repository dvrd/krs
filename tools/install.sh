#!/bin/sh
set -eu

out="${KRS_CHECK_DIR:-${TMPDIR:-/tmp}/krs-check}"
bin_dir="${KRS_INSTALL_DIR:-$HOME/.local/bin}"
destination="$bin_dir/krs"
spinner_pid=
build_log=
staged=

icon() {
    if [ -t 1 ] && [ "${TERM:-}" != dumb ]; then
        if [ -z "${NO_COLOR:-}" ]; then
            printf '\033[%sm%s\033[0m  ' "$1" "$2"
        else
            printf '%s  ' "$2"
        fi
    fi
}

fail() {
    icon 31 '✕' >&2
    printf 'krs: %s\n' "$1" >&2
    exit "${2:-1}"
}

animate_build() {
    while :; do
        for frame in '⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏'; do
            printf '\r\033[2K\033[31m%s\033[0m  Building KRS' "$frame" >&2
            sleep 0.09
        done
    done
}

stop_animation() {
    if [ -n "$spinner_pid" ]; then
        kill "$spinner_pid" 2>/dev/null || :
        wait "$spinner_pid" 2>/dev/null || :
        spinner_pid=
        printf '\r\033[2K' >&2
    fi
}

cleanup() {
    stop_animation
    if [ -n "$build_log" ]; then
        rm -f "$build_log"
    fi
    if [ -n "$staged" ]; then
        rm -f "$staged"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [ -d "$destination" ]; then
    fail "cannot replace directory $destination"
fi

build_status=0
if [ -t 1 ] && [ -t 2 ] && [ "${TERM:-}" != dumb ] &&
   [ -z "${NO_COLOR:-}" ] && [ -z "${KRS_NO_ANIMATION:-}" ]; then
    build_log=$(mktemp "${TMPDIR:-/tmp}/krs-build.XXXXXX")
    animate_build &
    spinner_pid=$!
    task build QUIET=true > "$build_log" 2>&1 || build_status=$?
    stop_animation
    cat "$build_log" >&2
else
    task build || build_status=$?
fi
if [ "$build_status" -ne 0 ]; then
    fail 'could not build KRS' "$build_status"
fi

mkdir -p "$bin_dir" || fail "cannot create $bin_dir"
staged=$(mktemp "$bin_dir/.krs.XXXXXX") || fail "cannot stage $destination"
install -m 755 "$out/krs" "$staged" || fail "cannot copy KRS to $destination"
mv -f "$staged" "$destination" || fail "cannot replace $destination"
icon 32 '✓'
printf 'krs: installed %s\n' "$destination"

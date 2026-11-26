#!/bin/sh
# Checks that tests/unit mirrors src: one tests/unit/<x>_test.odin per
# src/<x>.odin, and nothing in tests/unit or tests/e2e out of place.
set -eu

cd "$(dirname "$0")/.."

# src files still waiting for unit tests; remove each as its
# tests/unit/<x>_test.odin lands. Must end empty.
pending="apply commands doctor_process fetch journal lookup plan recover resolve vendor"

status=0

problem() {
	printf 'check-test-layout: %s\n' "$1" >&2
	status=1
}

is_pending() {
	for name in $pending; do
		[ "$name" = "$1" ] && return 0
	done
	return 1
}

for source in src/*.odin; do
	name=${source#src/}
	name=${name%.odin}
	if [ ! -f "tests/unit/${name}_test.odin" ] && ! is_pending "$name"; then
		problem "src/$name.odin has no tests/unit/${name}_test.odin"
	fi
done

for name in $pending; do
	if [ -f "tests/unit/${name}_test.odin" ]; then
		problem "$name has tests/unit/${name}_test.odin; remove it from pending"
	fi
done

for test in tests/unit/*.odin tests/e2e/*.odin; do
	[ -e "$test" ] || continue
	case $test in
	*_test.odin) ;;
	*) problem "$test is not named *_test.odin" ;;
	esac
done

for test in tests/unit/*_test.odin; do
	[ -e "$test" ] || continue
	name=${test#tests/unit/}
	name=${name%_test.odin}
	if [ ! -f "src/$name.odin" ]; then
		problem "$test has no src/$name.odin"
	fi
	if ! grep -q '^@(test)' "$test"; then
		problem "$test has no @(test)"
	fi
done

for test in tests/unit/*.odin; do
	[ -e "$test" ] || continue
	if grep -Eq '(^|[^A-Za-z0-9_.])(fixtures\.)?(run|run_in)\(' "$test"; then
		problem "$test calls run or run_in; unit tests call procedures, not commands"
	fi
done

exit "$status"

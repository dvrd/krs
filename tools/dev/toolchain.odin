package main

import "core:fmt"
import "core:os"
import "core:strings"

// libgit2 1.2 introduced git_remote_set_instance_url.
LIBGIT2_FLOOR :: "1.2"

// toolchain_matches reports whether an `odin version` string agrees with the
// recorded ODIN_VERSION: equal dates, and one non-empty hash a prefix of the other.
toolchain_matches :: proc(actual, expected: string) -> bool {
	actual_date, actual_hash := split_version(strings.trim_space(actual))
	expected_date, expected_hash := split_version(strings.trim_space(expected))

	if actual_date != expected_date {
		return false
	}

	if actual_hash == "" || expected_hash == "" {
		return false
	}

	return strings.has_prefix(expected_hash, actual_hash) ||
		strings.has_prefix(actual_hash, expected_hash)
}

split_version :: proc(version: string) -> (date, hash: string) {
	colon := strings.index_byte(version, ':')
	if colon < 0 {
		return version, ""
	}

	date = version[:colon]
	hash = version[colon + 1:]
	assert(len(date) + len(hash) + 1 == len(version))
	return date, hash
}

toolchain :: proc() -> bool {
	out, started := capture({"odin", "version"})
	if !started {
		fail("install Odin")
		return false
	}

	actual := strings.trim_space(strings.trim_prefix(strings.trim_space(out.text), "odin version "))
	version_file := os.get_env("KRS_ODIN_VERSION_FILE", context.allocator)
	if version_file == "" {
		version_file = "ODIN_VERSION"
	}

	data, read_err := os.read_entire_file(version_file, context.allocator)
	if read_err != nil {
		fail(fmt.tprintf("cannot read %s", version_file))
		return false
	}

	expected := strings.trim_space(string(data))
	if !toolchain_matches(actual, expected) {
		fmt.eprintfln("krs: warning: built with Odin %s; tested with %s (ODIN_VERSION)", actual, expected)
		if os.get_env("KRS_STRICT_TOOLCHAIN", context.allocator) == "1" {
			return false
		}
	}

	if _, found := capture({"git", "--version"}); !found {
		fail("install git")
		return false
	}

	atleast, pkg_found := capture({"pkg-config", "--atleast-version=" + LIBGIT2_FLOOR, "libgit2"})
	if !pkg_found || atleast.code != 0 {
		fail("install libgit2 " + LIBGIT2_FLOOR + " or newer and make it available to pkg-config")
		return false
	}

	sqlite, _ := capture({"pkg-config", "--exists", "sqlite3"})
	if sqlite.code != 0 {
		fail("install SQLite and make it available to pkg-config")
		return false
	}

	root := os.get_env("ODIN_ROOT", context.allocator)
	if root == "" {
		root = strings.trim_space(capture_text({"odin", "root"}))
	}

	root = strings.trim_right(root, "/")
	if !os.is_dir(strings.concatenate({root, "/shared/kakunou"})) {
		fail(fmt.tprintf("shared:kakunou is missing from %s/shared", root))
		return false
	}
	return true
}

Capture :: struct {
	text: string,
	code: int,
}

// capture runs a command and returns its stdout and exit code. started is
// false when the executable could not be run at all.
capture :: proc(command: []string) -> (result: Capture, started: bool) {
	assert(len(command) > 0)

	state, stdout, _, err := os.process_exec({command = command}, context.allocator)
	if err != nil {
		return {}, false
	}

	assert(state.exited)
	return Capture{text = string(stdout), code = state.exit_code}, true
}

capture_text :: proc(command: []string) -> string {
	result, _ := capture(command)
	return result.text
}

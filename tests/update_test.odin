package tests

import "core:testing"

import krs "../src"

@(test)
update_all_is_removed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release(&fixture, "beta", "v1.0.1")

	result := run(&fixture, "", "update", "--all", "--yes")
	testing.expect_value(t, result.code, krs.EXIT_USAGE)
	expect_contains(&fixture, result.err, "--all was removed; use krs update -u -t semver")
	expect_release(&fixture, "beta", "v1.0.0")
}

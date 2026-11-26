package e2e

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

Misuse :: struct {
	arguments: []string,
	code:      int,
	text:      string,
}

@(test)
cli_rejects_misuse :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	table := []Misuse {
		{{"--bogus"}, krs.EXIT_USAGE, "unknown option --bogus"},
		{{}, krs.EXIT_USAGE, "usage:"},
		{{"install", "extra"}, krs.EXIT_USAGE, "usage:"},
		{{"fetch", "owner/repo", "--yes"}, krs.EXIT_USAGE, "--yes does not apply to fetch"},
		{{"fetch", "owner/repo", "--root=/x"}, krs.EXIT_USAGE, "--root does not apply to fetch"},
		{{"fetch", "--frozen"}, krs.EXIT_USAGE, "--frozen does not apply to fetch"},
		{{"update", "beta", "--frozen"}, krs.EXIT_FAILED, "--frozen does not apply to update"},
		{{"link", "beta", "--frozen"}, krs.EXIT_FAILED, "--frozen does not apply to link"},
		{{"unlink", "beta", "--frozen"}, krs.EXIT_FAILED, "--frozen does not apply to unlink"},
		{{"link", "ls", "--yes"}, krs.EXIT_FAILED, "link ls takes only --root"},
		{{"link", ".hidden"}, krs.EXIT_FAILED, "is not a usable package name"},
		{{"pin", "beta", "--yes"}, krs.EXIT_USAGE, "--yes does not apply to pin"},
	}
	for row in table {
		result := fixtures.run(&fixture, "", ..row.arguments)
		testing.expectf(t, result.code == row.code, "%v: exit %d, want %d\nerr: %s", row.arguments, result.code, row.code, result.err)
		testing.expectf(t, strings.contains(result.err, row.text), "%v: expected \"%s\" in: %s", row.arguments, row.text, result.err)
	}
}

@(test)
cli_help_prints_usage :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	result := fixtures.run(&fixture, "", "--help")
	testing.expect_value(t, result.code, krs.EXIT_OK)
	fixtures.expect_contains(&fixture, result.out, "krs link ls")
}

@(test)
cli_version_uses_the_release_tag_format :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	// Version reporting does not require an Odin root or a valid package lock.
	os.remove_all(fixture.root)
	fixtures.write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), "invalid JSON")
	result := fixtures.run(&fixture, "", "--version")
	fixtures.expect_ok(&fixture, result)
	testing.expect(t, krs.KRS_VERSION != "")
	testing.expect_value(t, result.out, fmt.aprintf("krs %s\n", krs.KRS_VERSION))
}

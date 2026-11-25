package tests

import "core:strings"
import "core:testing"

import krs "../src"

Misuse :: struct {
	arguments: []string,
	code:      int,
	text:      string,
}

@(test)
cli_rejects_misuse :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	table := []Misuse {
		{{"--bogus"}, krs.EXIT_USAGE, "unknown option --bogus"},
		{{}, krs.EXIT_USAGE, "usage:"},
		{{"install", "extra"}, krs.EXIT_USAGE, "usage:"},
		{{"fetch", "owner/repo", "--yes"}, krs.EXIT_USAGE, "usage:"},
		{{"update", "beta", "--frozen"}, krs.EXIT_FAILED, "--frozen does not apply to update"},
		{{"link", "beta", "--frozen"}, krs.EXIT_FAILED, "--frozen does not apply to link"},
		{{"unlink", "beta", "--frozen"}, krs.EXIT_FAILED, "--frozen does not apply to unlink"},
		{{"link", "ls", "--yes"}, krs.EXIT_FAILED, "link ls takes only --root"},
		{{"link", ".hidden"}, krs.EXIT_FAILED, "is not a usable package name"},
	}
	for row in table {
		result := run(&fixture, "", ..row.arguments)
		testing.expectf(t, result.code == row.code, "%v: exit %d, want %d\nerr: %s", row.arguments, result.code, row.code, result.err)
		testing.expectf(t, strings.contains(result.err, row.text), "%v: expected \"%s\" in: %s", row.arguments, row.text, result.err)
	}
}

@(test)
cli_help_prints_usage :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	result := run(&fixture, "", "--help")
	testing.expect_value(t, result.code, krs.EXIT_OK)
	expect_contains(&fixture, result.out, "krs link ls")
}

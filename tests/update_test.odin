package tests

import "core:fmt"
import "core:strings"
import "core:testing"

import krs "../src"

// Runs `krs update` with `arguments`, expects success and returns the
// output with padding collapsed.
check_update :: proc(fixture: ^Fixture, arguments: ..string, loc := #caller_location) -> string {
	all := make([dynamic]string)
	append(&all, "update")
	append(&all, ..arguments)
	result := run(fixture, "", ..all[:])
	expect_ok(fixture, result, loc)
	return squeeze(result.out)
}

// Expects a row for each name in `present` and none for each in `absent`.
expect_rows :: proc(fixture: ^Fixture, text: string, present, absent: []string, loc := #caller_location) {
	for name in present {
		expect_contains(fixture, text, fmt.tprintf(" %s v", name), loc)
	}

	for name in absent {
		testing.expectf(fixture.t, !strings.contains(text, fmt.tprintf(" %s v", name)), "unexpected %s in: %s", name, text, loc = loc)
	}
}

// Installs beta v1.0.0 and publishes v1.0.1, v1.1.0 and v2.0.0.
release_beta_line :: proc(fixture: ^Fixture) {
	library_release(fixture, "beta", "v1.0.0")
	project_imports(fixture, "beta")
	expect_ok(fixture, run(fixture, "", "install", "--yes"))
	library_release(fixture, "beta", "v1.0.1")
	library_release(fixture, "beta", "v1.1.0")
	library_release(fixture, "beta", "v2.0.0")
}

@(test)
update_lists_without_installing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release(&fixture, "beta", "v1.1.0")

	every := check_update(&fixture)
	expect_contains(&fixture, every, "Minor\n beta v1.0.0 -> v1.1.0")
	expect_release(&fixture, "beta", "v1.0.0")

	named := check_update(&fixture, "beta")
	expect_contains(&fixture, named, "Minor\n beta v1.0.0 -> v1.1.0")
	expect_release(&fixture, "beta", "v1.0.0")
	expect_contains(&fixture, packages_text(&fixture), "\"tag\": \"v1.0.0\"")
}

@(test)
update_uses_the_project_pin_not_the_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixture_make(t)
	defer fixture_destroy(&a)

	library_release(&a, "beta", "v0.1.0")
	project_imports(&a, "beta")
	expect_ok(&a, run(&a, "", "install", "--yes"))

	b := fixture_make(t)
	defer fixture_destroy(&b)
	b.root = a.root
	b.shared = a.shared
	b.home = a.home
	b.sources = a.sources
	project_imports(&b, "beta")
	expect_ok(&b, run(&b, "", "install", "--yes"))

	library_release(&a, "beta", "v0.2.0")
	expect_ok(&b, run(&b, "", "update", "beta", "-u", "--yes"))
	expect_release(&a, "beta", "v0.2.0")

	// The root holds v0.2.0, but project A still records v0.1.0.
	expect_contains(&a, check_update(&a), "beta v0.1.0 -> v0.2.0")
}

@(test)
update_groups_by_change_kind :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	library_release(&fixture, "gamma", "v0.1.0")
	library_release(&fixture, "delta", "v1.0.0")
	library_release(&fixture, "eps", "v1.0.0")
	project_imports(&fixture, "beta", "gamma", "delta", "eps")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release(&fixture, "beta", "v2.0.0")
	library_release(&fixture, "gamma", "v0.2.0")
	library_release(&fixture, "delta", "v1.1.0")
	library_release(&fixture, "eps", "v1.0.1")

	text := check_update(&fixture)
	expect_contains(&fixture, text, "Patch\n eps v1.0.0 -> v1.0.1\n")
	expect_contains(&fixture, text, "Minor\n delta v1.0.0 -> v1.1.0\n")
	expect_contains(&fixture, text, "Major version zero\n gamma v0.1.0 -> v0.2.0\n")
	expect_contains(&fixture, text, "Major\n beta v1.0.0 -> v2.0.0\n")
	expect_contains(&fixture, text, "run krs update -u to upgrade .krs/packages.json")

	patch := strings.index(text, "Patch\n")
	minor := strings.index(text, "Minor\n")
	zero := strings.index(text, "Major version zero\n")
	major := strings.index(text, "Major\n")
	testing.expectf(t, 0 <= patch && patch < minor && minor < zero && zero < major, "headers out of order: %s", text)
}

@(test)
update_targets :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	release_beta_line(&fixture)

	expect_contains(&fixture, check_update(&fixture, "-t", "patch"), "beta v1.0.0 -> v1.0.1\n")
	expect_contains(&fixture, check_update(&fixture, "--target=patch"), "beta v1.0.0 -> v1.0.1\n")
	expect_contains(&fixture, check_update(&fixture, "--target", "patch"), "beta v1.0.0 -> v1.0.1\n")
	expect_contains(&fixture, check_update(&fixture, "-t", "minor"), "beta v1.0.0 -> v1.1.0\n")
	expect_contains(&fixture, check_update(&fixture, "-t", "semver"), "beta v1.0.0 -> v1.1.0\n")
	expect_contains(&fixture, check_update(&fixture, "-t", "latest"), "beta v1.0.0 -> v2.0.0\n")
	expect_contains(&fixture, check_update(&fixture, "-t", "greatest"), "beta v1.0.0 -> v2.0.0\n")
	expect_contains(&fixture, check_update(&fixture), "beta v1.0.0 -> v2.0.0\n")

	// Nothing newer within the target.
	other := fixture_make(t)
	defer fixture_destroy(&other)
	library_release(&other, "beta", "v1.0.0")
	project_imports(&other, "beta")
	expect_ok(&other, run(&other, "", "install", "--yes"))
	library_release(&other, "beta", "v2.0.0")
	expect_contains(&other, check_update(&other, "-t", "minor"), "no upgrades for --target minor")
}

@(test)
update_target_newest_uses_commit_time :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release_at(&fixture, "beta", "v1.0.0", "2020-01-01 00:00:00 +0000")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release_at(&fixture, "beta", "v2.0.0", "2021-01-01 00:00:00 +0000")
	library_release_at(&fixture, "beta", "v1.1.0", "2022-01-01 00:00:00 +0000")

	expect_contains(&fixture, check_update(&fixture, "-t", "newest"), "beta v1.0.0 -> v1.1.0\n")
	expect_contains(&fixture, check_update(&fixture, "-t", "latest"), "beta v1.0.0 -> v2.0.0\n")
}

@(test)
update_filters :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	for name in ([]string{"beta", "gamma", "delta"}) {
		library_release(&fixture, name, "v1.0.0")
	}
	project_imports(&fixture, "beta", "gamma", "delta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	for name in ([]string{"beta", "gamma", "delta"}) {
		library_release(&fixture, name, "v1.0.1")
	}

	expect_rows(&fixture, check_update(&fixture), {"beta", "gamma", "delta"}, {})
	expect_rows(&fixture, check_update(&fixture, "-f", "beta"), {"beta"}, {"gamma", "delta"})
	expect_rows(&fixture, check_update(&fixture, "-f", "be*"), {"beta"}, {"gamma", "delta"})
	expect_rows(&fixture, check_update(&fixture, "-f", "*ta"), {"beta", "delta"}, {"gamma"})
	expect_rows(&fixture, check_update(&fixture, "-f", "/^b/"), {"beta"}, {"gamma", "delta"})
	expect_rows(&fixture, check_update(&fixture, "-f", "!beta"), {"gamma", "delta"}, {"beta"})
	expect_rows(&fixture, check_update(&fixture, "-x", "beta"), {"gamma", "delta"}, {"beta"})
	expect_rows(&fixture, check_update(&fixture, "--reject=beta,gamma"), {"delta"}, {"beta", "gamma"})
	expect_rows(&fixture, check_update(&fixture, "-f", "beta,gamma"), {"beta", "gamma"}, {"delta"})
	expect_rows(&fixture, check_update(&fixture, "--filter", "beta delta"), {"beta", "delta"}, {"gamma"})
	expect_rows(&fixture, check_update(&fixture, "beta"), {"beta"}, {"gamma", "delta"})
	expect_rows(&fixture, check_update(&fixture, "beta", "delta"), {"beta", "delta"}, {"gamma"})
}

@(test)
update_version_filters :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	library_release(&fixture, "gamma", "v0.1.0")
	project_imports(&fixture, "beta", "gamma")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release(&fixture, "beta", "v1.1.0")
	library_release(&fixture, "gamma", "v0.1.1")

	expect_rows(&fixture, check_update(&fixture, "--filter-version", "v1.*"), {"beta"}, {"gamma"})
	expect_rows(&fixture, check_update(&fixture, "--reject-version", "/^v0\\./"), {"beta"}, {"gamma"})
	expect_rows(&fixture, check_update(&fixture, "--filter-version=/^v0\\./"), {"gamma"}, {"beta"})
}

@(test)
update_invalid_pattern_and_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	expect_failure(&fixture, run(&fixture, "", "update", "-f", "/[/"), "/[/ is not a valid pattern")
	expect_failure(&fixture, run(&fixture, "", "update", "-x", "/unclosed"), "is not a valid pattern")

	Usage :: struct {
		arguments: []string,
		text:      string,
	}
	table := []Usage {
		{{"update", "-t", "sideways"}, "sideways is not a target"},
		{{"update", "-e", "3"}, "3 is not an error level; use 1 or 2"},
		{{"update", "--format", "nope"}, "nope is not a format"},
		{{"update", "--format=group,nope"}, "nope is not a format"},
		{{"update", "-l", "loud"}, "loud is not a log level"},
		{{"update", "-t"}, "-t needs a value"},
		{{"update", "--filter"}, "--filter needs a value"},
		{{"update", "--yes=1"}, "unknown option --yes=1"},
		{{"install", "-t", "patch"}, "-t only applies to update"},
		{{"status", "--json-upgraded"}, "--json-upgraded only applies to update"},
		{{"update", "-u"}, "-u needs exactly one package name for now"},
		{{"update", "-u", "beta", "gamma"}, "-u needs exactly one package name for now"},
	}
	for row in table {
		result := run(&fixture, "", ..row.arguments)
		testing.expectf(t, result.code == krs.EXIT_USAGE, "%v: exit %d, want %d\nerr: %s", row.arguments, result.code, krs.EXIT_USAGE, result.err)
		expect_contains(&fixture, result.err, row.text)
	}

	bad_tag := run(&fixture, "", "update", "beta@latest")
	expect_failure(&fixture, bad_tag, "latest is not a vMAJOR.MINOR.PATCH tag")
}

@(test)
update_name_with_tag_targets_that_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	release_beta_line(&fixture)

	text := check_update(&fixture, "beta@v1.0.1")
	expect_contains(&fixture, text, "beta v1.0.0 -> v1.0.1\n")
	testing.expect(t, !strings.contains(text, "v2.0.0"))
	expect_release(&fixture, "beta", "v1.0.0")

	missing := run(&fixture, "", "update", "beta@v9.9.9")
	expect_failure(&fixture, missing, "could not check 1 package(s) for updates")
	expect_contains(&fixture, missing.out, "beta has no tag v9.9.9")
}

@(test)
update_shows_pinned_packages_as_held :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	release_beta_line(&fixture)
	pinned, replaced := strings.replace_all(packages_text(&fixture), "\"tag\": \"v1.0.0\",", "\"tag\": \"v1.0.0\",\n      \"pinned\": true,")
	testing.expect(t, replaced)
	write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), pinned)

	text := check_update(&fixture)
	expect_contains(&fixture, text, "Pinned\n beta v1.0.0 (pinned; v2.0.0 available)\n")
	testing.expect(t, !strings.contains(text, "->"))
	testing.expect(t, !strings.contains(text, "krs update -u"))
	testing.expect(t, !strings.contains(text, "Major"))
}

@(test)
update_global_checks_the_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	library_release(&fixture, "gamma", "v1.0.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	// Another project on the same root installs gamma.
	other := fixture
	other.project = krs.path_join(fixture.base, "other-app")
	project_imports(&other, "gamma")
	expect_ok(&other, run(&other, "", "install", "--yes"))
	library_release(&fixture, "beta", "v1.0.1")
	library_release(&fixture, "gamma", "v1.0.1")

	expect_rows(&fixture, check_update(&fixture), {"beta"}, {"gamma"})
	expect_rows(&fixture, check_update(&fixture, "-g"), {"beta", "gamma"}, {})
	expect_rows(&fixture, check_update(&fixture, "--global", "gamma"), {"gamma"}, {"beta"})
}

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

// The line of `text` that contains `part`, or "".
line_with :: proc(text, part: string) -> string {
	for line in strings.split_lines(text) {
		if strings.contains(line, part) {
			return line
		}
	}
	return ""
}

@(test)
update_formats :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	release_beta_line(&fixture)

	lines := run(&fixture, "", "update", "--format", "lines")
	expect_ok(&fixture, lines)
	testing.expect_value(t, lines.out, "beta@v2.0.0\n")

	// `lines` wins over every other format.
	mixed := run(&fixture, "", "update", "--format=group,time,lines")
	expect_ok(&fixture, mixed)
	testing.expect_value(t, mixed.out, "beta@v2.0.0\n")

	timed := line_with(check_update(&fixture, "--format", "time"), "beta v1.0.0 -> v2.0.0")
	testing.expectf(t, len(timed) > 10, "no dated row: %q", timed)
	if len(timed) > 10 {
		date := timed[len(timed) - 10:]
		for character, index in transmute([]byte)date {
			if index == 4 || index == 7 {
				testing.expectf(t, character == '-', "not a date: %q", date)
			} else {
				testing.expectf(t, character >= '0' && character <= '9', "not a date: %q", date)
			}
		}
	}

	flat := check_update(&fixture, "--format", "no-group")
	expect_contains(&fixture, flat, " beta v1.0.0 -> v2.0.0\n")
	testing.expect(t, !strings.contains(flat, "Major"))

	// A local source has no repository link to show.
	local := line_with(check_update(&fixture, "--format", "repo,diff"), "beta v1.0.0")
	testing.expect(t, strings.has_suffix(local, "-> v2.0.0"), local)

	github := fixture_make(t)
	defer fixture_destroy(&github)
	github_fixture_release(&github, "dvrd", "project-kessel", "v1.0.0")
	project_imports(&github, "kessel")
	write_file(t, krs.path_join(github.home, krs.CONFIG_PATH),
		`{"libs":{"kessel":{"source":"github","target":"dvrd/project-kessel"}}}`)
	expect_ok(&github, run(&github, "", "install", "--yes"))
	github_fixture_release(&github, "dvrd", "project-kessel", "v1.1.0")

	repo := check_update(&github, "--fetch", "--format", "repo")
	expect_contains(&github, repo, "kessel v1.0.0 -> v1.1.0 https://github.com/dvrd/project-kessel.git\n")
	diff := check_update(&github, "--format", "diff")
	expect_contains(&github, diff, "kessel v1.0.0 -> v1.1.0 https://github.com/dvrd/project-kessel/compare/v1.0.0...v1.1.0\n")

	// The root holds another tag than this project records.
	b := fixture_make(t)
	defer fixture_destroy(&b)
	b.root = fixture.root
	b.shared = fixture.shared
	b.home = fixture.home
	b.sources = fixture.sources
	project_imports(&b, "beta")
	expect_ok(&b, run(&b, "", "install", "--yes"))
	expect_ok(&b, run(&b, "", "update", "beta@v1.1.0", "-u", "--yes"))
	installed := check_update(&fixture, "--format", "installed-version")
	expect_contains(&fixture, installed, "beta v1.0.0 -> v2.0.0 (installed v1.1.0)\n")
	testing.expect(t, !strings.contains(check_update(&b, "--format", "installed-version"), "(installed"))
}

@(test)
update_colors_when_forced :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	library_release(&fixture, "gamma", "v1.0.0")
	project_imports(&fixture, "beta", "gamma")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release(&fixture, "beta", "v2.0.0")
	library_release(&fixture, "gamma", "v1.0.1")

	plain := run(&fixture, "", "update")
	expect_ok(&fixture, plain)
	testing.expect(t, !strings.contains(plain.out, "\x1b["))

	colored := run(&fixture, "", "update", "--color")
	expect_ok(&fixture, colored)
	expect_contains(&fixture, colored.out, "\x1b[31mv2.0.0\x1b[0m")
	expect_contains(&fixture, colored.out, "\x1b[32mv1.0.1\x1b[0m")
}

@(test)
update_error_level :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	none := run(&fixture, "", "update", "-e", "2")
	testing.expect_value(t, none.code, krs.EXIT_OK)

	library_release(&fixture, "beta", "v1.0.1")
	strict := run(&fixture, "", "update", "-e", "2")
	testing.expect_value(t, strict.code, krs.EXIT_FAILED)
	testing.expect_value(t, strict.err, "")
	expect_contains(&fixture, squeeze(strict.out), "beta v1.0.0 -> v1.0.1")
	testing.expect_value(t, run(&fixture, "", "update", "--error-level=2").code, krs.EXIT_FAILED)
	testing.expect_value(t, run(&fixture, "", "update", "-e", "1").code, krs.EXIT_OK)
	testing.expect_value(t, run(&fixture, "", "update").code, krs.EXIT_OK)

	// A pinned package is not an available upgrade.
	expect_ok(&fixture, run(&fixture, "", "pin", "beta"))
	testing.expect_value(t, run(&fixture, "", "update", "-e", "2").code, krs.EXIT_OK)
}

@(test)
update_log_levels :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	release_beta_line(&fixture)

	silent := run(&fixture, "", "update", "-s")
	testing.expect_value(t, silent.code, krs.EXIT_OK)
	testing.expect_value(t, silent.out, "")
	testing.expect_value(t, run(&fixture, "", "update", "--silent").out, "")

	warn := run(&fixture, "", "update", "-l", "warn")
	expect_ok(&fixture, warn)
	expect_contains(&fixture, squeeze(warn.out), "beta v1.0.0 -> v2.0.0")
	testing.expect(t, !strings.contains(warn.out, "krs update -u"))

	// No repository: a warning on stdout and a failure on stderr.
	fixture_config(&fixture, {krs.path_join(fixture.base, "other-sources")})
	normal := run(&fixture, "", "update")
	expect_failure(&fixture, normal, "could not check 1 package(s)")
	expect_contains(&fixture, normal.out, "warning:")

	minimal := run(&fixture, "", "update", "--loglevel=minimal")
	expect_failure(&fixture, minimal, "could not check 1 package(s)")
	testing.expect(t, !strings.contains(minimal.out, "warning:"), minimal.out)

	errors := run(&fixture, "", "update", "-l", "error")
	expect_failure(&fixture, errors, "could not check 1 package(s)")
	testing.expect_value(t, errors.out, "")

	quiet := run(&fixture, "", "update", "-s")
	testing.expect_value(t, quiet.code, krs.EXIT_FAILED)
	testing.expect_value(t, quiet.out, "")
	testing.expect_value(t, quiet.err, "")
}

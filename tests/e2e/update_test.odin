package e2e

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
repair_flag_is_rejected_elsewhere :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	misplaced := fixtures.run(&fixture, "", "update", "--repair")
	testing.expect_value(t, misplaced.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, misplaced.err, "--repair only applies to install")

	combined := fixtures.run(&fixture, "", "install", "--repair", "--frozen")
	testing.expect_value(t, combined.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, combined.err, "cannot be combined")
}

@(test)
moved_tag_is_refused ::proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	repository := krs.path_join(fixture.sources, "beta")
	fixtures.git(t, repository, "commit", "--quiet", "--allow-empty", "-m", "rewritten")
	fixtures.git(t, repository, "tag", "--force", "v0.1.0")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "beta@v0.1.0", "-u", "--yes"), "a published tag must not move")

	other := krs.path_join(fixture.base, "other-root")
	os.make_directory_all(other)
	result := fixtures.run(&fixture, "", "install", "--yes", fmt.aprintf("--root=%s", other))
	fixtures.expect_failure(&fixture, result, "a published tag must not move")
	testing.expect(t, !os.exists(krs.path_join(other, "shared/beta")))
}

// Runs `krs update` with `arguments`, expects success and returns the
// output with padding collapsed.
check_update :: proc(fixture: ^fixtures.Fixture, arguments: ..string, loc := #caller_location) -> string {
	all := make([dynamic]string)
	append(&all, "update")
	append(&all, ..arguments)
	result := fixtures.run(fixture, "", ..all[:])
	fixtures.expect_ok(fixture, result, loc)
	return fixtures.squeeze(result.out)
}

// Expects a row for each name in `present` and none for each in `absent`.
expect_rows :: proc(fixture: ^fixtures.Fixture, text: string, present, absent: []string, loc := #caller_location) {
	for name in present {
		fixtures.expect_contains(fixture, text, fmt.tprintf(" %s v", name), loc)
	}

	for name in absent {
		testing.expectf(fixture.t, !strings.contains(text, fmt.tprintf(" %s v", name)), "unexpected %s in: %s", name, text, loc = loc)
	}
}

// Installs beta v1.0.0 and publishes v1.0.1, v1.1.0 and v2.0.0.
release_beta_line :: proc(fixture: ^fixtures.Fixture) {
	fixtures.library_release(fixture, "beta", "v1.0.0")
	fixtures.project_imports(fixture, "beta")
	fixtures.expect_ok(fixture, fixtures.run(fixture, "", "install", "--yes"))
	fixtures.library_release(fixture, "beta", "v1.0.1")
	fixtures.library_release(fixture, "beta", "v1.1.0")
	fixtures.library_release(fixture, "beta", "v2.0.0")
}

@(test)
update_lists_without_installing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v1.1.0")

	every := check_update(&fixture)
	fixtures.expect_contains(&fixture, every, "Minor\n beta v1.0.0 -> v1.1.0")
	fixtures.expect_release(&fixture, "beta", "v1.0.0")

	named := check_update(&fixture, "beta")
	fixtures.expect_contains(&fixture, named, "Minor\n beta v1.0.0 -> v1.1.0")
	fixtures.expect_release(&fixture, "beta", "v1.0.0")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"tag\": \"v1.0.0\"")
}

@(test)
update_uses_the_project_pin_not_the_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&a)

	fixtures.library_release(&a, "beta", "v0.1.0")
	fixtures.project_imports(&a, "beta")
	fixtures.expect_ok(&a, fixtures.run(&a, "", "install", "--yes"))

	b := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&b)
	b.root = a.root
	b.shared = a.shared
	b.home = a.home
	b.sources = a.sources
	fixtures.project_imports(&b, "beta")
	fixtures.expect_ok(&b, fixtures.run(&b, "", "install", "--yes"))

	fixtures.library_release(&a, "beta", "v0.2.0")
	fixtures.expect_ok(&b, fixtures.run(&b, "", "update", "beta", "-u", "--yes"))
	fixtures.expect_release(&a, "beta", "v0.2.0")

	// The root holds v0.2.0, but project A still records v0.1.0.
	fixtures.expect_contains(&a, check_update(&a), "beta v0.1.0 -> v0.2.0")
}

@(test)
update_groups_by_change_kind :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.library_release(&fixture, "gamma", "v0.1.0")
	fixtures.library_release(&fixture, "delta", "v1.0.0")
	fixtures.library_release(&fixture, "eps", "v1.0.0")
	fixtures.project_imports(&fixture, "beta", "gamma", "delta", "eps")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v2.0.0")
	fixtures.library_release(&fixture, "gamma", "v0.2.0")
	fixtures.library_release(&fixture, "delta", "v1.1.0")
	fixtures.library_release(&fixture, "eps", "v1.0.1")

	text := check_update(&fixture)
	fixtures.expect_contains(&fixture, text, "Patch\n eps v1.0.0 -> v1.0.1\n")
	fixtures.expect_contains(&fixture, text, "Minor\n delta v1.0.0 -> v1.1.0\n")
	fixtures.expect_contains(&fixture, text, "Major version zero\n gamma v0.1.0 -> v0.2.0\n")
	fixtures.expect_contains(&fixture, text, "Major\n beta v1.0.0 -> v2.0.0\n")
	fixtures.expect_contains(&fixture, text, "run krs update -u to upgrade .krs/packages.json")

	patch := strings.index(text, "Patch\n")
	minor := strings.index(text, "Minor\n")
	zero := strings.index(text, "Major version zero\n")
	major := strings.index(text, "Major\n")
	testing.expectf(t, 0 <= patch && patch < minor && minor < zero && zero < major, "headers out of order: %s", text)
}

@(test)
update_targets :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	release_beta_line(&fixture)

	fixtures.expect_contains(&fixture, check_update(&fixture, "-t", "patch"), "beta v1.0.0 -> v1.0.1\n")
	fixtures.expect_contains(&fixture, check_update(&fixture, "--target=patch"), "beta v1.0.0 -> v1.0.1\n")
	fixtures.expect_contains(&fixture, check_update(&fixture, "--target", "patch"), "beta v1.0.0 -> v1.0.1\n")
	fixtures.expect_contains(&fixture, check_update(&fixture, "-t", "minor"), "beta v1.0.0 -> v1.1.0\n")
	fixtures.expect_contains(&fixture, check_update(&fixture, "-t", "semver"), "beta v1.0.0 -> v1.1.0\n")
	fixtures.expect_contains(&fixture, check_update(&fixture, "-t", "latest"), "beta v1.0.0 -> v2.0.0\n")
	fixtures.expect_contains(&fixture, check_update(&fixture, "-t", "greatest"), "beta v1.0.0 -> v2.0.0\n")
	fixtures.expect_contains(&fixture, check_update(&fixture), "beta v1.0.0 -> v2.0.0\n")

	// Nothing newer within the target.
	other := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&other)
	fixtures.library_release(&other, "beta", "v1.0.0")
	fixtures.project_imports(&other, "beta")
	fixtures.expect_ok(&other, fixtures.run(&other, "", "install", "--yes"))
	fixtures.library_release(&other, "beta", "v2.0.0")
	fixtures.expect_contains(&other, check_update(&other, "-t", "minor"), "no upgrades for --target minor")
}

@(test)
update_target_newest_uses_commit_time :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release_at(&fixture, "beta", "v1.0.0", "2020-01-01 00:00:00 +0000")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release_at(&fixture, "beta", "v2.0.0", "2021-01-01 00:00:00 +0000")
	fixtures.library_release_at(&fixture, "beta", "v1.1.0", "2022-01-01 00:00:00 +0000")

	fixtures.expect_contains(&fixture, check_update(&fixture, "-t", "newest"), "beta v1.0.0 -> v1.1.0\n")
	fixtures.expect_contains(&fixture, check_update(&fixture, "-t", "latest"), "beta v1.0.0 -> v2.0.0\n")
}

@(test)
update_newest_skips_lower_versions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release_at(&fixture, "beta", "v1.2.0", "2020-01-01 00:00:00 +0000")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release_at(&fixture, "beta", "v1.3.0", "2021-01-01 00:00:00 +0000")
	fixtures.library_release_at(&fixture, "beta", "v1.1.0", "2022-01-01 00:00:00 +0000")

	// v1.1.0 is the newest commit but lower than the current v1.2.0.
	fixtures.expect_contains(&fixture, check_update(&fixture, "-t", "newest"), "beta v1.2.0 -> v1.3.0")
}

@(test)
update_rejects_an_empty_negation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "--filter-version", "!"), "! is not a valid pattern")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "--filter", "!"), "! is not a valid pattern")
}

@(test)
update_filters :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	for name in ([]string{"beta", "gamma", "delta"}) {
		fixtures.library_release(&fixture, name, "v1.0.0")
	}
	fixtures.project_imports(&fixture, "beta", "gamma", "delta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	for name in ([]string{"beta", "gamma", "delta"}) {
		fixtures.library_release(&fixture, name, "v1.0.1")
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
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.library_release(&fixture, "gamma", "v0.1.0")
	fixtures.project_imports(&fixture, "beta", "gamma")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v1.1.0")
	fixtures.library_release(&fixture, "gamma", "v0.1.1")

	expect_rows(&fixture, check_update(&fixture, "--filter-version", "v1.*"), {"beta"}, {"gamma"})
	expect_rows(&fixture, check_update(&fixture, "--reject-version", "/^v0\\./"), {"beta"}, {"gamma"})
	expect_rows(&fixture, check_update(&fixture, "--filter-version=/^v0\\./"), {"gamma"}, {"beta"})
}

@(test)
update_invalid_pattern_and_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "-f", "/[/"), "/[/ is not a valid pattern")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "-x", "/unclosed"), "is not a valid pattern")

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
	}
	for row in table {
		result := fixtures.run(&fixture, "", ..row.arguments)
		testing.expectf(t, result.code == krs.EXIT_USAGE, "%v: exit %d, want %d\nerr: %s", row.arguments, result.code, krs.EXIT_USAGE, result.err)
		fixtures.expect_contains(&fixture, result.err, row.text)
	}

	bad_tag := fixtures.run(&fixture, "", "update", "beta@latest")
	fixtures.expect_failure(&fixture, bad_tag, "latest is not a vMAJOR.MINOR.PATCH tag")
}

@(test)
update_name_with_tag_targets_that_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	release_beta_line(&fixture)

	text := check_update(&fixture, "beta@v1.0.1")
	fixtures.expect_contains(&fixture, text, "beta v1.0.0 -> v1.0.1\n")
	testing.expect(t, !strings.contains(text, "v2.0.0"))
	fixtures.expect_release(&fixture, "beta", "v1.0.0")

	missing := fixtures.run(&fixture, "", "update", "beta@v9.9.9")
	fixtures.expect_failure(&fixture, missing, "could not check 1 package(s) for updates")
	fixtures.expect_contains(&fixture, missing.out, "beta has no tag v9.9.9")
}

@(test)
update_shows_pinned_packages_as_held :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	release_beta_line(&fixture)
	pinned, replaced := strings.replace_all(fixtures.packages_text(&fixture), "\"tag\": \"v1.0.0\",", "\"tag\": \"v1.0.0\",\n      \"pinned\": true,")
	testing.expect(t, replaced)
	fixtures.write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), pinned)

	text := check_update(&fixture)
	fixtures.expect_contains(&fixture, text, "Pinned\n beta v1.0.0 (pinned; v2.0.0 available)\n")
	testing.expect(t, !strings.contains(text, "->"))
	testing.expect(t, !strings.contains(text, "krs update -u"))
	testing.expect(t, !strings.contains(text, "Major"))

	upgraded := fixtures.run(&fixture, "", "update", "--json-upgraded")
	fixtures.expect_ok(&fixture, upgraded)
	held: map[string]string
	testing.expect_value(t, json.unmarshal(transmute([]byte)upgraded.out, &held), nil)
	testing.expect_value(t, len(held), 0)
}

@(test)
update_global_checks_the_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.library_release(&fixture, "gamma", "v1.0.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	// Another project on the same root installs gamma.
	other := fixture
	other.project = krs.path_join(fixture.base, "other-app")
	fixtures.project_imports(&other, "gamma")
	fixtures.expect_ok(&other, fixtures.run(&other, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v1.0.1")
	fixtures.library_release(&fixture, "gamma", "v1.0.1")

	expect_rows(&fixture, check_update(&fixture), {"beta"}, {"gamma"})
	expect_rows(&fixture, check_update(&fixture, "-g"), {"beta", "gamma"}, {})
	expect_rows(&fixture, check_update(&fixture, "--global", "gamma"), {"gamma"}, {"beta"})
}

@(test)
update_all_is_removed :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v1.0.1")

	result := fixtures.run(&fixture, "", "update", "--all", "--yes")
	testing.expect_value(t, result.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, result.err, "--all was removed; use krs update -u -t semver")
	fixtures.expect_release(&fixture, "beta", "v1.0.0")
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
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	release_beta_line(&fixture)

	lines := fixtures.run(&fixture, "", "update", "--format", "lines")
	fixtures.expect_ok(&fixture, lines)
	testing.expect_value(t, lines.out, "beta@v2.0.0\n")

	// `lines` wins over every other format.
	mixed := fixtures.run(&fixture, "", "update", "--format=group,time,lines")
	fixtures.expect_ok(&fixture, mixed)
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
	fixtures.expect_contains(&fixture, flat, " beta v1.0.0 -> v2.0.0\n")
	testing.expect(t, !strings.contains(flat, "Major"))

	// A local source has no repository link to show.
	local := line_with(check_update(&fixture, "--format", "repo,diff"), "beta v1.0.0")
	testing.expect(t, strings.has_suffix(local, "-> v2.0.0"), local)

	github := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&github)
	fixtures.github_fixture_release(&github, "dvrd", "project-kessel", "v1.0.0")
	fixtures.project_imports(&github, "kessel")
	fixtures.write_file(t, krs.path_join(github.home, krs.CONFIG_PATH),
		`{"libs":{"kessel":{"source":"github","target":"dvrd/project-kessel"}}}`)
	fixtures.expect_ok(&github, fixtures.run(&github, "", "install", "--yes"))
	fixtures.github_fixture_release(&github, "dvrd", "project-kessel", "v1.1.0")

	repo := check_update(&github, "--fetch", "--format", "repo")
	fixtures.expect_contains(&github, repo, "kessel v1.0.0 -> v1.1.0 https://github.com/dvrd/project-kessel.git\n")
	diff := check_update(&github, "--format", "diff")
	fixtures.expect_contains(&github, diff, "kessel v1.0.0 -> v1.1.0 https://github.com/dvrd/project-kessel/compare/v1.0.0...v1.1.0\n")

	// The root holds another tag than this project records.
	b := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&b)
	b.root = fixture.root
	b.shared = fixture.shared
	b.home = fixture.home
	b.sources = fixture.sources
	fixtures.project_imports(&b, "beta")
	fixtures.expect_ok(&b, fixtures.run(&b, "", "install", "--yes"))
	fixtures.expect_ok(&b, fixtures.run(&b, "", "update", "beta@v1.1.0", "-u", "--yes"))
	installed := check_update(&fixture, "--format", "installed-version")
	fixtures.expect_contains(&fixture, installed, "beta v1.0.0 -> v2.0.0 (installed v1.1.0)\n")
	testing.expect(t, !strings.contains(check_update(&b, "--format", "installed-version"), "(installed"))
}

@(test)
update_colors_when_forced :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.library_release(&fixture, "gamma", "v1.0.0")
	fixtures.project_imports(&fixture, "beta", "gamma")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v2.0.0")
	fixtures.library_release(&fixture, "gamma", "v1.0.1")

	plain := fixtures.run(&fixture, "", "update")
	fixtures.expect_ok(&fixture, plain)
	testing.expect(t, !strings.contains(plain.out, "\x1b["))

	colored := fixtures.run(&fixture, "", "update", "--color")
	fixtures.expect_ok(&fixture, colored)
	fixtures.expect_contains(&fixture, colored.out, "\x1b[31mv2.0.0\x1b[0m")
	fixtures.expect_contains(&fixture, colored.out, "\x1b[32mv1.0.1\x1b[0m")
}

@(test)
update_error_level :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	none := fixtures.run(&fixture, "", "update", "-e", "2")
	testing.expect_value(t, none.code, krs.EXIT_OK)

	fixtures.library_release(&fixture, "beta", "v1.0.1")
	strict := fixtures.run(&fixture, "", "update", "-e", "2")
	testing.expect_value(t, strict.code, krs.EXIT_FAILED)
	testing.expect_value(t, strict.err, "")
	fixtures.expect_contains(&fixture, fixtures.squeeze(strict.out), "beta v1.0.0 -> v1.0.1")
	testing.expect_value(t, fixtures.run(&fixture, "", "update", "--error-level=2").code, krs.EXIT_FAILED)
	testing.expect_value(t, fixtures.run(&fixture, "", "update", "-e", "1").code, krs.EXIT_OK)
	testing.expect_value(t, fixtures.run(&fixture, "", "update").code, krs.EXIT_OK)

	// A pinned package is not an available upgrade.
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "beta"))
	testing.expect_value(t, fixtures.run(&fixture, "", "update", "-e", "2").code, krs.EXIT_OK)
}

@(test)
update_log_levels :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	release_beta_line(&fixture)

	silent := fixtures.run(&fixture, "", "update", "-s")
	testing.expect_value(t, silent.code, krs.EXIT_OK)
	testing.expect_value(t, silent.out, "")
	testing.expect_value(t, fixtures.run(&fixture, "", "update", "--silent").out, "")

	warn := fixtures.run(&fixture, "", "update", "-l", "warn")
	fixtures.expect_ok(&fixture, warn)
	fixtures.expect_contains(&fixture, fixtures.squeeze(warn.out), "beta v1.0.0 -> v2.0.0")
	testing.expect(t, !strings.contains(warn.out, "krs update -u"))

	// No repository: a warning on stdout and a failure on stderr.
	fixtures.fixture_config(&fixture, {krs.path_join(fixture.base, "other-sources")})
	normal := fixtures.run(&fixture, "", "update")
	fixtures.expect_failure(&fixture, normal, "could not check 1 package(s)")
	fixtures.expect_contains(&fixture, normal.out, "warning:")

	minimal := fixtures.run(&fixture, "", "update", "--loglevel=minimal")
	fixtures.expect_failure(&fixture, minimal, "could not check 1 package(s)")
	testing.expect(t, !strings.contains(minimal.out, "warning:"), minimal.out)

	errors := fixtures.run(&fixture, "", "update", "-l", "error")
	fixtures.expect_failure(&fixture, errors, "could not check 1 package(s)")
	testing.expect_value(t, errors.out, "")

	quiet := fixtures.run(&fixture, "", "update", "-s")
	testing.expect_value(t, quiet.code, krs.EXIT_FAILED)
	testing.expect_value(t, quiet.out, "")
	testing.expect_value(t, quiet.err, "")
}

@(test)
update_u_moves_an_unpinned_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.release_beta_upgrade(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v0.2.0")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"tag\": \"v0.2.0\"")
}

@(test)
update_without_u_writes_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.release_beta_upgrade(&fixture)
	packages, manifest := fixtures.packages_text(&fixture), fixtures.manifest_text(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update"))
	testing.expect_value(t, fixtures.packages_text(&fixture), packages)
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)
}

@(test)
update_u_moves_to_vendor_when_the_root_differs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&a)
	b := fixtures.pinned_divergence(&a)
	defer fixtures.fixture_destroy(&b)

	fixtures.library_release(&a, "gamma", "v0.1.1")
	before := fixtures.manifest_text(&a)
	result := fixtures.run(&a, "", "update", "-u", "--yes")
	fixtures.expect_ok(&a, result)
	fixtures.expect_contains(&a, result.out, "-collection:shared=vendor")
	fixtures.expect_contains(&a, fixtures.read_file(krs.path_join(a.project, "vendor/beta/beta.odin")), "RELEASE :: \"v0.1.0\"")
	fixtures.expect_contains(&a, fixtures.read_file(krs.path_join(a.project, "vendor/gamma/gamma.odin")), "RELEASE :: \"v0.1.1\"")
	testing.expect(t, os.exists(krs.path_join(a.project, "vendor/.krs/manifest.json")))

	// The root, which project B uses, is left as it was.
	testing.expect_value(t, fixtures.manifest_text(&a), before)
	fixtures.expect_release(&a, "beta", "v0.2.0")
	fixtures.expect_contains(&a, fixtures.read_file(krs.path_join(a.root, "shared/gamma/gamma.odin")), "RELEASE :: \"v0.1.0\"")

	beta := fixtures.record_of(&a, "beta")
	testing.expect_value(t, beta.tag, "v0.1.0")
	testing.expect(t, beta.pinned)
	testing.expect_value(t, fixtures.record_of(&a, "gamma").tag, "v0.1.1")
}

@(test)
update_install_always_still_asks_before_vendoring :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&a)
	b := fixtures.pinned_divergence(&a)
	defer fixtures.fixture_destroy(&b)

	fixtures.library_release(&a, "gamma", "v0.1.1")
	before := fixtures.manifest_text(&a)
	fixtures.expect_failure(&a, fixtures.run(&a, "", "update", "-u", "--install=always"), "confirmation is needed")
	testing.expect(t, !os.exists(krs.path_join(a.project, krs.VENDOR_DIR)))
	testing.expect_value(t, fixtures.manifest_text(&a), before)
}

@(test)
update_vendor_declined_changes_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&a)
	b := fixtures.pinned_divergence(&a)
	defer fixtures.fixture_destroy(&b)

	fixtures.library_release(&a, "gamma", "v0.1.1")
	before := fixtures.manifest_text(&a)
	result := fixtures.run(&a, "n\n", "update", "-u")
	fixtures.expect_failure(&a, result, "nothing was changed")
	testing.expect(t, !os.exists(krs.path_join(a.project, krs.VENDOR_DIR)))
	testing.expect_value(t, fixtures.record_of(&a, "gamma").tag, "v0.1.0")
	testing.expect_value(t, fixtures.manifest_text(&a), before)
}

@(test)
update_vendor_confirmed_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&a)
	b := fixtures.pinned_divergence(&a)
	defer fixtures.fixture_destroy(&b)

	fixtures.library_release(&a, "gamma", "v0.1.1")
	before := fixtures.manifest_text(&a)
	result := fixtures.run(&a, "y\n", "update", "-u")
	fixtures.expect_ok(&a, result)
	fixtures.expect_contains(&a, fixtures.read_file(krs.path_join(a.project, "vendor/gamma/gamma.odin")), "RELEASE :: \"v0.1.1\"")
	testing.expect_value(t, fixtures.manifest_text(&a), before)
	testing.expect_value(t, strings.count(result.out, "[y/N]"), 1)
}

@(test)
update_vendor_not_created_when_discovery_fails :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&a)
	b := fixtures.pinned_divergence(&a)
	defer fixtures.fixture_destroy(&b)

	fixtures.library_release(&a, "gamma", "v0.1.1")
	fixtures.expect_failure(&a, fixtures.run(&a, "", "update", "-u", "--yes", "gamma@v9.9.9"), "could not check")
	testing.expect(t, !os.exists(krs.path_join(a.project, krs.VENDOR_DIR)))
}

@(test)
update_install_never_only_writes_the_lockfile :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	// A compatible release: `krs install` asks before a breaking one, as usual.
	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v0.1.1")
	manifest := fixtures.manifest_text(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "--install=never"))
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"tag\": \"v0.1.1\"")
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)
	fixtures.expect_release(&fixture, "beta", "v0.1.0")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v0.1.1")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen"))
}

@(test)
update_install_prompt_needs_confirmation :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.release_beta_upgrade(&fixture)
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "-u"), "confirmation is needed")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "-u", "--install", "prompt"), "confirmation is needed")
	fixtures.expect_release(&fixture, "beta", "v0.1.0")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "y\n", "update", "-u"))
	fixtures.expect_release(&fixture, "beta", "v0.2.0")
}

@(test)
update_install_always_does_not_ask :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.release_beta_upgrade(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "--install=always"))
	fixtures.expect_release(&fixture, "beta", "v0.2.0")
}

@(test)
update_pin_pins_the_chosen_version :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.release_beta_upgrade(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "--pin", "--yes"))
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"pinned\": true")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"tag\": \"v0.2.0\"")
	fixtures.expect_release(&fixture, "beta", "v0.2.0")
}

@(test)
update_explicit_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.release_beta_upgrade(&fixture)
	fixtures.library_release(&fixture, "beta", "v0.3.0")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "beta@v0.2.0", "-u", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v0.2.0")

	result := fixtures.run(&fixture, "", "update", "beta@v9.9.9", "-u", "--yes")
	fixtures.expect_failure(&fixture, result, "could not check 1 package(s)")
	fixtures.expect_contains(&fixture, result.out, "has no tag v9.9.9")
	fixtures.expect_release(&fixture, "beta", "v0.2.0")
}

@(test)
update_upgrade_usage_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	Usage :: struct {
		arguments: []string,
		text:      string,
	}
	table := []Usage {
		{{"update", "-u", "--frozen"}, "--upgrade and --frozen cannot be combined"},
		{{"update", "--pin"}, "--pin only applies to update -u"},
		{{"update", "--install=never"}, "--install only applies to update -u"},
		{{"install", "-u"}, "-u only applies to update"},
		{{"install", "--pin"}, "--pin only applies to update"},
		{{"update", "-u", "--install=sometimes"}, "--install takes always, never or prompt"},
		{{"update", "-u", "--install"}, "--install needs a value"},
		{{"update", "-u", "-g"}, "-u and --global cannot be combined"},
		{{"update", "-u", "-e", "2"}, "--error-level cannot be combined with -u"},
		{{"update", "-u", "--json-upgraded"}, "--json-upgraded cannot be combined with -u"},
	}
	for row in table {
		result := fixtures.run(&fixture, "", ..row.arguments)
		testing.expectf(t, result.code == krs.EXIT_USAGE, "%v: exit %d, want %d\nerr: %s", row.arguments, result.code, krs.EXIT_USAGE, result.err)
		fixtures.expect_contains(&fixture, result.err, row.text)
	}
}

@(test)
update_u_semver_takes_compatible_tags_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.4.0")
	fixtures.library_release(&fixture, "gamma", "v0.1.0")
	fixtures.project_imports(&fixture, "beta", "gamma")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v0.4.1")
	fixtures.library_release(&fixture, "beta", "v0.5.0")
	fixtures.library_release(&fixture, "gamma", "v0.1.1")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "-u", "-t", "semver"), "confirmation is needed")
	fixtures.expect_release(&fixture, "beta", "v0.4.0")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "-t", "semver", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v0.4.1")
	fixtures.expect_release(&fixture, "gamma", "v0.1.1")
	fixtures.expect_contains(&fixture, check_update(&fixture), "beta v0.4.1 -> v0.5.0")
}

@(test)
update_u_semver_moves_a_stale_project_pin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	other := fixture
	other.project = krs.path_join(fixture.base, "other-app")
	os.make_directory_all(other.project)

	fixtures.library_release(&fixture, "beta", "v0.4.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.project_imports(&other, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&other, fixtures.run(&other, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v0.4.1")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "beta", "-u", "--yes"))

	fixtures.expect_ok(&other, fixtures.run(&other, "", "update", "-u", "-t", "semver", "--yes"))
	fixtures.expect_contains(&other, fixtures.packages_text(&other), "\"tag\": \"v0.4.1\"")
}

@(test)
update_u_changes_nothing_when_a_package_cannot_be_checked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.4.0")
	fixtures.library_release(&fixture, "gamma", "v0.1.0")
	fixtures.project_imports(&fixture, "beta", "gamma")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "gamma", "v0.1.1")
	os.remove_all(krs.path_join(fixture.sources, "beta"))

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "-u", "-t", "semver", "--yes"), "could not check")
	fixtures.expect_release(&fixture, "gamma", "v0.1.0")
}

@(test)
update_moves_one_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.4.0")
	fixtures.alpha_recording_beta(&fixture, "v1.0.0", "v0.4.0")
	fixtures.library_release(&fixture, "gamma", "v0.1.0")
	fixtures.project_imports(&fixture, "alpha", "beta", "gamma")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	fixtures.library_release(&fixture, "beta", "v0.4.1")
	fixtures.library_release(&fixture, "beta", "v0.5.0")
	fixtures.library_release(&fixture, "gamma", "v0.1.1")

	// With no argument it only lists.
	listing := fixtures.run(&fixture, "", "update")
	fixtures.expect_ok(&fixture, listing)
	fixtures.expect_contains(&fixture, fixtures.squeeze(listing.out), "beta v0.4.0 -> v0.5.0")
	fixtures.expect_contains(&fixture, fixtures.squeeze(listing.out), "gamma v0.1.0 -> v0.1.1")
	fixtures.expect_contains(&fixture, listing.out, "Major version zero")
	testing.expect(t, !strings.contains(listing.out, "alpha"))
	fixtures.expect_release(&fixture, "beta", "v0.4.0")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "beta", "-u"), "confirmation is needed")
	fixtures.expect_release(&fixture, "beta", "v0.4.0")

	result := fixtures.run(&fixture, "", "update", "beta", "-u", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "beta v0.4.0 -> v0.5.0 (breaking)")
	fixtures.expect_contains(&fixture, result.out, "alpha v1.0.0 recorded beta v0.4.0")
	fixtures.expect_release(&fixture, "beta", "v0.5.0")
	fixtures.expect_release(&fixture, "gamma", "v0.1.0")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"tag\": \"v0.5.0\"")
	fixtures.expect_contains(&fixture, fixtures.manifest_text(&fixture), "\"tag\": \"v0.5.0\"")

	// A named tag may be an older one.
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "beta@v0.4.1", "-u", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v0.4.1")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"tag\": \"v0.4.1\"")

	result = fixtures.run(&fixture, "", "update", "beta@v7.0.0", "-u", "--yes")
	fixtures.expect_failure(&fixture, result, "could not check 1 package(s)")
	fixtures.expect_contains(&fixture, result.out, "has no tag v7.0.0")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "beta@latest", "-u", "--yes"), "not a vMAJOR.MINOR.PATCH tag")
}

@(test)
update_refuses_a_package_this_project_does_not_use :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	other := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&other)
	other.root = fixture.root
	other.shared = fixture.shared
	other.home = fixture.home
	other.sources = fixture.sources
	fixtures.project_imports(&other)

	fixtures.library_release(&fixture, "beta", "v0.2.0")
	fixtures.expect_failure(&fixture, fixtures.run(&other, "", "update", "beta", "-u", "--yes"), "is not used by this project")
	fixtures.expect_release(&fixture, "beta", "v0.1.0")
	testing.expect(t, !os.exists(krs.path_join(other.project, krs.PACKAGES_PATH)))
}

@(test)
update_moves_the_project_pin_when_the_root_is_already_there :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&a)

	fixtures.library_release(&a, "beta", "v0.1.0")
	fixtures.project_imports(&a, "beta")
	fixtures.expect_ok(&a, fixtures.run(&a, "", "install", "--yes"))

	b := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&b)
	b.root = a.root
	b.shared = a.shared
	b.home = a.home
	b.sources = a.sources
	fixtures.project_imports(&b, "beta")
	fixtures.expect_ok(&b, fixtures.run(&b, "", "install", "--yes"))

	fixtures.library_release(&a, "beta", "v0.2.0")
	fixtures.expect_ok(&a, fixtures.run(&a, "", "update", "beta", "-u", "--yes"))
	fixtures.expect_release(&a, "beta", "v0.2.0")

	result := fixtures.run(&b, "", "update", "beta", "-u", "--yes")
	fixtures.expect_ok(&b, result)
	testing.expect(t, !strings.contains(result.out, "is already at"))
	fixtures.expect_contains(&b, fixtures.read_file(krs.path_join(b.project, krs.PACKAGES_PATH)), "\"tag\": \"v0.2.0\"")
}

@(test)
update_reports_already_at :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	result := fixtures.run(&fixture, "", "update", "beta@v0.1.0", "-u", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "beta is already at v0.1.0")
}

@(test)
update_listing_reports_unavailable_sources :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.fixture_config(&fixture, {krs.path_join(fixture.base, "other-sources")})

	result := fixtures.run(&fixture, "", "update")
	fixtures.expect_failure(&fixture, result, "could not check 1 package(s) for updates")
	fixtures.expect_contains(&fixture, result.out, "cannot check beta: no usable repository")
	testing.expect(t, !strings.contains(result.out, "at its highest tag"))
}

@(test)
unlink_restore_prefers_the_project_pin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	// A second project on the same root moves the shared release forward.
	second := fixture
	second.project = krs.path_join(fixture.base, "second")
	os.make_directory_all(second.project)
	fixtures.project_imports(&second, "beta")
	fixtures.library_release(&fixture, "beta", "v0.2.0")
	fixtures.expect_ok(&second, fixtures.run(&second, "", "update", "beta", "-u", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v0.2.0")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&second), "\"tag\": \"v0.2.0\"")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"tag\": \"v0.1.0\"")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "link", "beta"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "unlink", "beta", "--restore", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v0.1.0")
}

@(test)
update_fetch_sees_new_github_releases :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.github_fixture_release(&fixture, "dvrd", "project-kessel", "v1.0.0")
	fixtures.project_imports(&fixture, "kessel")
	fixtures.write_file(t, krs.path_join(fixture.home, krs.CONFIG_PATH),
		`{"libs":{"kessel":{"source":"github","target":"dvrd/project-kessel"}}}`)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	fixtures.github_fixture_release(&fixture, "dvrd", "project-kessel", "v1.1.0")
	plain := fixtures.run(&fixture, "", "update")
	fixtures.expect_ok(&fixture, plain)
	testing.expect(t, !strings.contains(plain.out, "v1.1.0"))

	fetched := fixtures.run(&fixture, "", "update", "--fetch")
	fixtures.expect_ok(&fixture, fetched)
	fixtures.expect_contains(&fixture, fixtures.squeeze(fetched.out), "kessel v1.0.0 -> v1.1.0")
	fixtures.expect_contains(&fixture, fetched.out, "Minor")
}

@(test)
update_flags_are_rejected_elsewhere :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	all := fixtures.run(&fixture, "", "install", "--all")
	testing.expect_value(t, all.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, all.err, "--all was removed; use krs update -u -t semver")
	fetch := fixtures.run(&fixture, "", "install", "--fetch")
	testing.expect_value(t, fetch.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, fetch.err, "--fetch only applies to update")
	update_all := fixtures.run(&fixture, "", "update", "--all")
	testing.expect_value(t, update_all.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, update_all.err, "--all was removed; use krs update -u -t semver")
}

// Replaces the fixture's base directory, in its real and raw forms, with `<base>`.
normalized :: proc(fixture: ^fixtures.Fixture, text: string) -> string {
	real, _ := os.get_absolute_path(fixture.base, context.allocator)
	result, _ := strings.replace_all(text, real, "<base>")
	result, _ = strings.replace_all(result, fixture.base, "<base>")
	return result
}

// Expects a command's complete output, paths normalized.
expect_output :: proc(fixture: ^fixtures.Fixture, result: fixtures.Result, out, err: string, loc := #caller_location) {
	testing.expect_value(fixture.t, normalized(fixture, result.out), out, loc = loc)
	testing.expect_value(fixture.t, normalized(fixture, result.err), err, loc = loc)
}

@(test)
resolver_output_is_stable :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	{
		// A compatible difference takes the higher release.
		fixture := fixtures.fixture_make(t)
		defer fixtures.fixture_destroy(&fixture)
		fixtures.library_release(&fixture, "beta", "v0.4.0")
		fixtures.project_imports(&fixture, "beta")
		fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
		fixtures.library_release(&fixture, "beta", "v0.4.2")
		fixtures.alpha_recording_beta(&fixture, "v1.0.0", "v0.4.2")
		fixtures.project_imports(&fixture, "alpha", "beta")

		result := fixtures.run(&fixture, "", "install", "--yes")
		fixtures.expect_ok(&fixture, result)
		expect_output(
			&fixture,
			result,
			"beta: v0.4.0 and v0.4.2 (wanted by alpha v1.0.0) are compatible; using v0.4.2\n" +
			"krs will change <base>/root/shared:\n" +
			"  install alpha v1.0.0 (from <base>/sources/alpha)\n" +
			"  replace beta v0.4.0 with v0.4.2 (from <base>/sources/beta)\n" +
			"krs: 2 installed, 0 already in place\n",
			"",
		)
	}

	{
		// A breaking difference with nobody to ask stops with a report.
		fixture := fixtures.fixture_make(t)
		defer fixtures.fixture_destroy(&fixture)
		fixtures.library_release(&fixture, "beta", "v0.4.0")
		fixtures.project_imports(&fixture, "beta")
		fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
		fixtures.library_release(&fixture, "beta", "v0.5.0")
		fixtures.alpha_recording_beta(&fixture, "v1.0.0", "v0.5.0")
		fixtures.project_imports(&fixture, "alpha", "beta")

		result := fixtures.run(&fixture, "", "install", "--yes")
		fixtures.expect_failure(&fixture, result, "needs a decision")
		expect_output(
			&fixture,
			result,
			"beta: v0.4.0 and v0.5.0 (wanted by alpha v1.0.0) are not compatible\n",
			"krs: beta needs a decision between v0.4.0 and v0.5.0; run krs install in a terminal\n",
		)
	}

	{
		// Updating one package moves it past a dependant's record.
		fixture := fixtures.fixture_make(t)
		defer fixtures.fixture_destroy(&fixture)
		fixtures.library_release(&fixture, "beta", "v0.4.0")
		fixtures.alpha_recording_beta(&fixture, "v1.0.0", "v0.4.0")
		fixtures.library_release(&fixture, "gamma", "v0.1.0")
		fixtures.project_imports(&fixture, "alpha", "beta", "gamma")
		fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
		fixtures.library_release(&fixture, "beta", "v0.4.1")
		fixtures.library_release(&fixture, "beta", "v0.5.0")

		result := fixtures.run(&fixture, "", "update", "beta", "-u", "--yes")
		fixtures.expect_ok(&fixture, result)
		expect_output(
			&fixture,
			result,
			"beta v0.4.0 -> v0.5.0 (breaking)\n" +
			"  alpha v1.0.0 recorded beta v0.4.0\n" +
			"note: alpha v1.0.0 recorded beta v0.4.0; v0.5.0 was asked for explicitly\n" +
			"krs will change <base>/root/shared:\n" +
			"  replace beta v0.4.0 with v0.5.0 (from <base>/sources/beta)\n" +
			"krs: 1 installed, 2 already in place\n",
			"",
		)
	}

	{
		// Unlinking with --restore installs the recorded release again.
		fixture := fixtures.fixture_make(t)
		defer fixtures.fixture_destroy(&fixture)
		fixtures.library_release(&fixture, "beta", "v0.1.0")
		fixtures.project_imports(&fixture, "beta")
		fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
		fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "link", "beta"))

		result := fixtures.run(&fixture, "", "unlink", "beta", "--restore", "--yes")
		fixtures.expect_ok(&fixture, result)
		expect_output(
			&fixture,
			result,
			"krs: restoring beta v0.1.0\n" +
			"krs will change <base>/root/shared:\n" +
			"  install beta v0.1.0 (from <base>/sources/beta)\n" +
			"krs: 1 installed, 0 already in place\n",
			"",
		)
	}
}

COOLDOWN_OLD ::"2001-01-01 00:00:00 +0000"

@(test)
cooldown_falls_back_to_an_old_enough_release :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release_at(&fixture, "beta", "v1.0.0", COOLDOWN_OLD)
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release_at(&fixture, "beta", "v1.0.1", "2001-02-01 00:00:00 +0000")
	fixtures.library_release(&fixture, "beta", "v1.1.0")

	result := fixtures.run(&fixture, "", "update", "--cooldown", "7")
	fixtures.expect_ok(&fixture, result)
	listing := fixtures.squeeze(result.out)
	fixtures.expect_contains(&fixture, listing, "beta v1.0.0 -> v1.0.1")
	testing.expect(t, !strings.contains(listing, "v1.1.0"))

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "--cooldown", "7", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v1.0.1")
}

@(test)
cooldown_skips_a_package_with_only_young_releases :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release_at(&fixture, "beta", "v1.0.0", COOLDOWN_OLD)
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v1.0.1")

	result := fixtures.run(&fixture, "", "update", "--cooldown", "7d")
	fixtures.expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(fixtures.squeeze(result.out), "-> v1.0.1"))

	held := fixtures.run(&fixture, "", "update", "--cooldown", "7d", "--format", "cooldown")
	fixtures.expect_ok(&fixture, held)
	fixtures.expect_contains(&fixture, fixtures.squeeze(held.out), "cooldown beta v1.0.0 skips v1.0.1")
}

@(test)
cooldown_periods_are_checked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	for period in ([]string{"--cooldown=0", "--cooldown=7x", "--cooldown=d", "--cooldown=-7"}) {
		result := fixtures.run(&fixture, "", "update", period)
		testing.expectf(t, result.code == krs.EXIT_USAGE, "%s should be a usage error: %s", period, result.err)
		fixtures.expect_contains(&fixture, result.err, "is not a cooldown period")
	}

	result := fixtures.run(&fixture, "", "install", "--cooldown=7")
	testing.expect_value(t, result.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, result.err, "only applies to update")
}

@(test)
cooldown_without_it_offers_the_fresh_release :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release_at(&fixture, "beta", "v1.0.0", COOLDOWN_OLD)
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release_at(&fixture, "beta", "v1.0.1", "2001-02-01 00:00:00 +0000")
	fixtures.library_release(&fixture, "beta", "v1.1.0")

	result := fixtures.run(&fixture, "", "update")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, fixtures.squeeze(result.out), "beta v1.0.0 -> v1.1.0")
}

@(test)
cooldown_never_downgrades :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release_at(&fixture, "beta", "v1.0.0", COOLDOWN_OLD)
	fixtures.library_release(&fixture, "beta", "v1.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	result := fixtures.run(&fixture, "", "update", "--cooldown", "7")
	fixtures.expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(fixtures.squeeze(result.out), "-> v1.0.0"))

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "--cooldown", "7", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v1.1.0")
}

@(test)
doctor_recovery_command_restores :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v0.1.1")

	// The state an interrupted trial leaves: the newer release recorded and installed.
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v0.1.1")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "--yes", "beta@v0.1.0"))
	fixtures.expect_release(&fixture, "beta", "v0.1.0")
	testing.expect_value(t, fixtures.record_of(&fixture, "beta").tag, "v0.1.0")
}

@(test)
checkout_that_gained_a_remote_is_still_checked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	testing.expect_value(t, fixtures.record_of(&fixture, "beta").source, krs.SOURCE_LOCAL)

	// The checkout is pushed to GitHub after it was recorded.
	beta := krs.path_join(fixture.sources, "beta")
	fixtures.git(t, beta, "remote", "add", "origin", "https://github.com/dvrd/beta.git")
	fixtures.library_release(&fixture, "beta", "v1.1.0")

	listed := fixtures.run(&fixture, "", "update")
	fixtures.expect_ok(&fixture, listed)
	fixtures.expect_contains(&fixture, fixtures.squeeze(listed.out), "Minor\n beta v1.0.0 -> v1.1.0")
	testing.expect(t, !strings.contains(listed.out, "skipped"), listed.out)

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v1.1.0")
	testing.expect_value(t, fixtures.record_of(&fixture, "beta").source, "https://github.com/dvrd/beta.git")
}

@(test)
recorded_github_source_refuses_a_checkout_without_one :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	beta := krs.path_join(fixture.sources, "beta")
	fixtures.git(t, beta, "remote", "add", "origin", "https://github.com/dvrd/beta.git")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	fixtures.git(t, beta, "remote", "remove", "origin")
	listed := fixtures.run(&fixture, "", "update")
	fixtures.expect_contains(&fixture, listed.out, "not the recorded https://github.com/dvrd/beta.git")
}

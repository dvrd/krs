package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../src"

// A library with everything a real repository carries around its source.
alpha_release :: proc(fixture: ^Fixture) -> string {
	path := repository_make(fixture, "alpha")
	write_file(fixture.t, krs.path_join(path, "src/alpha.odin"), "package alpha\n\nRELEASE :: \"v0.1.0\"\nRUNTIME :: #load(\"assets/runtime.js\", string)\n")
	write_file(fixture.t, krs.path_join(path, "src/assets/runtime.js"), "export const released = true\n")
	write_file(fixture.t, krs.path_join(path, "src/assets/unused.js"), "export const unused = true\n")
	write_file(fixture.t, krs.path_join(path, "src/notes/design.md"), "# stray notes\n")
	write_file(fixture.t, krs.path_join(path, "src/tests/alpha_test.odin"), "package alpha_tests\n")
	write_file(fixture.t, krs.path_join(path, "tests/run.sh"), "#!/bin/sh\n")
	write_file(fixture.t, krs.path_join(path, "README.md"), "# alpha\n")
	write_file(fixture.t, krs.path_join(path, "LICENSE"), "licence text\n")

	return repository_release(fixture, "alpha", "v0.1.0")
}

@(test)
install_keeps_only_what_the_source_names :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	commit := alpha_release(&fixture)
	project_imports(&fixture, "alpha")

	// Work after the tag, committed or not, is never installed.
	repository := krs.path_join(fixture.sources, "alpha")
	write_file(t, krs.path_join(repository, "src/alpha.odin"), "package alpha\n\nRELEASE :: \"unreleased\"\n")
	git(t, repository, "commit", "--quiet", "-am", "after the tag")
	write_file(t, krs.path_join(repository, "src/draft.odin"), "package alpha\n")

	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	testing.expect(t, os.exists(krs.path_join(fixture.home, ".local/shared/krs/transactions.db")))

	installed := krs.path_join(fixture.shared, "alpha")
	expect_release(&fixture, "alpha", "v0.1.0")
	testing.expect(t, os.exists(krs.path_join(installed, "assets/runtime.js")))
	testing.expect(t, os.exists(krs.path_join(installed, "LICENSE")))
	testing.expect(t, !os.exists(krs.path_join(installed, "assets/unused.js")))
	testing.expect(t, !os.exists(krs.path_join(installed, "notes")))
	testing.expect(t, !os.exists(krs.path_join(installed, "tests")))
	testing.expect(t, !os.exists(krs.path_join(installed, "README.md")))
	testing.expect(t, !os.exists(krs.path_join(installed, "draft.odin")))
	testing.expect(t, !os.exists(krs.path_join(installed, "src")))

	packages := packages_text(&fixture)
	expect_contains(&fixture, packages, "\"tag\": \"v0.1.0\"")
	expect_contains(&fixture, packages, commit)
	expect_contains(&fixture, packages, "\"source\": \"local\"")
	testing.expect(t, !strings.contains(packages, fixture.base), "no machine path belongs in packages.json")
	expect_contains(&fixture, manifest_text(&fixture), repository)
	entries, err := os.read_all_directory_by_path(fixture.shared, context.allocator)
	testing.expect_value(t, err, nil)
	for entry in entries {
		testing.expect(t, !strings.has_prefix(entry.name, ".krs-stage-"))
	}
}

@(test)
second_install_changes_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	alpha_release(&fixture)
	project_imports(&fixture, "alpha")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	packages := packages_text(&fixture)
	manifest := manifest_text(&fixture)

	// No `--yes`: nothing may need confirming.
	again := run(&fixture, "", "install")
	expect_ok(&fixture, again)
	expect_contains(&fixture, again.out, "0 installed, 1 already in place")
	testing.expect_value(t, packages_text(&fixture), packages)
	testing.expect_value(t, manifest_text(&fixture), manifest)

	expect_ok(&fixture, run(&fixture, "", "install", "--frozen"))
}

@(test)
transitive_dependency_uses_the_recorded_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	pinned := library_release(&fixture, "beta", "v0.1.0")
	library_release(&fixture, "beta", "v0.1.1")

	pins := fmt.aprintf(
		"{{\"format\": 1, \"packages\": [{{\"name\": \"beta\", \"source\": \"local\", \"tag\": \"v0.1.0\", \"commit\": \"%s\", \"hash\": \"\"}}]}}\n",
		pinned,
	)
	repository_make(&fixture, "alpha")
	write_file(t, krs.path_join(fixture.sources, "alpha/.krs/packages.json"), pins)
	library_release(&fixture, "alpha", "v1.0.0", "beta", "alpha")
	project_imports(&fixture, "alpha")

	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	expect_release(&fixture, "alpha", "v1.0.0")
	expect_release(&fixture, "beta", "v0.1.0")
	expect_contains(&fixture, packages_text(&fixture), "\"name\": \"beta\"")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "alpha/.krs")))
}

@(test)
first_install_takes_the_highest_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.9.0")
	library_release(&fixture, "beta", "v0.10.0")
	git(t, krs.path_join(fixture.sources, "beta"), "tag", "nightly")
	project_imports(&fixture, "beta")

	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_release(&fixture, "beta", "v0.10.0")

	// A newer tag does not move an installed package.
	library_release(&fixture, "beta", "v0.11.0")
	expect_ok(&fixture, run(&fixture, "", "install"))
	expect_release(&fixture, "beta", "v0.10.0")
}

@(test)
install_asks_before_writing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")

	expect_failure(&fixture, run(&fixture, "", "install"), "confirmation is needed")
	expect_failure(&fixture, run(&fixture, "n\n", "install"), "nothing was changed")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "beta")))
	testing.expect_value(t, packages_text(&fixture), "")

	expect_ok(&fixture, run(&fixture, "y\n", "install"))
	expect_release(&fixture, "beta", "v0.1.0")
}

@(test)
frozen_installs_exactly_what_is_recorded :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")

	expect_failure(&fixture, run(&fixture, "", "install", "--frozen"), "packages.json would change")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "beta")))

	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release(&fixture, "beta", "v0.2.0")

	// A second, empty Odin root is filled from the project's record alone.
	other := krs.path_join(fixture.base, "other-root")
	os.make_directory_all(other)
	expect_ok(&fixture, run(&fixture, "", "install", "--frozen", fmt.aprintf("--root=%s", other)))
	expect_contains(&fixture, read_file(krs.path_join(other, "shared/beta/beta.odin")), "v0.1.0")

	library_release(&fixture, "gamma", "v0.1.0")
	project_imports(&fixture, "beta", "gamma")
	expect_failure(&fixture, run(&fixture, "", "install", "--frozen"), "packages.json would change")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "gamma")))
}

@(test)
recorded_hash_mismatch_is_refused :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	// The record names the right tag and commit but different bytes.
	path := krs.path_join(fixture.project, krs.PACKAGES_PATH)
	text := packages_text(&fixture)
	start := strings.index(text, "\"hash\": \"")
	if !testing.expect(t, start >= 0 && len(text) >= start + 9 + 64, text) {
		return
	}

	// The 64 characters after `"hash": "` must be the lowercase hex digest.
	for c in text[start + 9:start + 9 + 64] {
		testing.expect(t, strings.contains_rune("0123456789abcdef", c), text)
	}
	tampered := strings.concatenate({text[:start + 9], strings.repeat("0", 64), text[start + 9 + 64:]})
	write_file(t, path, tampered)

	other := krs.path_join(fixture.base, "other-root")
	os.make_directory_all(other)
	result := run(&fixture, "", "install", "--frozen", fmt.aprintf("--root=%s", other))
	expect_failure(&fixture, result, "beta v0.1.0 does not match the content hash this project recorded")
	testing.expect(t, !os.exists(krs.path_join(other, "shared/beta")))
}

@(test)
unmanaged_directory_is_left_alone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	// A repository of the same name exists, and must not be installed over it.
	library_release(&fixture, "beta", "v0.1.0")
	unmanaged := krs.path_join(fixture.shared, "beta/beta.odin")
	write_file(t, unmanaged, "package beta\n\nHAND_WRITTEN :: true\n")
	write_file(t, krs.path_join(fixture.shared, "beta/.git/HEAD"), "ref: refs/heads/main\n")
	before, before_ok := krs.hash_directory(krs.path_join(fixture.shared, "beta"))
	testing.expect(t, before_ok, "the unmanaged directory can be hashed")
	project_imports(&fixture, "beta")

	result := run(&fixture, "", "install", "--yes")
	expect_ok(&fixture, result)

	after, after_ok := krs.hash_directory(krs.path_join(fixture.shared, "beta"))
	testing.expect(t, after_ok, "the unmanaged directory can still be hashed")
	testing.expect_value(t, after, before)
	testing.expect_value(t, read_file(unmanaged), "package beta\n\nHAND_WRITTEN :: true\n")
	testing.expect_value(t, read_file(krs.path_join(fixture.shared, "beta/.git/HEAD")), "ref: refs/heads/main\n")
	expect_contains(&fixture, read_file(unmanaged), "HAND_WRITTEN")
	testing.expect(t, os.exists(krs.path_join(fixture.shared, "beta/.git/HEAD")))
	testing.expect(t, !strings.contains(packages_text(&fixture), "beta"))
	testing.expect(t, !strings.contains(manifest_text(&fixture), "beta"))

	expect_failure(&fixture, run(&fixture, "", "link", "beta"), "not managed by krs")
	expect_failure(&fixture, run(&fixture, "", "update", "beta", "-u", "--yes"), "was not installed by krs")
}

@(test)
unusable_directories_are_reported :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	first := krs.path_join(fixture.base, "first")
	second := krs.path_join(fixture.base, "second")
	write_file(t, krs.path_join(first, "beta/beta.odin"), "package beta\n")
	os.make_directory_all(krs.path_join(second, "beta"))
	git(t, krs.path_join(second, "beta"), "init", "--quiet")
	git(t, krs.path_join(second, "beta"), "commit", "--quiet", "--allow-empty", "-m", "untagged")
	fixture_config(&fixture, {first, second, fixture.sources})

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta", "missing")

	result := run(&fixture, "", "install", "--yes")
	expect_contains(&fixture, result.out, "first/beta: it is not a Git repository")
	expect_contains(&fixture, result.out, "second/beta: it has no semantic-version tag")
	expect_failure(&fixture, result, "no repository for \"missing\"")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "beta")), "a failed plan writes nothing")
}

@(test)
altered_install_is_reported :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")

	result := run(&fixture, "", "install")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "does not match the hash recorded for beta v0.1.0")
	expect_failure(&fixture, run(&fixture, "", "install", "--frozen"), "does not match its recorded hash")
}

@(test)
repair_reinstalls_an_altered_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")
	write_file(t, krs.path_join(fixture.shared, "beta/extra.txt"), "extra\n")

	expect_failure(&fixture, run(&fixture, "", "install", "--repair"), "confirmation is needed")
	expect_contains(&fixture, read_file(krs.path_join(fixture.shared, "beta/beta.odin")), "EDITED")

	result := run(&fixture, "", "install", "--repair", "--yes")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "repair beta v0.1.0")
	expect_contains(&fixture, result.out, "changed shared/beta/beta.odin")
	expect_contains(&fixture, result.out, "added shared/beta/extra.txt")
	expect_contains(&fixture, result.out, "discarded when the release is reinstalled")

	expect_release(&fixture, "beta", "v0.1.0")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "beta/extra.txt")))
	expect_ok(&fixture, run(&fixture, "", "install", "--frozen"))
}

@(test)
repair_leaves_intact_packages_alone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	library_release(&fixture, "gamma", "v0.1.0")
	project_imports(&fixture, "beta", "gamma")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	before := packages_text(&fixture)
	write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")

	result := run(&fixture, "", "install", "--repair", "--yes")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "repair beta")
	testing.expect(t, !strings.contains(result.out, "repair gamma"), result.out)
	testing.expect_value(t, packages_text(&fixture), before)
}

@(test)
repair_flag_is_rejected_elsewhere :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	misplaced := run(&fixture, "", "update", "--repair")
	testing.expect_value(t, misplaced.code, krs.EXIT_USAGE)
	expect_contains(&fixture, misplaced.err, "--repair only applies to install")

	combined := run(&fixture, "", "install", "--repair", "--frozen")
	testing.expect_value(t, combined.code, krs.EXIT_USAGE)
	expect_contains(&fixture, combined.err, "cannot be combined")
}

@(test)
repair_asks_in_a_terminal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")

	expect_failure(&fixture, run(&fixture, "n\n", "install", "--repair"), "nothing was changed")
	expect_ok(&fixture, run(&fixture, "y\n", "install", "--repair"))
	expect_release(&fixture, "beta", "v0.1.0")
}

@(test)
os_metadata_does_not_alter_an_install :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	write_file(t, krs.path_join(fixture.shared, "beta/.DS_Store"), "x")
	write_file(t, krs.path_join(fixture.shared, "beta/._beta.odin"), "x")
	write_file(t, krs.path_join(fixture.shared, "beta/sub/Thumbs.db"), "x")

	result := run(&fixture, "", "install")
	expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(result.out, "does not match the hash recorded"), result.out)
	expect_ok(&fixture, run(&fixture, "", "install", "--frozen"))

	// An added non-metadata file is still detected.
	write_file(t, krs.path_join(fixture.shared, "beta/extra.odin"), "package beta\n")
	expect_failure(&fixture, run(&fixture, "", "install", "--frozen"), "does not match its recorded hash")
}

@(test)
moved_tag_is_refused ::proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	repository := krs.path_join(fixture.sources, "beta")
	git(t, repository, "commit", "--quiet", "--allow-empty", "-m", "rewritten")
	git(t, repository, "tag", "--force", "v0.1.0")

	expect_failure(&fixture, run(&fixture, "", "update", "beta@v0.1.0", "-u", "--yes"), "a published tag must not move")

	other := krs.path_join(fixture.base, "other-root")
	os.make_directory_all(other)
	result := run(&fixture, "", "install", "--yes", fmt.aprintf("--root=%s", other))
	expect_failure(&fixture, result, "a published tag must not move")
	testing.expect(t, !os.exists(krs.path_join(other, "shared/beta")))
}

@(test)
frozen_install_restores_a_missing_managed_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	packages := packages_text(&fixture)
	library_release(&fixture, "beta", "v1.1.0")
	testing.expect_value(t, os.remove_all(krs.path_join(fixture.shared, "beta")), nil)

	expect_ok(&fixture, run(&fixture, "", "install", "--frozen"))
	expect_release(&fixture, "beta", "v1.0.0")
	testing.expect_value(t, packages_text(&fixture), packages)
}

@(test)
frozen_install_rejects_an_unmanaged_copy_of_a_pinned_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	other_root := krs.path_join(fixture.base, "other-root")
	unmanaged := krs.path_join(other_root, "shared/beta/beta.odin")
	write_file(t, unmanaged, "package beta\n")
	result := run(&fixture, "", "install", "--frozen", fmt.aprintf("--root=%s", other_root))
	expect_failure(&fixture, result, "cannot verify the recorded version of unmanaged package beta")
	testing.expect_value(t, read_file(unmanaged), "package beta\n")
}

@(test)
install_refuses_invalid_release_lockfiles :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	repository := repository_make(&fixture, "alpha")
	pins := krs.path_join(repository, krs.PACKAGES_PATH)
	library_release(&fixture, "beta", "v1.0.0")
	project_imports(&fixture, "alpha")

	write_file(t, pins, "{malformed")
	library_release(&fixture, "alpha", "v1.0.0", "beta")
	expect_failure(&fixture, run(&fixture, "", "install", "--yes"), ".krs/packages.json is not valid JSON")

	write_file(t, pins, `{"format": 9, "packages": []}`)
	library_release(&fixture, "alpha", "v1.0.1", "beta")
	expect_failure(&fixture, run(&fixture, "", "install", "--yes"), "was written by a newer krs")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "alpha")))
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "beta")))
}

@(test)
licence_only_release_is_not_a_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	repository := repository_make(&fixture, "alpha")
	write_file(t, krs.path_join(repository, "LICENSE"), "licence text")
	repository_release(&fixture, "alpha", "v1.0.0")
	project_imports(&fixture, "alpha")

	expect_failure(&fixture, run(&fixture, "", "install", "--yes"), "has no Odin files to install")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "alpha")))
}

@(test)
local_origin_is_portable_and_legacy_pin_is_preserved :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	repository := krs.path_join(fixture.sources, "beta")
	git(t, repository, "remote", "add", "origin", krs.path_join(fixture.base, "upstream"))
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	packages := packages_text(&fixture)
	expect_contains(&fixture, packages, "\"source\": \"local\"")
	testing.expect(t, !strings.contains(packages, fixture.base))
	legacy, _ := strings.replace_all(packages, "\"local\"", fmt.aprintf("\"%s/upstream\"", fixture.base))
	write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), legacy)
	expect_ok(&fixture, run(&fixture, "", "install", "--frozen"))
	testing.expect_value(t, packages_text(&fixture), legacy)
}

@(test)
config_ignores_retired_keys :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	text := fmt.aprintf("{{\"format\": 1, \"source_directories\": [\"%s\"], \"trusted_owners\": [\"someone\"]}}\n", fixture.sources)
	write_file(t, krs.path_join(fixture.home, krs.CONFIG_PATH), text)

	result := run(&fixture, "", "link", "ls")
	expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(result.out, "no settings"), result.out)
}

@(test)
install_skips_symbolic_links_in_a_release :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	path := repository_make(&fixture, "alpha")
	write_file(t, krs.path_join(path, "LICENSE"), "licence text\n")
	write_file(t, krs.path_join(path, "data/runtime.js"), "export const released = true\n")
	write_file(t, krs.path_join(path, "src/alpha.odin"), "package alpha\n\nRUNTIME :: #load(\"assets/runtime.js\", string)\n")
	err1 := os.symlink("../LICENSE", krs.path_join(path, "src/LICENSE"))
	os.make_directory_all(krs.path_join(path, "src/assets"))
	err2 := os.symlink("../../data/runtime.js", krs.path_join(path, "src/assets/runtime.js"))
	testing.expect(t, err1 == nil && err2 == nil)
	repository_release(&fixture, "alpha", "v0.1.0")

	project_imports(&fixture, "alpha")
	result := run(&fixture, "", "install", "--yes")
	expect_ok(&fixture, result)

	testing.expect_value(t, read_file(krs.path_join(fixture.shared, "alpha/LICENSE")), "licence text\n")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "alpha/assets/runtime.js")))
	expect_contains(&fixture, result.out, "which is a symbolic link in the release")
}

@(test)
install_reports_a_load_into_a_submodule :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "alpha", "v0.1.0")
	path := krs.path_join(fixture.sources, "alpha")
	first := git(t, path, "rev-parse", "HEAD")

	// A gitlink without a real submodule. `repository_release` would stage the
	// missing directory as a deletion, so commit and tag directly.
	git(t, path, "update-index", "--add", "--cacheinfo", fmt.aprintf("160000,%s,src/vendor", first))
	write_file(t, krs.path_join(path, "src/alpha.odin"), "package alpha\n\nX :: #load(\"vendor/x.txt\", string)\nRELEASE :: \"v0.2.0\"\n")
	git(t, path, "add", "src/alpha.odin")
	git(t, path, "commit", "--quiet", "-m", "v0.2.0")
	git(t, path, "tag", "v0.2.0")

	project_imports(&fixture, "alpha")
	result := run(&fixture, "", "install", "--yes")
	expect_ok(&fixture, result)

	expect_contains(&fixture, result.out, "inside submodule src/vendor")
}

@(test)
install_refuses_case_colliding_paths :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	path := repository_make(&fixture, "alpha")
	write_file(t, krs.path_join(path, "src/alpha.odin"), "package alpha\n\nA :: #load(\"Data.txt\", string)\nB :: #load(\"data.txt\", string)\n")
	git(t, path, "add", "src/alpha.odin")

	// The blob lives outside the repository so `git add` never sees it. Both
	// index entries are added with case-sensitive matching.
	blob_source := krs.path_join(fixture.base, "blob.txt")
	write_file(t, blob_source, "data\n")
	blob := git(t, path, "hash-object", "-w", blob_source)
	git(t, path, "-c", "core.ignorecase=false", "update-index", "--add", "--cacheinfo", fmt.aprintf("100644,%s,src/Data.txt", blob))
	git(t, path, "-c", "core.ignorecase=false", "update-index", "--add", "--cacheinfo", fmt.aprintf("100644,%s,src/data.txt", blob))
	git(t, path, "commit", "--quiet", "-m", "v0.1.0")
	git(t, path, "tag", "v0.1.0")

	project_imports(&fixture, "alpha")
	expect_failure(&fixture, run(&fixture, "", "install", "--yes"), "differ only in letter case")

	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "alpha")))
}

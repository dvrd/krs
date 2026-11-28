package e2e

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
install_keeps_only_what_the_source_names :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	commit := fixtures.alpha_release(&fixture)
	fixtures.project_imports(&fixture, "alpha")

	// Work after the tag, committed or not, is never installed.
	repository := krs.path_join(fixture.sources, "alpha")
	fixtures.write_file(t, krs.path_join(repository, "src/alpha.odin"), "package alpha\n\nRELEASE :: \"unreleased\"\n")
	fixtures.git(t, repository, "commit", "--quiet", "-am", "after the tag")
	fixtures.write_file(t, krs.path_join(repository, "src/draft.odin"), "package alpha\n")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	testing.expect(t, os.exists(krs.path_join(fixture.home, ".local/shared/krs/transactions.db")))

	installed := krs.path_join(fixture.shared, "alpha")
	fixtures.expect_release(&fixture, "alpha", "v0.1.0")
	testing.expect(t, os.exists(krs.path_join(installed, "assets/runtime.js")))
	testing.expect(t, os.exists(krs.path_join(installed, "LICENSE")))
	testing.expect(t, !os.exists(krs.path_join(installed, "assets/unused.js")))
	testing.expect(t, !os.exists(krs.path_join(installed, "notes")))
	testing.expect(t, !os.exists(krs.path_join(installed, "tests")))
	testing.expect(t, !os.exists(krs.path_join(installed, "README.md")))
	testing.expect(t, !os.exists(krs.path_join(installed, "draft.odin")))
	testing.expect(t, !os.exists(krs.path_join(installed, "src")))

	packages := fixtures.packages_text(&fixture)
	fixtures.expect_contains(&fixture, packages, "\"tag\": \"v0.1.0\"")
	fixtures.expect_contains(&fixture, packages, commit)
	fixtures.expect_contains(&fixture, packages, "\"source\": \"local\"")
	testing.expect(t, !strings.contains(packages, fixture.base), "no machine path belongs in packages.json")
	fixtures.expect_contains(&fixture, fixtures.manifest_text(&fixture), repository)
	entries, err := os.read_all_directory_by_path(fixture.shared, context.allocator)
	testing.expect_value(t, err, nil)
	for entry in entries {
		testing.expect(t, !strings.has_prefix(entry.name, ".krs-stage-"))
	}
}

@(test)
second_install_changes_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.alpha_release(&fixture)
	fixtures.project_imports(&fixture, "alpha")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	packages := fixtures.packages_text(&fixture)
	manifest := fixtures.manifest_text(&fixture)

	// No `--yes`: nothing may need confirming.
	again := fixtures.run(&fixture, "", "install")
	fixtures.expect_ok(&fixture, again)
	fixtures.expect_contains(&fixture, again.out, "0 installed, 1 already in place")
	testing.expect_value(t, fixtures.packages_text(&fixture), packages)
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen"))
}

@(test)
transitive_dependency_uses_the_recorded_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	pinned := fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.library_release(&fixture, "beta", "v0.1.1")

	pins := fmt.aprintf(
		"{{\"format\": 1, \"packages\": [{{\"name\": \"beta\", \"source\": \"local\", \"tag\": \"v0.1.0\", \"commit\": \"%s\", \"hash\": \"\"}}]}}\n",
		pinned,
	)
	fixtures.repository_make(&fixture, "alpha")
	fixtures.write_file(t, krs.path_join(fixture.sources, "alpha/.krs/packages.json"), pins)
	fixtures.library_release(&fixture, "alpha", "v1.0.0", "beta", "alpha")
	fixtures.project_imports(&fixture, "alpha")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	fixtures.expect_release(&fixture, "alpha", "v1.0.0")
	fixtures.expect_release(&fixture, "beta", "v0.1.0")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"name\": \"beta\"")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "alpha/.krs")))
}

@(test)
first_install_takes_the_highest_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.9.0")
	fixtures.library_release(&fixture, "beta", "v0.10.0")
	fixtures.git(t, krs.path_join(fixture.sources, "beta"), "tag", "nightly")
	fixtures.project_imports(&fixture, "beta")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v0.10.0")

	// A newer tag does not move an installed package.
	fixtures.library_release(&fixture, "beta", "v0.11.0")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install"))
	fixtures.expect_release(&fixture, "beta", "v0.10.0")
}

@(test)
install_asks_before_writing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install"), "confirmation is needed")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "n\n", "install"), "nothing was changed")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "beta")))
	testing.expect_value(t, fixtures.packages_text(&fixture), "")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "y\n", "install"))
	fixtures.expect_release(&fixture, "beta", "v0.1.0")
}

@(test)
frozen_installs_exactly_what_is_recorded :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--frozen"), "packages.json would change")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "beta")))

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v0.2.0")

	// A second, empty Odin root is filled from the project's record alone.
	other := krs.path_join(fixture.base, "other-root")
	os.make_directory_all(other)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen", fmt.aprintf("--root=%s", other)))
	fixtures.expect_contains(&fixture, fixtures.read_file(krs.path_join(other, "shared/beta/beta.odin")), "v0.1.0")

	fixtures.library_release(&fixture, "gamma", "v0.1.0")
	fixtures.project_imports(&fixture, "beta", "gamma")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--frozen"), "packages.json would change")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "gamma")))
}

@(test)
frozen_keeps_the_recorded_version_when_a_dependency_records_another :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.4.0")
	fixtures.library_release(&fixture, "beta", "v0.4.1")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "beta", "v0.4.2")
	fixtures.library_release(&fixture, "beta", "v0.5.0")
	fixtures.project_imports(&fixture, "alpha", "beta")

	// alpha's own record names an older release, a newer compatible one,
	// then a breaking one. The project records beta v0.4.1 throughout.
	for wanted, index in ([]string{"v0.4.0", "v0.4.2", "v0.5.0"}) {
		alpha_tag := fmt.aprintf("v1.0.%d", index)
		fixtures.alpha_recording_beta(&fixture, alpha_tag, wanted)

		// Record alpha while a pin holds beta, then leave beta unpinned.
		fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "beta"))
		if index == 0 {
			fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
		} else {
			fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "-u", "--yes", fmt.aprintf("alpha@%s", alpha_tag)))
		}
		fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "unpin", "beta"))
		recorded := fixtures.packages_text(&fixture)
		testing.expect(t, !strings.contains(recorded, "pinned"), recorded)

		// A fresh Odin root, no terminal, no --yes.
		other := krs.path_join(fixture.base, fmt.aprintf("frozen-root-%d", index))
		os.make_directory_all(other)
		result := fixtures.run(&fixture, "", "install", "--frozen", fmt.aprintf("--root=%s", other))
		fixtures.expect_ok(&fixture, result)
		fixtures.expect_contains(&fixture, result.out, fmt.aprintf("alpha %s recorded beta %s; --frozen keeps v0.4.1 from .krs/packages.json", alpha_tag, wanted))
		fixtures.expect_contains(&fixture, fixtures.read_file(krs.path_join(other, "shared/beta/beta.odin")), "v0.4.1")
		fixtures.expect_contains(&fixture, fixtures.read_file(krs.path_join(other, "shared/alpha/alpha.odin")), alpha_tag)
		testing.expect_value(t, fixtures.packages_text(&fixture), recorded)
	}
}

@(test)
recorded_hash_mismatch_is_refused :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	// The record names the right tag and commit but different bytes.
	path := krs.path_join(fixture.project, krs.PACKAGES_PATH)
	text := fixtures.packages_text(&fixture)
	start := strings.index(text, "\"hash\": \"")
	if !testing.expect(t, start >= 0 && len(text) >= start + 9 + 64, text) {
		return
	}

	// The 64 characters after `"hash": "` must be the lowercase hex digest.
	for c in text[start + 9:start + 9 + 64] {
		testing.expect(t, strings.contains_rune("0123456789abcdef", c), text)
	}
	tampered := strings.concatenate({text[:start + 9], strings.repeat("0", 64), text[start + 9 + 64:]})
	fixtures.write_file(t, path, tampered)

	other := krs.path_join(fixture.base, "other-root")
	os.make_directory_all(other)
	result := fixtures.run(&fixture, "", "install", "--frozen", fmt.aprintf("--root=%s", other))
	fixtures.expect_failure(&fixture, result, "beta v0.1.0 does not match the content hash this project recorded")
	testing.expect(t, !os.exists(krs.path_join(other, "shared/beta")))
}

@(test)
unusable_directories_are_reported :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	first := krs.path_join(fixture.base, "first")
	second := krs.path_join(fixture.base, "second")
	fixtures.write_file(t, krs.path_join(first, "beta/beta.odin"), "package beta\n")
	os.make_directory_all(krs.path_join(second, "beta"))
	fixtures.git(t, krs.path_join(second, "beta"), "init", "--quiet")
	fixtures.git(t, krs.path_join(second, "beta"), "commit", "--quiet", "--allow-empty", "-m", "untagged")
	fixtures.fixture_config(&fixture, {first, second, fixture.sources})

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta", "missing")

	result := fixtures.run(&fixture, "", "install", "--yes")
	fixtures.expect_contains(&fixture, result.out, "first/beta: it is not a Git repository")
	fixtures.expect_contains(&fixture, result.out, "second/beta: it has no semantic-version tag")
	fixtures.expect_failure(&fixture, result, "no repository for \"missing\"")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "beta")), "a failed plan writes nothing")
}

@(test)
altered_install_is_reported :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")

	result := fixtures.run(&fixture, "", "install")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "does not match the hash recorded for beta v0.1.0")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--frozen"), "does not match its recorded hash")
}

@(test)
repair_reinstalls_an_altered_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")
	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/extra.txt"), "extra\n")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--repair"), "confirmation is needed")
	fixtures.expect_contains(&fixture, fixtures.read_file(krs.path_join(fixture.shared, "beta/beta.odin")), "EDITED")

	result := fixtures.run(&fixture, "", "install", "--repair", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "repair beta v0.1.0")
	fixtures.expect_contains(&fixture, result.out, "changed shared/beta/beta.odin")
	fixtures.expect_contains(&fixture, result.out, "added shared/beta/extra.txt")
	fixtures.expect_contains(&fixture, result.out, "discarded when the release is reinstalled")

	fixtures.expect_release(&fixture, "beta", "v0.1.0")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "beta/extra.txt")))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen"))
}

@(test)
repair_leaves_intact_packages_alone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.library_release(&fixture, "gamma", "v0.1.0")
	fixtures.project_imports(&fixture, "beta", "gamma")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	before := fixtures.packages_text(&fixture)
	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")

	result := fixtures.run(&fixture, "", "install", "--repair", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "repair beta")
	testing.expect(t, !strings.contains(result.out, "repair gamma"), result.out)
	testing.expect_value(t, fixtures.packages_text(&fixture), before)
}

@(test)
repair_asks_in_a_terminal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "n\n", "install", "--repair"), "nothing was changed")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "y\n", "install", "--repair"))
	fixtures.expect_release(&fixture, "beta", "v0.1.0")
}

@(test)
os_metadata_does_not_alter_an_install :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/.DS_Store"), "x")
	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/._beta.odin"), "x")
	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/sub/Thumbs.db"), "x")

	result := fixtures.run(&fixture, "", "install")
	fixtures.expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(result.out, "does not match the hash recorded"), result.out)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen"))

	// An added non-metadata file is still detected.
	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/extra.odin"), "package beta\n")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--frozen"), "does not match its recorded hash")
}

@(test)
frozen_install_restores_a_missing_managed_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	packages := fixtures.packages_text(&fixture)
	fixtures.library_release(&fixture, "beta", "v1.1.0")
	testing.expect_value(t, os.remove_all(krs.path_join(fixture.shared, "beta")), nil)

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen"))
	fixtures.expect_release(&fixture, "beta", "v1.0.0")
	testing.expect_value(t, fixtures.packages_text(&fixture), packages)
}

@(test)
frozen_install_rejects_an_unmanaged_copy_of_a_pinned_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	other_root := krs.path_join(fixture.base, "other-root")
	unmanaged := krs.path_join(other_root, "shared/beta/beta.odin")
	fixtures.write_file(t, unmanaged, "package beta\n")
	result := fixtures.run(&fixture, "", "install", "--frozen", fmt.aprintf("--root=%s", other_root))
	fixtures.expect_failure(&fixture, result, "cannot verify the recorded version of unmanaged package beta")
	testing.expect_value(t, fixtures.read_file(unmanaged), "package beta\n")
}

@(test)
install_refuses_invalid_release_lockfiles :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	repository := fixtures.repository_make(&fixture, "alpha")
	pins := krs.path_join(repository, krs.PACKAGES_PATH)
	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.project_imports(&fixture, "alpha")

	fixtures.write_file(t, pins, "{malformed")
	fixtures.library_release(&fixture, "alpha", "v1.0.0", "beta")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--yes"), ".krs/packages.json is not valid JSON")

	fixtures.write_file(t, pins, `{"format": 9, "packages": []}`)
	fixtures.library_release(&fixture, "alpha", "v1.0.1", "beta")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--yes"), "was written by a newer krs")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "alpha")))
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "beta")))
}

@(test)
licence_only_release_is_not_a_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	repository := fixtures.repository_make(&fixture, "alpha")
	fixtures.write_file(t, krs.path_join(repository, "LICENSE"), "licence text")
	fixtures.repository_release(&fixture, "alpha", "v1.0.0")
	fixtures.project_imports(&fixture, "alpha")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--yes"), "has no Odin files to install")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "alpha")))
}

@(test)
local_origin_is_portable_and_legacy_pin_is_preserved :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	repository := krs.path_join(fixture.sources, "beta")
	fixtures.git(t, repository, "remote", "add", "origin", krs.path_join(fixture.base, "upstream"))
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	packages := fixtures.packages_text(&fixture)
	fixtures.expect_contains(&fixture, packages, "\"source\": \"local\"")
	testing.expect(t, !strings.contains(packages, fixture.base))
	legacy, _ := strings.replace_all(packages, "\"local\"", fmt.aprintf("\"%s/upstream\"", fixture.base))
	fixtures.write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), legacy)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen"))
	testing.expect_value(t, fixtures.packages_text(&fixture), legacy)
}

@(test)
install_skips_symbolic_links_in_a_release :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	path := fixtures.repository_make(&fixture, "alpha")
	fixtures.write_file(t, krs.path_join(path, "LICENSE"), "licence text\n")
	fixtures.write_file(t, krs.path_join(path, "data/runtime.js"), "export const released = true\n")
	fixtures.write_file(t, krs.path_join(path, "src/alpha.odin"), "package alpha\n\nRUNTIME :: #load(\"assets/runtime.js\", string)\n")
	err1 := os.symlink("../LICENSE", krs.path_join(path, "src/LICENSE"))
	os.make_directory_all(krs.path_join(path, "src/assets"))
	err2 := os.symlink("../../data/runtime.js", krs.path_join(path, "src/assets/runtime.js"))
	testing.expect(t, err1 == nil && err2 == nil)
	fixtures.repository_release(&fixture, "alpha", "v0.1.0")

	fixtures.project_imports(&fixture, "alpha")
	result := fixtures.run(&fixture, "", "install", "--yes")
	fixtures.expect_ok(&fixture, result)

	testing.expect_value(t, fixtures.read_file(krs.path_join(fixture.shared, "alpha/LICENSE")), "licence text\n")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "alpha/assets/runtime.js")))
	fixtures.expect_contains(&fixture, result.out, "which is a symbolic link in the release")
}

@(test)
install_reports_a_load_into_a_submodule :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "alpha", "v0.1.0")
	path := krs.path_join(fixture.sources, "alpha")
	first := fixtures.git(t, path, "rev-parse", "HEAD")

	// A gitlink without a real submodule. `repository_release` would stage the
	// missing directory as a deletion, so commit and tag directly.
	fixtures.git(t, path, "update-index", "--add", "--cacheinfo", fmt.aprintf("160000,%s,src/vendor", first))
	fixtures.write_file(t, krs.path_join(path, "src/alpha.odin"), "package alpha\n\nX :: #load(\"vendor/x.txt\", string)\nRELEASE :: \"v0.2.0\"\n")
	fixtures.git(t, path, "add", "src/alpha.odin")
	fixtures.git(t, path, "commit", "--quiet", "-m", "v0.2.0")
	fixtures.git(t, path, "tag", "v0.2.0")

	fixtures.project_imports(&fixture, "alpha")
	result := fixtures.run(&fixture, "", "install", "--yes")
	fixtures.expect_ok(&fixture, result)

	fixtures.expect_contains(&fixture, result.out, "inside submodule src/vendor")
}

@(test)
install_refuses_case_colliding_paths :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	path := fixtures.repository_make(&fixture, "alpha")
	fixtures.write_file(t, krs.path_join(path, "src/alpha.odin"), "package alpha\n\nA :: #load(\"Data.txt\", string)\nB :: #load(\"data.txt\", string)\n")
	fixtures.git(t, path, "add", "src/alpha.odin")

	// The blob lives outside the repository so `git add` never sees it. Both
	// index entries are added with case-sensitive matching.
	blob_source := krs.path_join(fixture.base, "blob.txt")
	fixtures.write_file(t, blob_source, "data\n")
	blob := fixtures.git(t, path, "hash-object", "-w", blob_source)
	fixtures.git(t, path, "-c", "core.ignorecase=false", "update-index", "--add", "--cacheinfo", fmt.aprintf("100644,%s,src/Data.txt", blob))
	fixtures.git(t, path, "-c", "core.ignorecase=false", "update-index", "--add", "--cacheinfo", fmt.aprintf("100644,%s,src/data.txt", blob))
	fixtures.git(t, path, "commit", "--quiet", "-m", "v0.1.0")
	fixtures.git(t, path, "tag", "v0.1.0")

	fixtures.project_imports(&fixture, "alpha")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--yes"), "differ only in letter case")

	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "alpha")))
}

@(test)
repair_refuses_a_pin_the_root_has_moved :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&a)
	b := fixtures.pinned_divergence(&a)
	defer fixtures.fixture_destroy(&b)

	fixtures.write_file(t, krs.path_join(a.shared, "beta/extra.txt"), "x")
	fixtures.expect_failure(&a, fixtures.run(&a, "", "install", "--repair", "--yes"), "is pinned at v0.1.0")
	fixtures.expect_release(&a, "beta", "v0.2.0")
}

@(test)
unpinned_import_defers_to_a_pin_visited_second :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "gamma", "v1.2.0")
	fixtures.library_release(&fixture, "gamma", "v1.4.0")
	fixtures.library_release(&fixture, "alpha", "v1.0.0", "gamma")
	fixtures.library_recording(&fixture, "beta", "v1.0.0", "gamma", "v1.2.0")
	fixtures.project_imports(&fixture, "alpha", "beta")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_release(&fixture, "gamma", "v1.2.0")
}

@(test)
unpinned_import_defers_to_a_pin_visited_first :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "gamma", "v1.2.0")
	fixtures.library_release(&fixture, "gamma", "v1.4.0")
	fixtures.library_recording(&fixture, "alpha", "v1.0.0", "gamma", "v1.2.0")
	fixtures.library_release(&fixture, "beta", "v1.0.0", "gamma")
	fixtures.project_imports(&fixture, "alpha", "beta")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_release(&fixture, "gamma", "v1.2.0")
}

@(test)
unpinned_import_does_not_raise_a_breaking_question :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "gamma", "v1.2.0")
	fixtures.library_release(&fixture, "gamma", "v2.0.0")
	fixtures.library_release(&fixture, "alpha", "v1.0.0", "gamma")
	fixtures.library_recording(&fixture, "beta", "v1.0.0", "gamma", "v1.2.0")
	fixtures.project_imports(&fixture, "alpha", "beta")

	result := fixtures.run(&fixture, "", "install", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_release(&fixture, "gamma", "v1.2.0")
	testing.expect(t, !strings.contains(result.err, "needs a decision"), result.err)
	testing.expect(t, !strings.contains(result.out, "are not compatible"), result.out)
}

@(test)
compatible_difference_takes_the_higher :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
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
	fixtures.expect_contains(&fixture, result.out, "are compatible; using v0.4.2")
	fixtures.expect_contains(&fixture, result.out, "replace beta v0.4.0 with v0.4.2")
	fixtures.expect_release(&fixture, "beta", "v0.4.2")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"tag\": \"v0.4.2\"")
}

@(test)
compatible_update_respects_the_dependency_commit_pin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.4.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	fixtures.library_release(&fixture, "beta", "v0.4.2")
	fixtures.alpha_recording_beta(&fixture, "v1.0.0", "v0.4.2")
	new_commit := fixtures.library_release(&fixture, "beta", "v0.4.3")
	fixtures.git(t, krs.path_join(fixture.sources, "beta"), "tag", "--force", "v0.4.2", new_commit)
	fixtures.project_imports(&fixture, "alpha", "beta")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--yes"), "a published tag must not move")
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "alpha")))
}

@(test)
dependency_lockfile_cannot_redirect_a_local_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	commit := fixtures.library_release(&fixture, "beta", "v1.0.0")
	pins := fmt.aprintf(
		"{{\"format\": 1, \"packages\": [{{\"name\": \"beta\", \"source\": \"https://github.com/other/unrelated.git\", \"tag\": \"v1.0.0\", \"commit\": \"%s\", \"hash\": \"\"}}]}}\n",
		commit,
	)
	fixtures.repository_make(&fixture, "alpha")
	fixtures.write_file(t, krs.path_join(fixture.sources, "alpha/.krs/packages.json"), pins)
	fixtures.library_release(&fixture, "alpha", "v1.0.0", "beta")
	fixtures.project_imports(&fixture, "alpha")

	result := fixtures.run(&fixture, "", "install", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_release(&fixture, "beta", "v1.0.0")
	fixtures.expect_contains(&fixture, result.out, "pins beta from")
}

@(test)
install_ignores_dependencies_dropped_by_a_later_version_selection :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	for obsolete_available in ([2]bool{false, true}) {
		fixture := fixtures.fixture_make(t)
		defer fixtures.fixture_destroy(&fixture)

		old_commit := fixtures.library_release(&fixture, "alpha", "v1.0.0", "former")
		new_commit := fixtures.library_release(&fixture, "alpha", "v1.1.0")
		if obsolete_available {
			fixtures.library_release(&fixture, "former", "v1.0.0")
		}

		zeta := fixtures.repository_make(&fixture, "zeta")
		fixtures.write_file(t, krs.path_join(zeta, krs.PACKAGES_PATH), fmt.aprintf(
			`{{"format":1,"packages":[{{"name":"alpha","source":"local","tag":"v1.1.0","commit":"%s"}}]}}`,
			new_commit,
		))
		fixtures.library_release(&fixture, "zeta", "v1.0.0", "alpha")
		fixtures.write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), fmt.aprintf(
			`{{"format":1,"packages":[{{"name":"alpha","source":"local","tag":"v1.0.0","commit":"%s"}}]}}`,
			old_commit,
		))
		fixtures.project_imports(&fixture, "alpha", "zeta")

		result := fixtures.run(&fixture, "", "install", "--yes")
		fixtures.expect_ok(&fixture, result)
		fixtures.expect_release(&fixture, "alpha", "v1.1.0")
		fixtures.expect_release(&fixture, "zeta", "v1.0.0")
		testing.expect(t, !os.exists(krs.path_join(fixture.shared, "former")))
		testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "former"))
		testing.expect_value(t, result.err, "")
		fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen"))
	}
}

@(test)
install_reconsiders_a_dependency_when_an_older_parent_pin_is_dropped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	old_gamma := fixtures.library_release(&fixture, "gamma", "v1.0.0")
	new_gamma := fixtures.library_release(&fixture, "gamma", "v1.1.0")
	alpha := fixtures.repository_make(&fixture, "alpha")
	fixtures.write_file(t, krs.path_join(alpha, krs.PACKAGES_PATH), fmt.aprintf(
		`{{"format":1,"packages":[{{"name":"gamma","source":"local","tag":"v1.1.0","commit":"%s"}}]}}`,
		new_gamma,
	))
	old_alpha := fixtures.library_release(&fixture, "alpha", "v1.0.0", "gamma")
	new_alpha := fixtures.library_release(&fixture, "alpha", "v1.1.0")
	zeta := fixtures.repository_make(&fixture, "zeta")
	fixtures.write_file(t, krs.path_join(zeta, krs.PACKAGES_PATH), fmt.aprintf(
		`{{"format":1,"packages":[{{"name":"alpha","source":"local","tag":"v1.1.0","commit":"%s"}},{{"name":"gamma","source":"local","tag":"v1.0.0","commit":"%s"}}]}}`,
		new_alpha,
		old_gamma,
	))
	fixtures.library_release(&fixture, "zeta", "v1.0.0", "alpha", "gamma")
	fixtures.write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), fmt.aprintf(
		`{{"format":1,"packages":[{{"name":"alpha","source":"local","tag":"v1.0.0","commit":"%s"}}]}}`,
		old_alpha,
	))
	fixtures.project_imports(&fixture, "alpha", "zeta")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_release(&fixture, "alpha", "v1.1.0")
	fixtures.expect_release(&fixture, "gamma", "v1.0.0")
}

@(test)
install_reports_dependency_choices_that_do_not_stabilize :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	old_beta := fixtures.library_release(&fixture, "beta", "v1.0.0", "alpha")
	fixtures.library_release(&fixture, "beta", "v1.1.0")
	fixtures.alpha_recording_beta(&fixture, "v1.0.0", "v1.1.0")
	pin := fmt.aprintf(
		`{{"format":1,"packages":[{{"name":"beta","source":"local","tag":"v1.0.0","commit":"%s"}}]}}`,
		old_beta,
	)
	fixtures.write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), pin)
	fixtures.project_imports(&fixture, "beta")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--yes"), "the dependency graph does not stabilize")
	testing.expect_value(t, fixtures.packages_text(&fixture), pin)
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "beta")))
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "alpha")))
}

@(test)
breaking_difference_is_the_users_choice :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.4.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	recorded := fixtures.packages_text(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.5.0")
	fixtures.alpha_recording_beta(&fixture, "v1.0.0", "v0.5.0")
	fixtures.project_imports(&fixture, "alpha", "beta")

	// Nobody to ask: stop with a report and change nothing.
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--yes"), "needs a decision between v0.4.0 and v0.5.0")
	// --frozen holds beta; alpha is not recorded, so it still refuses.
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--frozen"), "packages.json would change")
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "alpha")))
	testing.expect_value(t, fixtures.packages_text(&fixture), recorded)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "v9.9.9\n", "install", "--yes"), "is neither v0.5.0 nor v0.4.0")

	// Keeping the older one installs the newcomer and leaves beta alone.
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "v0.4.0\n", "install", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
	fixtures.expect_release(&fixture, "alpha", "v1.0.0")

	// Asked again, the proposed answer is the higher one.
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "\ny\n", "install"))
	fixtures.expect_release(&fixture, "beta", "v0.5.0")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"tag\": \"v0.5.0\"")
}

@(test)
dependency_pins_with_invalid_fields_are_refused :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	Row :: struct { tag, commit, expected: string }
	for row in ([2]Row{
		{tag = "latest", commit = "", expected = "records beta with an invalid tag"},
		{tag = "v0.1.0", commit = "zz", expected = "records beta with an invalid commit"},
	}) {
		fixture := fixtures.fixture_make(t)
		defer fixtures.fixture_destroy(&fixture)

		fixtures.library_release(&fixture, "beta", "v0.1.0")
		commit := row.commit
		if commit == "" {
			commit = fixtures.git(t, krs.path_join(fixture.sources, "beta"), "rev-parse", "v0.1.0^{commit}")
		}
		pins := fmt.aprintf(
			"{{\"format\": 1, \"packages\": [{{\"name\": \"beta\", \"source\": \"local\", \"tag\": \"%s\", \"commit\": \"%s\", \"hash\": \"\"}}]}}\n",
			row.tag,
			commit,
		)
		fixtures.repository_make(&fixture, "alpha")
		fixtures.write_file(t, krs.path_join(fixture.sources, "alpha/.krs/packages.json"), pins)
		fixtures.library_release(&fixture, "alpha", "v1.0.0", "beta")
		fixtures.project_imports(&fixture, "alpha")

		fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--yes"), row.expected)
	}
}

// Builds delta <- gamma <- beta <- alpha, each importing the next.
resolution_chain :: proc(fixture: ^fixtures.Fixture) {
	fixtures.library_release(fixture, "delta", "v0.1.0")
	fixtures.library_release(fixture, "gamma", "v0.1.0", "delta")
	fixtures.library_release(fixture, "beta", "v0.1.0", "gamma")
	fixtures.library_release(fixture, "alpha", "v0.1.0", "beta")
	fixtures.project_imports(fixture, "alpha")
}

// Resolves the project once and returns what the resolution touched.
resolution_counts :: proc(t: ^testing.T, fixture: ^fixtures.Fixture) -> (counts: krs.Resolution_Counts, ok: bool) {
	output := strings.builder_make()
	env := krs.Env {
		project      = fixture.project,
		home         = fixture.home,
		default_root = fixture.root,
		out          = strings.to_writer(&output),
		err          = strings.to_writer(&output),
	}
	state, opened := krs.state_open(&env, {})
	if !testing.expect(t, opened, strings.to_string(output)) {
		return {}, false
	}
	defer krs.state_close(state)

	resolved := krs.plan_discover(state) && krs.plan_drain(state)
	testing.expect(t, resolved, strings.to_string(output))
	log.infof("%v", state.counts)
	return state.counts, resolved
}

@(test)
resolution_touches_each_repository_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	{
		// A fresh root: every package resolves from scratch on each pass.
		fixture := fixtures.fixture_make(t)
		defer fixtures.fixture_destroy(&fixture)
		resolution_chain(&fixture)

		counts, ok := resolution_counts(t, &fixture)
		if ok {
			testing.expectf(t, counts.repository_opens == 4, "%v", counts)
			testing.expectf(t, counts.tag_resolves == 4, "%v", counts)
			testing.expectf(t, counts.selections == 4, "%v", counts)
		}
	}

	{
		// After an install: every package is kept at its own project pin.
		fixture := fixtures.fixture_make(t)
		defer fixtures.fixture_destroy(&fixture)
		resolution_chain(&fixture)
		fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

		counts, ok := resolution_counts(t, &fixture)
		if ok {
			testing.expectf(t, counts.installed_hashes == 4, "%v", counts)
			testing.expectf(t, counts.selections == 4, "%v", counts)
		}
	}
}

@(test)
unpinned_lockfiles_do_not_gain_a_pinned_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"tag\": \"v0.1.0\"")
	testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "pinned"))
}

@(test)
nested_project_imports_stay_out_of_the_parent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.library_release(&fixture, "gamma", "v1.0.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.write_file(t, krs.path_join(fixture.project, "tools/gen/main.odin"), "package main\n\nimport \"shared:gamma\"\n")
	fixtures.write_file(t, krs.path_join(fixture.project, "tools/gen/.krs/packages.json"), "{\"format\": 1, \"packages\": []}\n")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"beta\"")
	testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "\"gamma\""))
}

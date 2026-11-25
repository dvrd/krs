package tests

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../src"

@(test)
cli_version_uses_the_release_tag_format :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	// Version reporting does not require an Odin root or a valid package lock.
	os.remove_all(fixture.root)
	write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), "invalid JSON")
	result := run(&fixture, "", "--version")
	expect_ok(&fixture, result)
	testing.expect_value(t, result.out, fmt.aprintf("krs %s\n", strings.trim_space(krs.RELEASE_TAG)))
}

// `alpha` is released recording `beta` at `beta_tag`.
alpha_recording_beta :: proc(fixture: ^Fixture, alpha_tag, beta_tag: string) {
	commit := git(fixture.t, krs.path_join(fixture.sources, "beta"), "rev-parse", fmt.aprintf("%s^{{commit}}", beta_tag))
	pins := fmt.aprintf(
		"{{\"format\": 1, \"packages\": [{{\"name\": \"beta\", \"source\": \"local\", \"tag\": \"%s\", \"commit\": \"%s\", \"hash\": \"\"}}]}}\n",
		beta_tag,
		commit,
	)

	if !os.is_directory(krs.path_join(fixture.sources, "alpha")) {
		repository_make(fixture, "alpha")
	}
	write_file(fixture.t, krs.path_join(fixture.sources, "alpha/.krs/packages.json"), pins)
	library_release(fixture, "alpha", alpha_tag, "beta")
}

// `name` is released recording `dependency` at `dependency_tag`.
library_recording :: proc(fixture: ^Fixture, name, tag, dependency, dependency_tag: string) {
	commit := git(fixture.t, krs.path_join(fixture.sources, dependency), "rev-parse", fmt.aprintf("%s^{{commit}}", dependency_tag))
	pins := fmt.aprintf(
		"{{\"format\": 1, \"packages\": [{{\"name\": \"%s\", \"source\": \"local\", \"tag\": \"%s\", \"commit\": \"%s\", \"hash\": \"\"}}]}}\n",
		dependency,
		dependency_tag,
		commit,
	)

	if !os.is_directory(krs.path_join(fixture.sources, name)) {
		repository_make(fixture, name)
	}
	write_file(fixture.t, krs.path_join(fixture.sources, fmt.aprintf("%s/.krs/packages.json", name)), pins)
	library_release(fixture, name, tag, dependency)
}

@(test)
unpinned_import_defers_to_a_pin_visited_second :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "gamma", "v1.2.0")
	library_release(&fixture, "gamma", "v1.4.0")
	library_release(&fixture, "alpha", "v1.0.0", "gamma")
	library_recording(&fixture, "beta", "v1.0.0", "gamma", "v1.2.0")
	project_imports(&fixture, "alpha", "beta")

	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_release(&fixture, "gamma", "v1.2.0")
}

@(test)
unpinned_import_defers_to_a_pin_visited_first :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "gamma", "v1.2.0")
	library_release(&fixture, "gamma", "v1.4.0")
	library_recording(&fixture, "alpha", "v1.0.0", "gamma", "v1.2.0")
	library_release(&fixture, "beta", "v1.0.0", "gamma")
	project_imports(&fixture, "alpha", "beta")

	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_release(&fixture, "gamma", "v1.2.0")
}

@(test)
unpinned_import_does_not_raise_a_breaking_question :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "gamma", "v1.2.0")
	library_release(&fixture, "gamma", "v2.0.0")
	library_release(&fixture, "alpha", "v1.0.0", "gamma")
	library_recording(&fixture, "beta", "v1.0.0", "gamma", "v1.2.0")
	project_imports(&fixture, "alpha", "beta")

	result := run(&fixture, "", "install", "--yes")
	expect_ok(&fixture, result)
	expect_release(&fixture, "gamma", "v1.2.0")
	testing.expect(t, !strings.contains(result.err, "needs a decision"), result.err)
	testing.expect(t, !strings.contains(result.out, "are not compatible"), result.out)
}

@(test)
compatible_difference_takes_the_higher :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.4.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	library_release(&fixture, "beta", "v0.4.2")
	alpha_recording_beta(&fixture, "v1.0.0", "v0.4.2")
	project_imports(&fixture, "alpha", "beta")

	result := run(&fixture, "", "install", "--yes")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "are compatible; using v0.4.2")
	expect_contains(&fixture, result.out, "replace beta v0.4.0 with v0.4.2")
	expect_release(&fixture, "beta", "v0.4.2")
	expect_contains(&fixture, packages_text(&fixture), "\"tag\": \"v0.4.2\"")
}

@(test)
compatible_update_respects_the_dependency_commit_pin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.4.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	library_release(&fixture, "beta", "v0.4.2")
	alpha_recording_beta(&fixture, "v1.0.0", "v0.4.2")
	new_commit := library_release(&fixture, "beta", "v0.4.3")
	git(t, krs.path_join(fixture.sources, "beta"), "tag", "--force", "v0.4.2", new_commit)
	project_imports(&fixture, "alpha", "beta")

	expect_failure(&fixture, run(&fixture, "", "install", "--yes"), "a published tag must not move")
	expect_release(&fixture, "beta", "v0.4.0")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "alpha")))
}

@(test)
dependency_lockfile_cannot_redirect_a_local_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	commit := library_release(&fixture, "beta", "v1.0.0")
	pins := fmt.aprintf(
		"{{\"format\": 1, \"packages\": [{{\"name\": \"beta\", \"source\": \"https://github.com/other/unrelated.git\", \"tag\": \"v1.0.0\", \"commit\": \"%s\", \"hash\": \"\"}}]}}\n",
		commit,
	)
	repository_make(&fixture, "alpha")
	write_file(t, krs.path_join(fixture.sources, "alpha/.krs/packages.json"), pins)
	library_release(&fixture, "alpha", "v1.0.0", "beta")
	project_imports(&fixture, "alpha")

	result := run(&fixture, "", "install", "--yes")
	expect_ok(&fixture, result)
	expect_release(&fixture, "beta", "v1.0.0")
	expect_contains(&fixture, result.out, "pins beta from")
}

@(test)
install_ignores_dependencies_dropped_by_a_later_version_selection :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	for obsolete_available in ([2]bool{false, true}) {
		fixture := fixture_make(t)
		defer fixture_destroy(&fixture)

		old_commit := library_release(&fixture, "alpha", "v1.0.0", "former")
		new_commit := library_release(&fixture, "alpha", "v1.1.0")
		if obsolete_available {
			library_release(&fixture, "former", "v1.0.0")
		}

		zeta := repository_make(&fixture, "zeta")
		write_file(t, krs.path_join(zeta, krs.PACKAGES_PATH), fmt.aprintf(
			`{{"format":1,"packages":[{{"name":"alpha","source":"local","tag":"v1.1.0","commit":"%s"}}]}}`,
			new_commit,
		))
		library_release(&fixture, "zeta", "v1.0.0", "alpha")
		write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), fmt.aprintf(
			`{{"format":1,"packages":[{{"name":"alpha","source":"local","tag":"v1.0.0","commit":"%s"}}]}}`,
			old_commit,
		))
		project_imports(&fixture, "alpha", "zeta")

		result := run(&fixture, "", "install", "--yes")
		expect_ok(&fixture, result)
		expect_release(&fixture, "alpha", "v1.1.0")
		expect_release(&fixture, "zeta", "v1.0.0")
		testing.expect(t, !os.exists(krs.path_join(fixture.shared, "former")))
		testing.expect(t, !strings.contains(packages_text(&fixture), "former"))
		testing.expect_value(t, result.err, "")
		expect_ok(&fixture, run(&fixture, "", "install", "--frozen"))
	}
}

@(test)
install_reconsiders_a_dependency_when_an_older_parent_pin_is_dropped :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	old_gamma := library_release(&fixture, "gamma", "v1.0.0")
	new_gamma := library_release(&fixture, "gamma", "v1.1.0")
	alpha := repository_make(&fixture, "alpha")
	write_file(t, krs.path_join(alpha, krs.PACKAGES_PATH), fmt.aprintf(
		`{{"format":1,"packages":[{{"name":"gamma","source":"local","tag":"v1.1.0","commit":"%s"}}]}}`,
		new_gamma,
	))
	old_alpha := library_release(&fixture, "alpha", "v1.0.0", "gamma")
	new_alpha := library_release(&fixture, "alpha", "v1.1.0")
	zeta := repository_make(&fixture, "zeta")
	write_file(t, krs.path_join(zeta, krs.PACKAGES_PATH), fmt.aprintf(
		`{{"format":1,"packages":[{{"name":"alpha","source":"local","tag":"v1.1.0","commit":"%s"}},{{"name":"gamma","source":"local","tag":"v1.0.0","commit":"%s"}}]}}`,
		new_alpha,
		old_gamma,
	))
	library_release(&fixture, "zeta", "v1.0.0", "alpha", "gamma")
	write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), fmt.aprintf(
		`{{"format":1,"packages":[{{"name":"alpha","source":"local","tag":"v1.0.0","commit":"%s"}}]}}`,
		old_alpha,
	))
	project_imports(&fixture, "alpha", "zeta")

	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_release(&fixture, "alpha", "v1.1.0")
	expect_release(&fixture, "gamma", "v1.0.0")
}

@(test)
install_reports_dependency_choices_that_do_not_stabilize :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	old_beta := library_release(&fixture, "beta", "v1.0.0", "alpha")
	library_release(&fixture, "beta", "v1.1.0")
	alpha_recording_beta(&fixture, "v1.0.0", "v1.1.0")
	pin := fmt.aprintf(
		`{{"format":1,"packages":[{{"name":"beta","source":"local","tag":"v1.0.0","commit":"%s"}}]}}`,
		old_beta,
	)
	write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), pin)
	project_imports(&fixture, "beta")

	expect_failure(&fixture, run(&fixture, "", "install", "--yes"), "the dependency graph does not stabilize")
	testing.expect_value(t, packages_text(&fixture), pin)
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "beta")))
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "alpha")))
}

@(test)
breaking_difference_is_the_users_choice :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.4.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	recorded := packages_text(&fixture)

	library_release(&fixture, "beta", "v0.5.0")
	alpha_recording_beta(&fixture, "v1.0.0", "v0.5.0")
	project_imports(&fixture, "alpha", "beta")

	// Nobody to ask: stop with a report and change nothing.
	expect_failure(&fixture, run(&fixture, "", "install", "--yes"), "needs a decision between v0.4.0 and v0.5.0")
	expect_failure(&fixture, run(&fixture, "", "install", "--frozen"), "needs a decision between v0.4.0 and v0.5.0")
	expect_release(&fixture, "beta", "v0.4.0")
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "alpha")))
	testing.expect_value(t, packages_text(&fixture), recorded)

	expect_failure(&fixture, run(&fixture, "v9.9.9\n", "install", "--yes"), "is neither v0.5.0 nor v0.4.0")

	// Keeping the older one installs the newcomer and leaves beta alone.
	expect_ok(&fixture, run(&fixture, "v0.4.0\n", "install", "--yes"))
	expect_release(&fixture, "beta", "v0.4.0")
	expect_release(&fixture, "alpha", "v1.0.0")

	// Asked again, the proposed answer is the higher one.
	expect_ok(&fixture, run(&fixture, "\ny\n", "install"))
	expect_release(&fixture, "beta", "v0.5.0")
	expect_contains(&fixture, packages_text(&fixture), "\"tag\": \"v0.5.0\"")
}

@(test)
update_moves_one_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.4.0")
	alpha_recording_beta(&fixture, "v1.0.0", "v0.4.0")
	library_release(&fixture, "gamma", "v0.1.0")
	project_imports(&fixture, "alpha", "beta", "gamma")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	library_release(&fixture, "beta", "v0.4.1")
	library_release(&fixture, "beta", "v0.5.0")
	library_release(&fixture, "gamma", "v0.1.1")

	// With no argument it only lists.
	listing := run(&fixture, "", "update")
	expect_ok(&fixture, listing)
	expect_contains(&fixture, squeeze(listing.out), "beta v0.4.0 -> v0.5.0")
	expect_contains(&fixture, squeeze(listing.out), "gamma v0.1.0 -> v0.1.1")
	expect_contains(&fixture, listing.out, "Major version zero")
	testing.expect(t, !strings.contains(listing.out, "alpha"))
	expect_release(&fixture, "beta", "v0.4.0")

	expect_failure(&fixture, run(&fixture, "", "update", "beta", "-u"), "confirmation is needed")
	expect_release(&fixture, "beta", "v0.4.0")

	result := run(&fixture, "", "update", "beta", "-u", "--yes")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "beta v0.4.0 -> v0.5.0 (breaking)")
	expect_contains(&fixture, result.out, "alpha v1.0.0 recorded beta v0.4.0")
	expect_release(&fixture, "beta", "v0.5.0")
	expect_release(&fixture, "gamma", "v0.1.0")
	expect_contains(&fixture, packages_text(&fixture), "\"tag\": \"v0.5.0\"")
	expect_contains(&fixture, manifest_text(&fixture), "\"tag\": \"v0.5.0\"")

	// A named tag may be an older one.
	expect_ok(&fixture, run(&fixture, "", "update", "beta@v0.4.1", "-u", "--yes"))
	expect_release(&fixture, "beta", "v0.4.1")
	expect_contains(&fixture, packages_text(&fixture), "\"tag\": \"v0.4.1\"")

	result = run(&fixture, "", "update", "beta@v7.0.0", "-u", "--yes")
	expect_failure(&fixture, result, "could not check 1 package(s)")
	expect_contains(&fixture, result.out, "has no tag v7.0.0")
	expect_failure(&fixture, run(&fixture, "", "update", "beta@latest", "-u", "--yes"), "not a vMAJOR.MINOR.PATCH tag")
}

@(test)
update_refuses_a_package_this_project_does_not_use :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	other := fixture_make(t)
	defer fixture_destroy(&other)
	other.root = fixture.root
	other.shared = fixture.shared
	other.home = fixture.home
	other.sources = fixture.sources
	project_imports(&other)

	library_release(&fixture, "beta", "v0.2.0")
	expect_failure(&fixture, run(&other, "", "update", "beta", "-u", "--yes"), "is not used by this project")
	expect_release(&fixture, "beta", "v0.1.0")
	testing.expect(t, !os.exists(krs.path_join(other.project, krs.PACKAGES_PATH)))
}

@(test)
update_moves_the_project_pin_when_the_root_is_already_there :: proc(t: ^testing.T) {
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
	expect_ok(&a, run(&a, "", "update", "beta", "-u", "--yes"))
	expect_release(&a, "beta", "v0.2.0")

	result := run(&b, "", "update", "beta", "-u", "--yes")
	expect_ok(&b, result)
	testing.expect(t, !strings.contains(result.out, "is already at"))
	expect_contains(&b, read_file(krs.path_join(b.project, krs.PACKAGES_PATH)), "\"tag\": \"v0.2.0\"")
}

@(test)
update_reports_already_at :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	result := run(&fixture, "", "update", "beta@v0.1.0", "-u", "--yes")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "beta is already at v0.1.0")
}

@(test)
update_listing_reports_unavailable_sources :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	fixture_config(&fixture, {krs.path_join(fixture.base, "other-sources")})

	result := run(&fixture, "", "update")
	expect_failure(&fixture, result, "could not check 1 package(s) for updates")
	expect_contains(&fixture, result.out, "cannot check beta: no usable repository")
	testing.expect(t, !strings.contains(result.out, "at its highest tag"))
}

@(test)
unlink_restore_prefers_the_project_pin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	// A second project on the same root moves the shared release forward.
	second := fixture
	second.project = krs.path_join(fixture.base, "second")
	os.make_directory_all(second.project)
	project_imports(&second, "beta")
	library_release(&fixture, "beta", "v0.2.0")
	expect_ok(&second, run(&second, "", "update", "beta", "-u", "--yes"))
	expect_release(&fixture, "beta", "v0.2.0")
	expect_contains(&fixture, packages_text(&second), "\"tag\": \"v0.2.0\"")
	expect_contains(&fixture, packages_text(&fixture), "\"tag\": \"v0.1.0\"")

	expect_ok(&fixture, run(&fixture, "", "link", "beta"))
	expect_ok(&fixture, run(&fixture, "", "unlink", "beta", "--restore", "--yes"))
	expect_release(&fixture, "beta", "v0.1.0")
}

@(test)
link_and_unlink :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	alpha_release(&fixture)
	project_imports(&fixture, "alpha")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	recorded := packages_text(&fixture)
	installed_hash, installed_ok := krs.hash_directory(krs.path_join(fixture.shared, "alpha"))
	testing.expect(t, installed_ok, "the installed package can be hashed")

	expect_ok(&fixture, run(&fixture, "", "link", "alpha"))
	link := krs.path_join(fixture.shared, "alpha")
	source := krs.path_join(fixture.sources, "alpha/src")
	testing.expect(t, krs.is_symbolic_link(link))
	expect_contains(&fixture, manifest_text(&fixture), fmt.aprintf("\"linked\": \"%s\"", source))
	testing.expect_value(t, packages_text(&fixture), recorded)

	linked_again := run(&fixture, "", "link", "alpha")
	expect_ok(&fixture, linked_again)
	expect_contains(&fixture, linked_again.out, fmt.aprintf("alpha is already linked to %s", source))
	testing.expect(t, !strings.contains(linked_again.out, "every project on this Odin root"))
	testing.expect(t, krs.is_symbolic_link(link))

	// An edit in the repository is what the compiler now sees.
	write_file(t, krs.path_join(source, "alpha.odin"), "package alpha\n\nRELEASE :: \"working copy\"\n")
	expect_release(&fixture, "alpha", "working copy")

	listed := run(&fixture, "", "install")
	expect_ok(&fixture, listed)
	expect_contains(&fixture, listed.out, fmt.aprintf("linked: alpha -> %s", source))
	testing.expect(t, krs.is_symbolic_link(link), "install leaves a linked package alone")
	testing.expect_value(t, packages_text(&fixture), recorded)
	expect_failure(&fixture, run(&fixture, "", "install", "--frozen"), "alpha is linked")
	expect_failure(&fixture, run(&fixture, "", "update", "alpha", "-u", "--yes"), "alpha is linked")

	misplaced := run(&fixture, "", "install", "--restore")
	testing.expect_value(t, misplaced.code, krs.EXIT_USAGE)
	expect_contains(&fixture, misplaced.err, "--restore only applies to unlink")

	// By default unlink only removes the link, even when a release is recorded.
	removed := run(&fixture, "", "unlink", "alpha")
	expect_ok(&fixture, removed)
	expect_contains(&fixture, removed.out, "alpha is unlinked and removed")
	testing.expect(t, !krs.path_present(link))
	testing.expect(t, !strings.contains(manifest_text(&fixture), "\"alpha\""))
	testing.expect_value(t, packages_text(&fixture), recorded)

	expect_ok(&fixture, run(&fixture, "", "link", "alpha"))
	linked_manifest := manifest_text(&fixture)
	expect_failure(&fixture, run(&fixture, "", "unlink", "alpha", "--restore"), "confirmation is needed")
	testing.expect(t, krs.is_symbolic_link(link))
	testing.expect_value(t, manifest_text(&fixture), linked_manifest)

	unlinked := run(&fixture, "", "unlink", "alpha", "--restore", "--yes")
	expect_ok(&fixture, unlinked)
	expect_contains(&fixture, unlinked.out, "src/notes/design.md is not named by any Odin file")
	expect_contains(&fixture, unlinked.out, "src/assets/unused.js is not named by any Odin file")
	testing.expect(t, !krs.is_symbolic_link(link))
	expect_release(&fixture, "alpha", "v0.1.0")
	restored_hash, restored_ok := krs.hash_directory(link)
	testing.expect(t, restored_ok, "the restored package can be hashed")
	testing.expect_value(t, restored_hash, installed_hash)
	testing.expect(t, !strings.contains(manifest_text(&fixture), "linked"))
	testing.expect_value(t, packages_text(&fixture), recorded)
	expect_contains(&fixture, read_file(krs.path_join(source, "alpha.odin")), "working copy")

	expect_failure(&fixture, run(&fixture, "", "unlink", "alpha"), "is not linked")
}

@(test)
link_asks_before_replacing_changed_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	link := krs.path_join(fixture.shared, "beta")
	edited := krs.path_join(fixture.shared, "beta/beta.odin")
	write_file(t, edited, "package beta\n\nEDITED :: true\n")

	expect_failure(&fixture, run(&fixture, "", "link", "beta"), "confirmation is needed")
	testing.expect(t, !krs.is_symbolic_link(link))
	expect_contains(&fixture, read_file(edited), "EDITED")

	expect_failure(&fixture, run(&fixture, "n\n", "link", "beta"), "nothing was changed")
	testing.expect(t, !krs.is_symbolic_link(link))
	expect_contains(&fixture, read_file(edited), "EDITED")

	linked := run(&fixture, "y\n", "link", "beta")
	expect_ok(&fixture, linked)
	expect_contains(&fixture, linked.out, "linking deletes them")
	testing.expect(t, krs.is_symbolic_link(link))
}

@(test)
link_replaces_an_unchanged_install_without_asking :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	write_file(t, krs.path_join(fixture.shared, "beta/.DS_Store"), "metadata")

	linked := run(&fixture, "", "link", "beta")
	expect_ok(&fixture, linked)
	testing.expect(t, !strings.contains(linked.out, "linking deletes them"))
}

@(test)
link_with_yes_replaces_changed_files_and_warns :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")

	linked := run(&fixture, "", "link", "beta", "--yes")
	expect_ok(&fixture, linked)
	expect_contains(&fixture, linked.out, "linking deletes them")
	testing.expect(t, krs.is_symbolic_link(krs.path_join(fixture.shared, "beta")))
}

@(test)
unlink_refuses_a_moved_tag_and_preserves_the_link :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_ok(&fixture, run(&fixture, "", "link", "beta"))
	manifest := manifest_text(&fixture)
	packages := packages_text(&fixture)

	new_commit := library_release(&fixture, "beta", "v1.0.1")
	git(t, krs.path_join(fixture.sources, "beta"), "tag", "--force", "v1.0.0", new_commit)

	expect_failure(&fixture, run(&fixture, "", "unlink", "beta", "--restore", "--yes"), "a published tag must not move")
	testing.expect(t, krs.is_symbolic_link(krs.path_join(fixture.shared, "beta")))
	testing.expect_value(t, manifest_text(&fixture), manifest)
	testing.expect_value(t, packages_text(&fixture), packages)
}

@(test)
link_needs_a_src_directory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	write_file(t, krs.path_join(fixture.sources, "flat/flat.odin"), "package flat\n")

	result := run(&fixture, "", "link", "flat")
	expect_contains(&fixture, result.out, "sources/flat: it has no src/")
	expect_failure(&fixture, result, "no repository with a src/")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "flat")))

	// A package that was never installed can be linked and unlinked.
	write_file(t, krs.path_join(fixture.sources, "fresh/src/fresh.odin"), "package fresh\n")
	expect_ok(&fixture, run(&fixture, "", "link", "fresh"))
	testing.expect(t, krs.is_symbolic_link(krs.path_join(fixture.shared, "fresh")))
	expect_ok(&fixture, run(&fixture, "", "unlink", "fresh"))
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "fresh")))
}

@(test)
link_ls_lists_links_and_their_problems :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	empty := run(&fixture, "", "link", "ls")
	expect_ok(&fixture, empty)
	expect_contains(&fixture, empty.out, "no packages are linked")

	write_file(t, krs.path_join(fixture.sources, "fresh/src/fresh.odin"), "package fresh\n")
	write_file(t, krs.path_join(fixture.sources, "gone/src/gone.odin"), "package gone\n")
	expect_ok(&fixture, run(&fixture, "", "link", "fresh"))
	expect_ok(&fixture, run(&fixture, "", "link", "gone"))
	testing.expect(t, os.remove(krs.path_join(fixture.shared, "gone")) == nil)

	listed := run(&fixture, "", "link", "ls")
	expect_ok(&fixture, listed)
	expect_contains(&fixture, listed.out, "2 linked in")
	expect_contains(&fixture, listed.out, fmt.aprintf("  fresh -> %s\n", krs.path_join(fixture.sources, "fresh/src")))
	expect_contains(&fixture, listed.out, fmt.aprintf("  gone  -> %s (missing from shared/)", krs.path_join(fixture.sources, "gone/src")))
	expect_contains(&fixture, listed.out, "1 link(s) need attention")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "ls")))
}

// Links `name` from a fresh source repository.
link_fresh :: proc(fixture: ^Fixture, name: string) {
	write_file(fixture.t, krs.path_join(fixture.sources, fmt.aprintf("%s/src/%s.odin", name, name)), fmt.aprintf("package %s\n", name))
	expect_ok(fixture, run(fixture, "", "link", name))
}

@(test)
link_ls_reports_each_broken_state_with_a_remedy :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	for name in ([]string{"gone", "dir", "file", "moved", "lost"}) {
		link_fresh(&fixture, name)
	}

	testing.expect(t, os.remove(krs.path_join(fixture.shared, "gone")) == nil)

	testing.expect(t, os.remove(krs.path_join(fixture.shared, "dir")) == nil)
	testing.expect(t, os.make_directory(krs.path_join(fixture.shared, "dir")) == nil)

	testing.expect(t, os.remove(krs.path_join(fixture.shared, "file")) == nil)
	write_file(t, krs.path_join(fixture.shared, "file"), "x")

	testing.expect(t, os.remove(krs.path_join(fixture.shared, "moved")) == nil)
	testing.expect(t, os.symlink(fixture.sources, krs.path_join(fixture.shared, "moved")) == nil)

	testing.expect(t, os.remove_all(krs.path_join(fixture.sources, "lost")) == nil)

	listed := run(&fixture, "", "link", "ls")
	expect_ok(&fixture, listed)
	expect_contains(&fixture, listed.out, "(missing from shared/)")
	expect_contains(&fixture, listed.out, "krs link gone")
	expect_contains(&fixture, listed.out, "(replaced by a directory)")
	expect_contains(&fixture, listed.out, "krs unlink dir")
	expect_contains(&fixture, listed.out, "(replaced by a file)")
	expect_contains(&fixture, listed.out, "points to")
	expect_contains(&fixture, listed.out, "instead")
	expect_contains(&fixture, listed.out, "(the source no longer exists)")
	expect_contains(&fixture, listed.out, "5 link(s) need attention")
	testing.expect(t, !strings.contains(listed.out, "to relink one"))
}

@(test)
unlink_forgets_a_link_krs_did_not_make :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	link_fresh(&fixture, "dir")
	directory := krs.path_join(fixture.shared, "dir")
	testing.expect(t, os.remove(directory) == nil)
	testing.expect(t, os.make_directory(directory) == nil)

	result := run(&fixture, "", "unlink", "dir")
	expect_ok(&fixture, result)
	testing.expect(t, os.is_directory(directory))
	testing.expect(t, !strings.contains(manifest_text(&fixture), "\"dir\""))
	expect_contains(&fixture, result.out, "left")
	expect_contains(&fixture, result.out, "krs did not make it")

	expect_failure(&fixture, run(&fixture, "", "link", "dir"), "not managed by krs")
}

@(test)
unlink_and_link_recover_a_missing_link :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	link_fresh(&fixture, "gone")
	link := krs.path_join(fixture.shared, "gone")
	testing.expect(t, os.remove(link) == nil)

	expect_ok(&fixture, run(&fixture, "", "link", "gone"))
	testing.expect(t, krs.is_symbolic_link(link))

	testing.expect(t, os.remove(link) == nil)
	result := run(&fixture, "", "unlink", "gone")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "no longer recorded as linked")
	testing.expect(t, !strings.contains(manifest_text(&fixture), "\"gone\""))
}

@(test)
link_refuses_a_foreign_path_with_advice :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	link_fresh(&fixture, "file")
	path := krs.path_join(fixture.shared, "file")
	testing.expect(t, os.remove(path) == nil)
	write_file(t, path, "x")

	expect_failure(&fixture, run(&fixture, "", "link", "file"), "is not the link krs made")
	testing.expect_value(t, read_file(path), "x")
}

@(test)
unlink_restore_without_a_release_changes_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	link_fresh(&fixture, "fresh")
	manifest := manifest_text(&fixture)

	expect_failure(&fixture, run(&fixture, "", "unlink", "fresh", "--restore", "--yes"), "has no recorded release to restore")
	testing.expect(t, krs.is_symbolic_link(krs.path_join(fixture.shared, "fresh")))
	testing.expect_value(t, manifest_text(&fixture), manifest)
}

@(test)
unlink_removes_a_link_whose_source_is_gone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	link_fresh(&fixture, "lost")
	testing.expect(t, os.remove_all(krs.path_join(fixture.sources, "lost")) == nil)

	expect_ok(&fixture, run(&fixture, "", "unlink", "lost"))
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "lost")))
}

@(test)
unlink_restore_refuses_a_foreign_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_ok(&fixture, run(&fixture, "", "link", "beta"))
	directory := krs.path_join(fixture.shared, "beta")
	testing.expect(t, os.remove(directory) == nil)
	testing.expect(t, os.make_directory(directory) == nil)
	manifest := manifest_text(&fixture)

	expect_failure(&fixture, run(&fixture, "", "unlink", "beta", "--restore", "--yes"), "is not the link krs made")
	testing.expect(t, os.is_directory(directory))
	testing.expect_value(t, manifest_text(&fixture), manifest)
}

@(test)
status_reports_a_clean_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	result := run(&fixture, "", "status")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "installed v0.1.0")
	expect_contains(&fixture, result.out, "everything is in place")
}

@(test)
status_reports_each_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")
	write_file(t, krs.path_join(fixture.shared, "hand/hand.odin"), "package hand\n")
	link_fresh(&fixture, "fresh")
	link_fresh(&fixture, "gone")
	testing.expect(t, os.remove(krs.path_join(fixture.shared, "gone")) == nil)
	project_imports(&fixture, "beta", "absent")

	result := run(&fixture, "", "status")
	expect_failure(&fixture, result, "need attention")
	testing.expect(t, result.code == krs.EXIT_FAILED)
	expect_contains(&fixture, result.out, "altered v0.1.0")
	expect_contains(&fixture, result.out, "unmanaged")
	expect_contains(&fixture, result.out, "linked -> ")
	expect_contains(&fixture, result.out, "not imported here")
	expect_contains(&fixture, result.out, "link broken (missing from shared/)")
	expect_contains(&fixture, result.out, "not installed")
}

@(test)
status_reports_a_pin_that_differs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	repinned, _ := strings.replace_all(packages_text(&fixture), "\"v0.1.0\"", "\"v0.2.0\"")
	write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), repinned)
	result := run(&fixture, "", "status")
	expect_failure(&fixture, result, "need attention")
	expect_contains(&fixture, result.out, "pin v0.2.0")
}

@(test)
status_writes_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")
	link_fresh(&fixture, "fresh")

	manifest := manifest_text(&fixture)
	packages := packages_text(&fixture)
	run(&fixture, "", "status")
	testing.expect(t, manifest_text(&fixture) == manifest)
	testing.expect(t, packages_text(&fixture) == packages)
}

@(test)
status_rejects_write_options :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	expect_failure(&fixture, run(&fixture, "", "status", "--yes"), "status takes only --root")
}

@(test)
dependency_pins_with_invalid_fields_are_refused :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	Row :: struct { tag, commit, expected: string }
	for row in ([2]Row{
		{tag = "latest", commit = "", expected = "records beta with an invalid tag"},
		{tag = "v0.1.0", commit = "zz", expected = "records beta with an invalid commit"},
	}) {
		fixture := fixture_make(t)
		defer fixture_destroy(&fixture)

		library_release(&fixture, "beta", "v0.1.0")
		commit := row.commit
		if commit == "" {
			commit = git(t, krs.path_join(fixture.sources, "beta"), "rev-parse", "v0.1.0^{commit}")
		}
		pins := fmt.aprintf(
			"{{\"format\": 1, \"packages\": [{{\"name\": \"beta\", \"source\": \"local\", \"tag\": \"%s\", \"commit\": \"%s\", \"hash\": \"\"}}]}}\n",
			row.tag,
			commit,
		)
		repository_make(&fixture, "alpha")
		write_file(t, krs.path_join(fixture.sources, "alpha/.krs/packages.json"), pins)
		library_release(&fixture, "alpha", "v1.0.0", "beta")
		project_imports(&fixture, "alpha")

		expect_failure(&fixture, run(&fixture, "", "install", "--yes"), row.expected)
	}
}

@(test)
update_fetch_sees_new_github_releases :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	github_fixture_release(&fixture, "dvrd", "project-kessel", "v1.0.0")
	project_imports(&fixture, "kessel")
	write_file(t, krs.path_join(fixture.home, krs.CONFIG_PATH),
		`{"libs":{"kessel":{"source":"github","target":"dvrd/project-kessel"}}}`)
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	github_fixture_release(&fixture, "dvrd", "project-kessel", "v1.1.0")
	plain := run(&fixture, "", "update")
	expect_ok(&fixture, plain)
	testing.expect(t, !strings.contains(plain.out, "v1.1.0"))

	fetched := run(&fixture, "", "update", "--fetch")
	expect_ok(&fixture, fetched)
	expect_contains(&fixture, squeeze(fetched.out), "kessel v1.0.0 -> v1.1.0")
	expect_contains(&fixture, fetched.out, "Minor")
}

@(test)
update_flags_are_rejected_elsewhere :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	all := run(&fixture, "", "install", "--all")
	testing.expect_value(t, all.code, krs.EXIT_USAGE)
	expect_contains(&fixture, all.err, "--all was removed; use krs update -u -t semver")
	fetch := run(&fixture, "", "install", "--fetch")
	testing.expect_value(t, fetch.code, krs.EXIT_USAGE)
	expect_contains(&fixture, fetch.err, "--fetch only applies to update")
	update_all := run(&fixture, "", "update", "--all")
	testing.expect_value(t, update_all.code, krs.EXIT_USAGE)
	expect_contains(&fixture, update_all.err, "--all was removed; use krs update -u -t semver")
}

// Builds delta <- gamma <- beta <- alpha, each importing the next.
resolution_chain :: proc(fixture: ^Fixture) {
	library_release(fixture, "delta", "v0.1.0")
	library_release(fixture, "gamma", "v0.1.0", "delta")
	library_release(fixture, "beta", "v0.1.0", "gamma")
	library_release(fixture, "alpha", "v0.1.0", "beta")
	project_imports(fixture, "alpha")
}

// Resolves the project once and returns what the resolution touched.
resolution_counts :: proc(t: ^testing.T, fixture: ^Fixture) -> (counts: krs.Resolution_Counts, ok: bool) {
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
		fixture := fixture_make(t)
		defer fixture_destroy(&fixture)
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
		fixture := fixture_make(t)
		defer fixture_destroy(&fixture)
		resolution_chain(&fixture)
		expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

		counts, ok := resolution_counts(t, &fixture)
		if ok {
			testing.expectf(t, counts.installed_hashes == 4, "%v", counts)
			testing.expectf(t, counts.selections == 4, "%v", counts)
		}
	}
}

// Replaces the fixture's base directory, in its real and raw forms, with `<base>`.
normalized :: proc(fixture: ^Fixture, text: string) -> string {
	real, _ := os.get_absolute_path(fixture.base, context.allocator)
	result, _ := strings.replace_all(text, real, "<base>")
	result, _ = strings.replace_all(result, fixture.base, "<base>")
	return result
}

// Expects a command's complete output, paths normalized.
expect_output :: proc(fixture: ^Fixture, result: Result, out, err: string, loc := #caller_location) {
	testing.expect_value(fixture.t, normalized(fixture, result.out), out, loc = loc)
	testing.expect_value(fixture.t, normalized(fixture, result.err), err, loc = loc)
}

@(test)
resolver_output_is_stable :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	{
		// A compatible difference takes the higher release.
		fixture := fixture_make(t)
		defer fixture_destroy(&fixture)
		library_release(&fixture, "beta", "v0.4.0")
		project_imports(&fixture, "beta")
		expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
		library_release(&fixture, "beta", "v0.4.2")
		alpha_recording_beta(&fixture, "v1.0.0", "v0.4.2")
		project_imports(&fixture, "alpha", "beta")

		result := run(&fixture, "", "install", "--yes")
		expect_ok(&fixture, result)
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
		fixture := fixture_make(t)
		defer fixture_destroy(&fixture)
		library_release(&fixture, "beta", "v0.4.0")
		project_imports(&fixture, "beta")
		expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
		library_release(&fixture, "beta", "v0.5.0")
		alpha_recording_beta(&fixture, "v1.0.0", "v0.5.0")
		project_imports(&fixture, "alpha", "beta")

		result := run(&fixture, "", "install", "--yes")
		expect_failure(&fixture, result, "needs a decision")
		expect_output(
			&fixture,
			result,
			"beta: v0.4.0 and v0.5.0 (wanted by alpha v1.0.0) are not compatible\n",
			"krs: beta needs a decision between v0.4.0 and v0.5.0; run krs install in a terminal\n",
		)
	}

	{
		// Updating one package moves it past a dependant's record.
		fixture := fixture_make(t)
		defer fixture_destroy(&fixture)
		library_release(&fixture, "beta", "v0.4.0")
		alpha_recording_beta(&fixture, "v1.0.0", "v0.4.0")
		library_release(&fixture, "gamma", "v0.1.0")
		project_imports(&fixture, "alpha", "beta", "gamma")
		expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
		library_release(&fixture, "beta", "v0.4.1")
		library_release(&fixture, "beta", "v0.5.0")

		result := run(&fixture, "", "update", "beta", "-u", "--yes")
		expect_ok(&fixture, result)
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
		fixture := fixture_make(t)
		defer fixture_destroy(&fixture)
		library_release(&fixture, "beta", "v0.1.0")
		project_imports(&fixture, "beta")
		expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
		expect_ok(&fixture, run(&fixture, "", "link", "beta"))

		result := run(&fixture, "", "unlink", "beta", "--restore", "--yes")
		expect_ok(&fixture, result)
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

@(test)
pin_and_unpin_change_only_the_flag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	manifest := manifest_text(&fixture)

	pinned := run(&fixture, "", "pin", "beta")
	expect_ok(&fixture, pinned)
	expect_contains(&fixture, pinned.out, "beta is pinned at v0.1.0")
	expect_contains(&fixture, packages_text(&fixture), "\"pinned\": true")
	testing.expect_value(t, manifest_text(&fixture), manifest)

	again := run(&fixture, "", "pin", "beta")
	expect_ok(&fixture, again)
	expect_contains(&fixture, again.out, "beta is already pinned at v0.1.0")

	unpinned := run(&fixture, "", "unpin", "beta")
	expect_ok(&fixture, unpinned)
	expect_contains(&fixture, unpinned.out, "beta is no longer pinned")
	testing.expect(t, !strings.contains(packages_text(&fixture), "pinned"))
	testing.expect_value(t, manifest_text(&fixture), manifest)

	expect_failure(&fixture, run(&fixture, "", "pin", "gamma"), "is not recorded")
}

@(test)
unpinned_lockfiles_do_not_gain_a_pinned_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_contains(&fixture, packages_text(&fixture), "\"tag\": \"v0.1.0\"")
	testing.expect(t, !strings.contains(packages_text(&fixture), "pinned"))
}

@(test)
install_keeps_a_pin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	library_release(&fixture, "gamma", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_ok(&fixture, run(&fixture, "", "pin", "beta"))

	// A new import makes install rewrite the lockfile; the pin survives it.
	project_imports(&fixture, "beta", "gamma")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_contains(&fixture, packages_text(&fixture), "\"name\": \"gamma\"")
	expect_contains(&fixture, packages_text(&fixture), "\"pinned\": true")
}

@(test)
dependency_cannot_move_a_pinned_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.4.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_ok(&fixture, run(&fixture, "", "pin", "beta"))

	library_release(&fixture, "beta", "v0.4.2")
	alpha_recording_beta(&fixture, "v1.0.0", "v0.4.2")
	project_imports(&fixture, "alpha", "beta")

	result := run(&fixture, "", "install", "--yes")
	expect_ok(&fixture, result)
	expect_release(&fixture, "beta", "v0.4.0")
	expect_contains(&fixture, result.out, "was asked for explicitly")
	expect_contains(&fixture, packages_text(&fixture), "\"tag\": \"v0.4.0\"")
	expect_contains(&fixture, packages_text(&fixture), "\"pinned\": true")
}

@(test)
update_refuses_a_pinned_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_ok(&fixture, run(&fixture, "", "pin", "beta"))
	library_release(&fixture, "beta", "v0.2.0")

	expect_failure(&fixture, run(&fixture, "", "update", "beta", "-u", "--yes"), "is pinned")
	expect_release(&fixture, "beta", "v0.1.0")
}

@(test)
install_refuses_a_pin_the_root_has_moved :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixture_make(t)
	defer fixture_destroy(&a)

	library_release(&a, "beta", "v0.4.0")
	project_imports(&a, "beta")
	expect_ok(&a, run(&a, "", "install", "--yes"))
	expect_ok(&a, run(&a, "", "pin", "beta"))

	b := fixture_make(t)
	defer fixture_destroy(&b)
	b.root = a.root
	b.shared = a.shared
	b.home = a.home
	b.sources = a.sources
	library_release(&a, "beta", "v0.4.2")
	project_imports(&b, "beta")
	expect_ok(&b, run(&b, "", "install", "--yes"))
	expect_ok(&b, run(&b, "", "update", "beta@v0.4.2", "-u", "--yes"))
	expect_release(&a, "beta", "v0.4.2")

	recorded := packages_text(&a)
	expect_failure(&a, run(&a, "", "install", "--yes"), "is pinned at v0.4.0")
	testing.expect_value(t, packages_text(&a), recorded)
}

// alpha v1.0.0 imports beta v0.1.0; the project imports alpha and has
// installed both into the Odin root.
vendor_fixture_install :: proc(fixture: ^Fixture) {
	library_release(fixture, "beta", "v0.1.0")
	library_release(fixture, "alpha", "v1.0.0", "beta")
	project_imports(fixture, "alpha")
	expect_ok(fixture, run(fixture, "", "install", "--yes"))
}

vendor_text :: proc(fixture: ^Fixture) -> string {
	return read_file(krs.path_join(fixture.project, fmt.aprintf("%s/%s", krs.VENDOR_DIR, krs.MANIFEST_PATH)))
}

@(test)
vendor_copies_every_dependency :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	root_manifest := manifest_text(&fixture)

	result := run(&fixture, "", "vendor", "--yes")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "-collection:shared=vendor")
	testing.expect(t, os.exists(krs.path_join(fixture.project, "vendor/alpha/alpha.odin")))
	testing.expect(t, os.exists(krs.path_join(fixture.project, "vendor/beta/beta.odin")))
	testing.expect(t, os.exists(krs.path_join(fixture.project, "vendor/.krs/manifest.json")))
	expect_contains(&fixture, read_file(krs.path_join(fixture.project, "vendor/beta/beta.odin")), "RELEASE :: \"v0.1.0\"")
	expect_contains(&fixture, vendor_text(&fixture), "\"path\": \"\"")
	testing.expect(t, !strings.contains(vendor_text(&fixture), fixture.sources))
	testing.expect_value(t, manifest_text(&fixture), root_manifest)

	again := run(&fixture, "", "vendor", "--yes")
	expect_ok(&fixture, again)
	expect_contains(&fixture, again.out, "this project already uses")
}

@(test)
update_in_vendor_mode_reports_dependants :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.4.0")
	library_recording(&fixture, "alpha", "v1.0.0", "beta", "v0.4.0")
	library_release(&fixture, "beta", "v0.4.2")
	project_imports(&fixture, "alpha")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_ok(&fixture, run(&fixture, "", "vendor", "--yes"))

	result := run(&fixture, "", "update", "beta@v0.4.2", "-u", "--yes")
	expect_contains(&fixture, result.out, "alpha v1.0.0 recorded beta v0.4.0")
}

@(test)
vendor_files_are_not_project_imports :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	expect_ok(&fixture, run(&fixture, "", "vendor", "--yes"))

	project_imports(&fixture)
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	testing.expect(t, !strings.contains(packages_text(&fixture), "\"beta\""))
}

@(test)
vendor_refuses_an_existing_directory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	root_manifest := manifest_text(&fixture)
	write_file(t, krs.path_join(fixture.project, "vendor/bindings/lib.h"), "int f(void);\n")

	expect_failure(&fixture, run(&fixture, "", "vendor", "--yes"), "already exists")
	testing.expect_value(t, manifest_text(&fixture), root_manifest)
	testing.expect(t, !os.exists(krs.path_join(fixture.project, "vendor/.krs/manifest.json")))
}

@(test)
install_in_vendor_mode_writes_vendor :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	expect_ok(&fixture, run(&fixture, "", "vendor", "--yes"))

	library_release(&fixture, "gamma", "v0.1.0")
	project_imports(&fixture, "alpha", "gamma")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	testing.expect(t, os.exists(krs.path_join(fixture.project, "vendor/gamma/gamma.odin")))
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "gamma")))
	expect_contains(&fixture, packages_text(&fixture), "\"name\": \"gamma\"")
	expect_contains(&fixture, vendor_text(&fixture), "\"name\": \"gamma\"")
}

@(test)
links_are_refused_in_vendor_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	expect_ok(&fixture, run(&fixture, "", "vendor", "--yes"))

	write_file(t, krs.path_join(fixture.sources, "fresh/src/fresh.odin"), "package fresh\n")
	expect_failure(&fixture, run(&fixture, "", "link", "fresh"), "vendor mode")
	expect_failure(&fixture, run(&fixture, "", "unlink", "alpha"), "vendor mode")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "fresh")))
}

@(test)
status_reports_vendor_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	expect_ok(&fixture, run(&fixture, "", "vendor", "--yes"))

	result := run(&fixture, "", "status")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "vendor mode")
	expect_contains(&fixture, result.out, "installed v1.0.0")
}

// Three libraries' worth of upgrades: beta v0.4.0 -> v0.5.0 (major zero) and
// gamma v0.1.0 -> v0.1.1 (patch), listed in name order.
interactive_fixture :: proc(fixture: ^Fixture) {
	library_release(fixture, "beta", "v0.4.0")
	library_release(fixture, "gamma", "v0.1.0")
	project_imports(fixture, "beta", "gamma")
	expect_ok(fixture, run(fixture, "", "install", "--yes"))
	library_release(fixture, "beta", "v0.4.1")
	library_release(fixture, "beta", "v0.5.0")
	library_release(fixture, "gamma", "v0.1.1")
}

@(test)
update_interactive_takes_the_preselected_upgrades :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	interactive_fixture(&fixture)

	expect_ok(&fixture, run(&fixture, "\n", "update", "-i"))
	expect_release(&fixture, "gamma", "v0.1.1")
	expect_release(&fixture, "beta", "v0.4.0")
}

@(test)
update_interactive_needs_a_terminal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	interactive_fixture(&fixture)

	expect_failure(&fixture, run(&fixture, "", "update", "-i"), "choosing upgrades needs a terminal")
}

@(test)
update_interactive_flags_are_checked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	interactive_fixture(&fixture)

	misuse := run(&fixture, "", "install", "-i")
	testing.expect_value(t, misuse.code, krs.EXIT_USAGE)
	expect_contains(&fixture, misuse.err, "-i only applies to update")

	without := run(&fixture, "", "update", "--interactive-select=all")
	testing.expect_value(t, without.code, krs.EXIT_USAGE)
	expect_contains(&fixture, without.err, "needs -i")

	bogus := run(&fixture, "", "update", "-i", "--interactive-select=bogus")
	testing.expect_value(t, bogus.code, krs.EXIT_USAGE)
	expect_contains(&fixture, bogus.err, "not a valid")

	tagged := run(&fixture, "", "update", "-i", "beta@v0.5.0")
	testing.expect_value(t, tagged.code, krs.EXIT_USAGE)
	expect_contains(&fixture, tagged.err, "cannot be combined with name@tag")
}

@(test)
update_interactive_toggles_by_number :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	interactive_fixture(&fixture)

	expect_ok(&fixture, run(&fixture, "1\n\n", "update", "-i"))
	expect_release(&fixture, "beta", "v0.5.0")
	expect_release(&fixture, "gamma", "v0.1.1")
}

@(test)
update_interactive_select_all_and_none :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	interactive_fixture(&fixture)

	none := run(&fixture, "\n", "update", "-i", "--interactive-select=none")
	expect_ok(&fixture, none)
	expect_contains(&fixture, none.out, "no upgrades were chosen")
	expect_release(&fixture, "beta", "v0.4.0")
	expect_release(&fixture, "gamma", "v0.1.0")

	expect_ok(&fixture, run(&fixture, "\n", "update", "-i", "--interactive-select=all"))
	expect_release(&fixture, "beta", "v0.5.0")
	expect_release(&fixture, "gamma", "v0.1.1")
}

@(test)
update_interactive_quit_changes_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	interactive_fixture(&fixture)
	before := packages_text(&fixture)

	expect_failure(&fixture, run(&fixture, "q\n", "update", "-i"), "no upgrades were applied")
	testing.expect_value(t, packages_text(&fixture), before)
	expect_release(&fixture, "gamma", "v0.1.0")
}

@(test)
update_interactive_skips_pinned :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	interactive_fixture(&fixture)
	expect_ok(&fixture, run(&fixture, "", "pin", "gamma"))

	result := run(&fixture, "\n", "update", "-i", "--interactive-select=all")
	expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(squeeze(result.out), "gamma v0.1.0 -> v0.1.1"))
	expect_release(&fixture, "gamma", "v0.1.0")
}

@(test)
update_interactive_cancels_at_end_of_input :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	interactive_fixture(&fixture)
	before := packages_text(&fixture)

	// "1" toggles beta; input then ends without Enter.
	expect_failure(&fixture, run(&fixture, "1", "update", "-i"), "no upgrades were applied")
	testing.expect_value(t, packages_text(&fixture), before)
	expect_release(&fixture, "beta", "v0.4.0")
	expect_release(&fixture, "gamma", "v0.1.0")
}

@(test)
update_interactive_needs_the_list :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	interactive_fixture(&fixture)

	Row :: struct {
		arguments: []string,
		printed:   bool, // -s hides every message, usage errors included
	}
	table := []Row {
		{{"update", "-i", "-s"}, false},
		{{"update", "-i", "--loglevel", "error"}, true},
		{{"update", "-i", "--format", "lines"}, true},
	}
	for row in table {
		result := run(&fixture, "\n", ..row.arguments)
		testing.expectf(t, result.code == krs.EXIT_USAGE, "%v: exit %d, want %d\nerr: %s", row.arguments, result.code, krs.EXIT_USAGE, result.err)
		if row.printed {
			expect_contains(&fixture, result.err, "-i shows the upgrade list")
		}
	}
	expect_release(&fixture, "gamma", "v0.1.0")
}

COOLDOWN_OLD ::"2001-01-01 00:00:00 +0000"

@(test)
cooldown_falls_back_to_an_old_enough_release :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release_at(&fixture, "beta", "v1.0.0", COOLDOWN_OLD)
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release_at(&fixture, "beta", "v1.0.1", "2001-02-01 00:00:00 +0000")
	library_release(&fixture, "beta", "v1.1.0")

	result := run(&fixture, "", "update", "--cooldown", "7")
	expect_ok(&fixture, result)
	listing := squeeze(result.out)
	expect_contains(&fixture, listing, "beta v1.0.0 -> v1.0.1")
	testing.expect(t, !strings.contains(listing, "v1.1.0"))

	expect_ok(&fixture, run(&fixture, "", "update", "-u", "--cooldown", "7", "--yes"))
	expect_release(&fixture, "beta", "v1.0.1")
}

@(test)
cooldown_skips_a_package_with_only_young_releases :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release_at(&fixture, "beta", "v1.0.0", COOLDOWN_OLD)
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release(&fixture, "beta", "v1.0.1")

	result := run(&fixture, "", "update", "--cooldown", "7d")
	expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(squeeze(result.out), "-> v1.0.1"))

	held := run(&fixture, "", "update", "--cooldown", "7d", "--format", "cooldown")
	expect_ok(&fixture, held)
	expect_contains(&fixture, squeeze(held.out), "cooldown beta v1.0.0 skips v1.0.1")
}

@(test)
cooldown_periods_are_checked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	for period in ([]string{"--cooldown=0", "--cooldown=7x", "--cooldown=d", "--cooldown=-7"}) {
		result := run(&fixture, "", "update", period)
		testing.expectf(t, result.code == krs.EXIT_USAGE, "%s should be a usage error: %s", period, result.err)
		expect_contains(&fixture, result.err, "is not a cooldown period")
	}

	result := run(&fixture, "", "install", "--cooldown=7")
	testing.expect_value(t, result.code, krs.EXIT_USAGE)
	expect_contains(&fixture, result.err, "only applies to update")
}

@(test)
cooldown_without_it_offers_the_fresh_release :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release_at(&fixture, "beta", "v1.0.0", COOLDOWN_OLD)
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release_at(&fixture, "beta", "v1.0.1", "2001-02-01 00:00:00 +0000")
	library_release(&fixture, "beta", "v1.1.0")

	result := run(&fixture, "", "update")
	expect_ok(&fixture, result)
	expect_contains(&fixture, squeeze(result.out), "beta v1.0.0 -> v1.1.0")
}

@(test)
cooldown_never_downgrades :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release_at(&fixture, "beta", "v1.0.0", COOLDOWN_OLD)
	library_release(&fixture, "beta", "v1.1.0")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))

	result := run(&fixture, "", "update", "--cooldown", "7")
	expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(squeeze(result.out), "-> v1.0.0"))

	expect_ok(&fixture, run(&fixture, "", "update", "-u", "--cooldown", "7", "--yes"))
	expect_release(&fixture, "beta", "v1.1.0")
}

// beta v0.4.0 and gamma v0.1.0 are installed for a project importing both;
// then beta v0.5.0 and gamma v0.1.1 are released.
upgrades_fixture :: proc(fixture: ^Fixture) {
	library_release(fixture, "beta", "v0.4.0")
	library_release(fixture, "gamma", "v0.1.0")
	project_imports(fixture, "beta", "gamma")
	expect_ok(fixture, run(fixture, "", "install", "--yes"))
	library_release(fixture, "beta", "v0.5.0")
	library_release(fixture, "gamma", "v0.1.1")
}

// A test command that fails while beta v0.5.0 is installed in `shared`.
beta_breaks_on :: proc(shared: string) -> string {
	return fmt.aprintf(`! grep -q 'RELEASE :: "v0.5.0"' %s/beta/beta.odin`, shared)
}

@(test)
doctor_keeps_all_upgrades_when_tests_pass :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	upgrades_fixture(&fixture)

	result := run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-test=true")
	expect_ok(&fixture, result)
	expect_release(&fixture, "beta", "v0.5.0")
	expect_release(&fixture, "gamma", "v0.1.1")
	expect_contains(&fixture, result.out, "pass the tests")
}

@(test)
doctor_reverts_the_upgrade_that_breaks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	upgrades_fixture(&fixture)

	test := fmt.aprintf("--doctor-test=%s", beta_breaks_on(fixture.shared))
	result := run(&fixture, "", "update", "-u", "--doctor", "--yes", test)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	expect_release(&fixture, "beta", "v0.4.0")
	expect_release(&fixture, "gamma", "v0.1.1")
	packages := packages_text(&fixture)
	expect_contains(&fixture, packages, "\"v0.4.0\"")
	expect_contains(&fixture, packages, "\"v0.1.1\"")
	testing.expect(t, !strings.contains(packages, "v0.5.0"))
	expect_contains(&fixture, result.out, "breaks the tests")
	expect_contains(&fixture, result.out, "passes the tests")
}

@(test)
doctor_asks_for_consent_on_a_shared_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	upgrades_fixture(&fixture)
	packages := packages_text(&fixture)
	manifest := manifest_text(&fixture)

	result := run(&fixture, "", "update", "-u", "--doctor", "--doctor-test=true")
	expect_failure(&fixture, result, "confirmation is needed")
	expect_contains(&fixture, result.out, "every project on this Odin root sees them")
	testing.expect_value(t, packages_text(&fixture), packages)
	testing.expect_value(t, manifest_text(&fixture), manifest)
}

@(test)
doctor_runs_the_install_command :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	upgrades_fixture(&fixture)

	result := run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-install=touch doctor-installed",
		"--doctor-test=test -f doctor-installed")
	expect_ok(&fixture, result)
	testing.expect(t, os.exists(krs.path_join(fixture.project, "doctor-installed")))
	expect_release(&fixture, "beta", "v0.5.0")
}

@(test)
doctor_restores_the_lockfile_byte_for_byte :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	upgrades_fixture(&fixture)
	packages := packages_text(&fixture)
	manifest := manifest_text(&fixture)

	either := fmt.aprintf(
		"--doctor-test=! grep -q 'v0.5.0' %s/beta/beta.odin && ! grep -q 'v0.1.1' %s/gamma/gamma.odin",
		fixture.shared,
		fixture.shared,
	)
	result := run(&fixture, "", "update", "-u", "--doctor", "--yes", either)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	testing.expect_value(t, packages_text(&fixture), packages)
	testing.expect_value(t, manifest_text(&fixture), manifest)
	expect_release(&fixture, "beta", "v0.4.0")
	expect_release(&fixture, "gamma", "v0.1.0")

	// beta v0.5.0 records gamma v0.1.1, so upgrading beta alone moves gamma
	// too; the revert must move gamma back.
	moved := fixture_make(t)
	defer fixture_destroy(&moved)

	library_release(&moved, "beta", "v0.4.0")
	library_release(&moved, "gamma", "v0.1.0")
	project_imports(&moved, "beta", "gamma")
	expect_ok(&moved, run(&moved, "", "install", "--yes"))
	library_release(&moved, "gamma", "v0.1.1")
	library_recording(&moved, "beta", "v0.5.0", "gamma", "v0.1.1")
	moved_packages := packages_text(&moved)

	test := fmt.aprintf("--doctor-test=%s", beta_breaks_on(moved.shared))
	only_beta := run(&moved, "", "update", "-u", "--doctor", "--yes", test, "beta")
	testing.expectf(t, only_beta.code == 1, "exit %d\nout: %s\nerr: %s", only_beta.code, only_beta.out, only_beta.err)
	expect_contains(&moved, only_beta.out, "breaks the tests")
	// gamma is not a candidate: only beta's trial install moved it.
	expect_contains(&moved, only_beta.out, "v0.1.1")
	testing.expect_value(t, packages_text(&moved), moved_packages)
	testing.expect(t, !strings.contains(packages_text(&moved), "v0.1.1"))
	expect_release(&moved, "beta", "v0.4.0")
	expect_release(&moved, "gamma", "v0.1.0")
}

@(test)
doctor_byte_check_ignores_the_install_hook :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	upgrades_fixture(&fixture)

	// The hook changes the lockfile on every run, the baseline included; the
	// bytes a revert must match are the ones from before the baseline.
	test := fmt.aprintf("--doctor-test=%s", beta_breaks_on(fixture.shared))
	result := run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-install=printf ' ' >> .krs/packages.json", test)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	testing.expectf(t, !strings.contains(result.err, "byte for byte"), "unexpected byte check failure: %s", result.err)
	expect_contains(&fixture, result.out, "breaks the tests")
	expect_release(&fixture, "beta", "v0.4.0")
}

@(test)
doctor_refuses_a_lockfile_behind_the_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixture_make(t)
	defer fixture_destroy(&a)

	library_release(&a, "beta", "v0.1.0")
	project_imports(&a, "beta")
	expect_ok(&a, run(&a, "", "install", "--yes"))

	// Project B, on the same Odin root, moves beta to a compatible release.
	b := fixture_make(t)
	defer fixture_destroy(&b)
	b.root = a.root
	b.shared = a.shared
	b.home = a.home
	b.sources = a.sources
	project_imports(&b, "beta")
	expect_ok(&b, run(&b, "", "install", "--yes"))
	library_release(&a, "beta", "v0.1.1")
	expect_ok(&b, run(&b, "", "update", "-u", "--yes"))
	expect_release(&a, "beta", "v0.1.1")

	packages := packages_text(&a)
	manifest := manifest_text(&a)
	result := run(&a, "", "update", "-u", "--doctor", "--yes", "--doctor-test=true")
	expect_failure(&a, result, "run krs install first")
	testing.expect_value(t, packages_text(&a), packages)
	testing.expect_value(t, manifest_text(&a), manifest)
}

@(test)
doctor_reports_a_failed_restore :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	upgrades_fixture(&fixture)

	// While beta v0.5.0 is installed, the tests fail and take beta's
	// repository away, so the revert cannot find beta v0.4.0.
	beta := krs.path_join(fixture.sources, "beta")
	gone := krs.path_join(fixture.sources, "beta.gone")
	test := fmt.aprintf(
		"--doctor-test=if grep -q 'RELEASE :: \"v0.5.0\"' %s/beta/beta.odin; then mv %s %s; exit 1; fi",
		fixture.shared,
		beta,
		gone,
	)
	result := run(&fixture, "", "update", "-u", "--doctor", "--yes", test)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	expect_contains(&fixture, result.err, "could not restore the previous versions")
	expect_contains(&fixture, result.err, "git checkout -- .krs/packages.json")

	testing.expect(t, os.rename(gone, beta) == nil)
	expect_ok(&fixture, run(&fixture, "", "install", "--frozen"))
}

@(test)
doctor_tests_vendor_in_vendor_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	upgrades_fixture(&fixture)
	expect_ok(&fixture, run(&fixture, "", "vendor", "--yes"))
	manifest := manifest_text(&fixture)

	test := fmt.aprintf("--doctor-test=%s", beta_breaks_on(krs.path_join(fixture.project, krs.VENDOR_DIR)))
	result := run(&fixture, "", "update", "-u", "--doctor", "--yes", test)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	testing.expect(t, !strings.contains(result.out, "every project on this Odin root sees them"))
	testing.expect_value(t, manifest_text(&fixture), manifest)
	expect_contains(&fixture, read_file(krs.path_join(fixture.project, "vendor/beta/beta.odin")), "RELEASE :: \"v0.4.0\"")
	expect_contains(&fixture, read_file(krs.path_join(fixture.project, "vendor/gamma/gamma.odin")), "RELEASE :: \"v0.1.1\"")
	expect_release(&fixture, "beta", "v0.4.0")
}

@(test)
doctor_needs_a_passing_baseline :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	upgrades_fixture(&fixture)
	packages := packages_text(&fixture)
	manifest := manifest_text(&fixture)

	result := run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-test=false")
	expect_failure(&fixture, result, "needs a passing baseline")
	testing.expect_value(t, packages_text(&fixture), packages)
	testing.expect_value(t, manifest_text(&fixture), manifest)
	expect_release(&fixture, "beta", "v0.4.0")
}

@(test)
doctor_times_out_and_reverts :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	release_beta_upgrade(&fixture)
	before := packages_text(&fixture)

	// `exec` makes the killed process the sleep itself, so nothing is left running.
	test := fmt.tprintf("--doctor-test=if grep -q 'RELEASE :: \"v0.2.0\"' %s/beta/beta.odin; then exec sleep 30; fi", fixture.shared)
	result := run(&fixture, "", "update", "-u", "--doctor", "--yes", "--doctor-timeout=1s", test)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	expect_contains(&fixture, result.out, "timed out")
	expect_release(&fixture, "beta", "v0.1.0")
	testing.expect_value(t, packages_text(&fixture), before)
}

@(test)
doctor_flags_are_checked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	upgrades_fixture(&fixture)

	Misuse :: struct {
		arguments: []string,
		message:   string,
	}
	cases := []Misuse {
		{{"update", "--doctor"}, "--doctor needs -u"},
		{{"install", "--doctor"}, "--doctor only applies to update"},
		{{"update", "-u", "--doctor-test=true"}, "--doctor-test needs --doctor"},
		{{"update", "-u", "--doctor-install", "true"}, "--doctor-install needs --doctor"},
		{{"update", "-u", "--doctor", "--install=never"}, "--install=never cannot be combined"},
		{{"update", "-u", "--doctor", "--pin"}, "--doctor and --pin cannot be combined"},
		{{"update", "-u", "--doctor", "-g"}, "--doctor and --global cannot be combined"},
		{{"update", "-u", "--doctor", "-j"}, "JSON output cannot be combined"},
		{{"update", "-u", "-d", "--json-upgraded"}, "JSON output cannot be combined"},
		{{"update", "-i", "--doctor"}, "--doctor and -i cannot be combined"},
		{{"update", "-u", "--doctor", "--doctor-timeout=0s"}, "0s is not a timeout"},
		{{"update", "-u", "--doctor", "--doctor-timeout=5"}, "5 is not a timeout"},
		{{"update", "-u", "--doctor-timeout=1m"}, "--doctor-timeout needs --doctor"},
	}
	for misuse in cases {
		result := run(&fixture, "", ..misuse.arguments)
		testing.expectf(t, result.code == krs.EXIT_USAGE, "%v: exit %d, err: %s", misuse.arguments, result.code, result.err)
		expect_contains(&fixture, result.err, misuse.message)
	}
	expect_release(&fixture, "beta", "v0.4.0")
}

@(test)
nested_project_imports_stay_out_of_the_parent :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	library_release(&fixture, "gamma", "v1.0.0")
	project_imports(&fixture, "beta")
	write_file(t, krs.path_join(fixture.project, "tools/gen/main.odin"), "package main\n\nimport \"shared:gamma\"\n")
	write_file(t, krs.path_join(fixture.project, "tools/gen/.krs/packages.json"), "{\"format\": 1, \"packages\": []}\n")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_contains(&fixture, packages_text(&fixture), "\"beta\"")
	testing.expect(t, !strings.contains(packages_text(&fixture), "\"gamma\""))
}

// beta v1.0.0 in the project, gamma v1.0.0 in tools/gen, both installed, then
// both libraries released again at v1.1.0.
deep_fixture :: proc(fixture: ^Fixture) -> (gen: string) {
	library_release(fixture, "beta", "v1.0.0")
	library_release(fixture, "gamma", "v1.0.0")
	project_imports(fixture, "beta")
	gen = krs.path_join(fixture.project, "tools/gen")
	write_file(fixture.t, krs.path_join(gen, "main.odin"), "package main\n\nimport \"shared:gamma\"\n")
	write_file(fixture.t, krs.path_join(gen, krs.PACKAGES_PATH), "{\"format\": 1, \"packages\": []}\n")
	expect_ok(fixture, run_in(fixture, gen, "", "install", "--yes"))
	expect_ok(fixture, run(fixture, "", "install", "--yes"))
	library_release(fixture, "beta", "v1.1.0")
	library_release(fixture, "gamma", "v1.1.0")

	return gen
}

@(test)
update_deep_lists_every_project :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	deep_fixture(&fixture)
	result := run(&fixture, "", "update", "--deep")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "project .")
	expect_contains(&fixture, result.out, "project tools/gen")
	expect_contains(&fixture, result.out, "beta")
	expect_contains(&fixture, result.out, "gamma")
	expect_contains(&fixture, result.out, "v1.1.0")
}

@(test)
update_deep_resolves_a_relative_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	deep_fixture(&fixture)
	// fixture.project is <base>/app and fixture.root is <base>/root.
	result := run(&fixture, "", "update", "--deep", "--root=../root")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "project .")
	expect_contains(&fixture, result.out, "project tools/gen")
	expect_contains(&fixture, result.out, "beta")
	expect_contains(&fixture, result.out, "gamma")
}

@(test)
update_deep_upgrades_each_lockfile :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	gen := deep_fixture(&fixture)
	expect_ok(&fixture, run(&fixture, "", "update", "--deep", "-u", "--yes"))
	parent := packages_text(&fixture)
	child := read_file(krs.path_join(gen, krs.PACKAGES_PATH))
	expect_contains(&fixture, parent, "\"beta\"")
	expect_contains(&fixture, parent, "v1.1.0")
	expect_contains(&fixture, child, "\"gamma\"")
	expect_contains(&fixture, child, "v1.1.0")
	testing.expect(t, !strings.contains(parent, "\"gamma\""))
	testing.expect(t, !strings.contains(child, "\"beta\""))
}

@(test)
update_package_file_selects_projects :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	deep_fixture(&fixture)
	result := run(&fixture, "", "update", "--package-file=tools/*")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "project tools/gen")
	testing.expect(t, !strings.contains(result.out, "project ."))

	none := run(&fixture, "", "update", "--package-file=nothing")
	expect_failure(&fixture, none, "no project matches")
}

@(test)
update_deep_skips_vendor_and_hidden :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	deep_fixture(&fixture)
	write_file(t, krs.path_join(fixture.project, "vendor/x/.krs/packages.json"), "{\"format\": 1, \"packages\": []}\n")
	write_file(t, krs.path_join(fixture.project, ".cache/y/.krs/packages.json"), "{\"format\": 1, \"packages\": []}\n")
	result := run(&fixture, "", "update", "--deep")
	expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(result.out, "project vendor"))
	testing.expect(t, !strings.contains(result.out, "project .cache"))
}

@(test)
update_deep_flags_are_checked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	Misuse :: struct {
		arguments: []string,
		message:   string,
	}
	misuses := []Misuse {
		{{"install", "--deep"}, "only applies to update"},
		{{"update", "--deep", "-j"}, "cannot be combined with JSON output"},
		{{"update", "--deep", "-g"}, "--deep and --global cannot be combined"},
	}
	for misuse in misuses {
		result := run(&fixture, "", ..misuse.arguments)
		testing.expectf(t, result.code == krs.EXIT_USAGE, "%v: exit %d, err: %s", misuse.arguments, result.code, result.err)
		expect_contains(&fixture, result.err, misuse.message)
	}
}

@(test)
update_deep_skips_names_a_project_does_not_use :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	gen := deep_fixture(&fixture)
	other := krs.path_join(gen, "../other")
	write_file(t, krs.path_join(other, "main.odin"), "package main\n\nimport \"shared:gamma\"\n")
	write_file(t, krs.path_join(other, krs.PACKAGES_PATH), "{\"format\": 1, \"packages\": []}\n")
	before := read_file(krs.path_join(other, krs.PACKAGES_PATH))
	result := run(&fixture, "", "update", "-u", "beta", "--deep", "--yes")
	expect_ok(&fixture, result)
	expect_contains(&fixture, packages_text(&fixture), "v1.1.0")
	testing.expect_value(t, read_file(krs.path_join(other, krs.PACKAGES_PATH)), before)
	expect_contains(&fixture, result.out, "none of the named packages are used here")
}

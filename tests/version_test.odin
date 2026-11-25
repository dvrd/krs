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
	expect_contains(&fixture, listing.out, "beta v0.4.0 -> v0.5.0 (breaking)")
	expect_contains(&fixture, listing.out, "gamma v0.1.0 -> v0.1.1 (compatible)")
	testing.expect(t, !strings.contains(listing.out, "alpha"))
	expect_release(&fixture, "beta", "v0.4.0")

	expect_failure(&fixture, run(&fixture, "", "update", "beta"), "confirmation is needed")
	expect_release(&fixture, "beta", "v0.4.0")

	result := run(&fixture, "", "update", "beta", "--yes")
	expect_ok(&fixture, result)
	expect_contains(&fixture, result.out, "beta v0.4.0 -> v0.5.0 (breaking)")
	expect_contains(&fixture, result.out, "alpha v1.0.0 recorded beta v0.4.0")
	expect_release(&fixture, "beta", "v0.5.0")
	expect_release(&fixture, "gamma", "v0.1.0")
	expect_contains(&fixture, packages_text(&fixture), "\"tag\": \"v0.5.0\"")
	expect_contains(&fixture, manifest_text(&fixture), "\"tag\": \"v0.5.0\"")

	// A named tag may be an older one.
	expect_ok(&fixture, run(&fixture, "", "update", "beta@v0.4.1", "--yes"))
	expect_release(&fixture, "beta", "v0.4.1")
	expect_contains(&fixture, packages_text(&fixture), "\"tag\": \"v0.4.1\"")

	expect_failure(&fixture, run(&fixture, "", "update", "beta@v7.0.0", "--yes"), "no usable repository")
	expect_failure(&fixture, run(&fixture, "", "update", "beta@latest", "--yes"), "not a vMAJOR.MINOR.PATCH tag")
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
	expect_failure(&fixture, run(&other, "", "update", "beta", "--yes"), "is not used by this project")
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
	expect_ok(&a, run(&a, "", "update", "beta", "--yes"))
	expect_release(&a, "beta", "v0.2.0")

	result := run(&b, "", "update", "beta", "--yes")
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

	result := run(&fixture, "", "update", "beta@v0.1.0", "--yes")
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
	expect_ok(&second, run(&second, "", "update", "beta", "--yes"))
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
	expect_failure(&fixture, run(&fixture, "", "update", "alpha", "--yes"), "alpha is linked")

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
	expect_contains(&fixture, fetched.out, "kessel v1.0.0 -> v1.1.0 (compatible)")
}

@(test)
update_all_takes_compatible_tags_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.4.0")
	library_release(&fixture, "gamma", "v0.1.0")
	project_imports(&fixture, "beta", "gamma")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release(&fixture, "beta", "v0.4.1")
	library_release(&fixture, "beta", "v0.5.0")
	library_release(&fixture, "gamma", "v0.1.1")

	expect_failure(&fixture, run(&fixture, "", "update", "--all"), "confirmation is needed")
	expect_release(&fixture, "beta", "v0.4.0")

	result := run(&fixture, "", "update", "--all", "--yes")
	expect_ok(&fixture, result)
	expect_release(&fixture, "beta", "v0.4.1")
	expect_release(&fixture, "gamma", "v0.1.1")
	expect_contains(&fixture, result.out, "beta v0.5.0 is available")
}

@(test)
update_flags_are_rejected_elsewhere :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	all := run(&fixture, "", "install", "--all")
	testing.expect_value(t, all.code, krs.EXIT_USAGE)
	expect_contains(&fixture, all.err, "--all only applies to update without a package")
	fetch := run(&fixture, "", "install", "--fetch")
	testing.expect_value(t, fetch.code, krs.EXIT_USAGE)
	expect_contains(&fixture, fetch.err, "--fetch only applies to update")
	package_all := run(&fixture, "", "update", "beta", "--all")
	testing.expect_value(t, package_all.code, krs.EXIT_USAGE)
	expect_contains(&fixture, package_all.err, "--all only applies to update without a package")
}

@(test)
update_all_moves_a_stale_project_pin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	other := fixture
	other.project = krs.path_join(fixture.base, "other-app")
	os.make_directory_all(other.project)

	library_release(&fixture, "beta", "v0.4.0")
	project_imports(&fixture, "beta")
	project_imports(&other, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_ok(&other, run(&other, "", "install", "--yes"))
	library_release(&fixture, "beta", "v0.4.1")
	expect_ok(&fixture, run(&fixture, "", "update", "beta", "--yes"))

	expect_ok(&other, run(&other, "", "update", "--all", "--yes"))
	expect_contains(&other, read_file(krs.path_join(other.project, krs.PACKAGES_PATH)), "\"tag\": \"v0.4.1\"")
}

@(test)
update_all_changes_nothing_when_a_package_cannot_be_checked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v0.4.0")
	library_release(&fixture, "gamma", "v0.1.0")
	project_imports(&fixture, "beta", "gamma")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	library_release(&fixture, "gamma", "v0.1.1")
	os.remove_all(krs.path_join(fixture.sources, "beta"))

	expect_failure(&fixture, run(&fixture, "", "update", "--all", "--yes"), "nothing was changed")
	expect_release(&fixture, "gamma", "v0.1.0")
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
			testing.expectf(t, counts.repository_opens > 0, "%v", counts)
			testing.expectf(t, counts.selections > 0, "%v", counts)
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
			testing.expectf(t, counts.installed_hashes > 0, "%v", counts)
			testing.expectf(t, counts.selections > 0, "%v", counts)
		}
	}
}

package tests

import "core:fmt"
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
link_and_unlink :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	alpha_release(&fixture)
	project_imports(&fixture, "alpha")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	recorded := packages_text(&fixture)
	installed_hash, _ := krs.hash_directory(krs.path_join(fixture.shared, "alpha"))

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
	restored_hash, _ := krs.hash_directory(link)
	testing.expect_value(t, restored_hash, installed_hash)
	testing.expect(t, !strings.contains(manifest_text(&fixture), "linked"))
	testing.expect_value(t, packages_text(&fixture), recorded)
	expect_contains(&fixture, read_file(krs.path_join(source, "alpha.odin")), "working copy")

	expect_failure(&fixture, run(&fixture, "", "unlink", "alpha"), "is not linked")
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

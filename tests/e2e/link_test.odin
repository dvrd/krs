package e2e

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
unmanaged_directory_is_left_alone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	// A repository of the same name exists, and must not be installed over it.
	fixtures.library_release(&fixture, "beta", "v0.1.0")
	unmanaged := krs.path_join(fixture.shared, "beta/beta.odin")
	fixtures.write_file(t, unmanaged, "package beta\n\nHAND_WRITTEN :: true\n")
	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/.git/HEAD"), "ref: refs/heads/main\n")
	before, before_ok := krs.hash_directory(krs.path_join(fixture.shared, "beta"))
	testing.expect(t, before_ok, "the unmanaged directory can be hashed")
	fixtures.project_imports(&fixture, "beta")

	result := fixtures.run(&fixture, "", "install", "--yes")
	fixtures.expect_ok(&fixture, result)

	after, after_ok := krs.hash_directory(krs.path_join(fixture.shared, "beta"))
	testing.expect(t, after_ok, "the unmanaged directory can still be hashed")
	testing.expect_value(t, after, before)
	testing.expect_value(t, fixtures.read_file(unmanaged), "package beta\n\nHAND_WRITTEN :: true\n")
	testing.expect_value(t, fixtures.read_file(krs.path_join(fixture.shared, "beta/.git/HEAD")), "ref: refs/heads/main\n")
	fixtures.expect_contains(&fixture, fixtures.read_file(unmanaged), "HAND_WRITTEN")
	testing.expect(t, os.exists(krs.path_join(fixture.shared, "beta/.git/HEAD")))
	testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "beta"))
	testing.expect(t, !strings.contains(fixtures.manifest_text(&fixture), "beta"))

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "link", "beta"), "not managed by krs")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "beta", "-u", "--yes"), "was not installed by krs")
}

@(test)
config_ignores_retired_keys :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	text := fmt.aprintf("{{\"format\": 1, \"source_directories\": [\"%s\"], \"trusted_owners\": [\"someone\"]}}\n", fixture.sources)
	fixtures.write_file(t, krs.path_join(fixture.home, krs.CONFIG_PATH), text)

	result := fixtures.run(&fixture, "", "link", "ls")
	fixtures.expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(result.out, "no settings"), result.out)
}

@(test)
link_and_unlink :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.alpha_release(&fixture)
	fixtures.project_imports(&fixture, "alpha")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	recorded := fixtures.packages_text(&fixture)
	installed_hash, installed_ok := krs.hash_directory(krs.path_join(fixture.shared, "alpha"))
	testing.expect(t, installed_ok, "the installed package can be hashed")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "link", "alpha"))
	link := krs.path_join(fixture.shared, "alpha")
	source := krs.path_join(fixture.sources, "alpha/src")
	testing.expect(t, krs.is_symbolic_link(link))
	fixtures.expect_contains(&fixture, fixtures.manifest_text(&fixture), fmt.aprintf("\"linked\": \"%s\"", source))
	testing.expect_value(t, fixtures.packages_text(&fixture), recorded)

	linked_again := fixtures.run(&fixture, "", "link", "alpha")
	fixtures.expect_ok(&fixture, linked_again)
	fixtures.expect_contains(&fixture, linked_again.out, fmt.aprintf("alpha is already linked to %s", source))
	testing.expect(t, !strings.contains(linked_again.out, "every project on this Odin root"))
	testing.expect(t, krs.is_symbolic_link(link))

	// An edit in the repository is what the compiler now sees.
	fixtures.write_file(t, krs.path_join(source, "alpha.odin"), "package alpha\n\nRELEASE :: \"working copy\"\n")
	fixtures.expect_release(&fixture, "alpha", "working copy")

	listed := fixtures.run(&fixture, "", "install")
	fixtures.expect_ok(&fixture, listed)
	fixtures.expect_contains(&fixture, listed.out, fmt.aprintf("linked: alpha -> %s", source))
	testing.expect(t, krs.is_symbolic_link(link), "install leaves a linked package alone")
	testing.expect_value(t, fixtures.packages_text(&fixture), recorded)
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--frozen"), "alpha is linked")
	// update checks a linked package too; with no newer tag nothing moves.
	updated := fixtures.run(&fixture, "", "update", "alpha", "-u", "--yes")
	fixtures.expect_ok(&fixture, updated)
	fixtures.expect_contains(&fixture, updated.out, "at its target version")
	testing.expect(t, krs.is_symbolic_link(link), "update leaves a linked package linked")
	testing.expect_value(t, fixtures.packages_text(&fixture), recorded)

	misplaced := fixtures.run(&fixture, "", "install", "--restore")
	testing.expect_value(t, misplaced.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, misplaced.err, "--restore only applies to unlink")

	// By default unlink only removes the link, even when a release is recorded.
	removed := fixtures.run(&fixture, "", "unlink", "alpha")
	fixtures.expect_ok(&fixture, removed)
	fixtures.expect_contains(&fixture, removed.out, "alpha is unlinked and removed")
	testing.expect(t, !krs.path_present(link))
	testing.expect(t, !strings.contains(fixtures.manifest_text(&fixture), "\"alpha\""))
	testing.expect_value(t, fixtures.packages_text(&fixture), recorded)

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "link", "alpha"))
	linked_manifest := fixtures.manifest_text(&fixture)
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "unlink", "alpha", "--restore"), "confirmation is needed")
	testing.expect(t, krs.is_symbolic_link(link))
	testing.expect_value(t, fixtures.manifest_text(&fixture), linked_manifest)

	unlinked := fixtures.run(&fixture, "", "unlink", "alpha", "--restore", "--yes")
	fixtures.expect_ok(&fixture, unlinked)
	fixtures.expect_contains(&fixture, unlinked.out, "src/notes/design.md is not named by any Odin file")
	fixtures.expect_contains(&fixture, unlinked.out, "src/assets/unused.js is not named by any Odin file")
	testing.expect(t, !krs.is_symbolic_link(link))
	fixtures.expect_release(&fixture, "alpha", "v0.1.0")
	restored_hash, restored_ok := krs.hash_directory(link)
	testing.expect(t, restored_ok, "the restored package can be hashed")
	testing.expect_value(t, restored_hash, installed_hash)
	testing.expect(t, !strings.contains(fixtures.manifest_text(&fixture), "linked"))
	testing.expect_value(t, fixtures.packages_text(&fixture), recorded)
	fixtures.expect_contains(&fixture, fixtures.read_file(krs.path_join(source, "alpha.odin")), "working copy")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "unlink", "alpha"), "is not linked")
}

@(test)
link_asks_before_replacing_changed_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	link := krs.path_join(fixture.shared, "beta")
	edited := krs.path_join(fixture.shared, "beta/beta.odin")
	fixtures.write_file(t, edited, "package beta\n\nEDITED :: true\n")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "link", "beta"), "confirmation is needed")
	testing.expect(t, !krs.is_symbolic_link(link))
	fixtures.expect_contains(&fixture, fixtures.read_file(edited), "EDITED")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "n\n", "link", "beta"), "nothing was changed")
	testing.expect(t, !krs.is_symbolic_link(link))
	fixtures.expect_contains(&fixture, fixtures.read_file(edited), "EDITED")

	linked := fixtures.run(&fixture, "y\n", "link", "beta")
	fixtures.expect_ok(&fixture, linked)
	fixtures.expect_contains(&fixture, linked.out, "linking deletes them")
	testing.expect(t, krs.is_symbolic_link(link))
}

@(test)
link_replaces_an_unchanged_install_without_asking :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/.DS_Store"), "metadata")

	linked := fixtures.run(&fixture, "", "link", "beta")
	fixtures.expect_ok(&fixture, linked)
	testing.expect(t, !strings.contains(linked.out, "linking deletes them"))
}

@(test)
link_with_yes_replaces_changed_files_and_warns :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")

	linked := fixtures.run(&fixture, "", "link", "beta", "--yes")
	fixtures.expect_ok(&fixture, linked)
	fixtures.expect_contains(&fixture, linked.out, "linking deletes them")
	testing.expect(t, krs.is_symbolic_link(krs.path_join(fixture.shared, "beta")))
}

@(test)
unlink_refuses_a_moved_tag_and_preserves_the_link :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "link", "beta"))
	manifest := fixtures.manifest_text(&fixture)
	packages := fixtures.packages_text(&fixture)

	new_commit := fixtures.library_release(&fixture, "beta", "v1.0.1")
	fixtures.git(t, krs.path_join(fixture.sources, "beta"), "tag", "--force", "v1.0.0", new_commit)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "unlink", "beta", "--restore", "--yes"), "a published tag must not move")
	testing.expect(t, krs.is_symbolic_link(krs.path_join(fixture.shared, "beta")))
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)
	testing.expect_value(t, fixtures.packages_text(&fixture), packages)
}

@(test)
link_needs_a_src_directory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.write_file(t, krs.path_join(fixture.sources, "flat/flat.odin"), "package flat\n")

	result := fixtures.run(&fixture, "", "link", "flat")
	fixtures.expect_contains(&fixture, result.out, "sources/flat: it has no src/")
	fixtures.expect_failure(&fixture, result, "no repository with a src/")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "flat")))

	// A package that was never installed can be linked and unlinked.
	fixtures.write_file(t, krs.path_join(fixture.sources, "fresh/src/fresh.odin"), "package fresh\n")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "link", "fresh"))
	testing.expect(t, krs.is_symbolic_link(krs.path_join(fixture.shared, "fresh")))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "unlink", "fresh"))
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "fresh")))
}

@(test)
link_ls_lists_links_and_their_problems :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	empty := fixtures.run(&fixture, "", "link", "ls")
	fixtures.expect_ok(&fixture, empty)
	fixtures.expect_contains(&fixture, empty.out, "no packages are linked")

	fixtures.write_file(t, krs.path_join(fixture.sources, "fresh/src/fresh.odin"), "package fresh\n")
	fixtures.write_file(t, krs.path_join(fixture.sources, "gone/src/gone.odin"), "package gone\n")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "link", "fresh"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "link", "gone"))
	testing.expect(t, os.remove(krs.path_join(fixture.shared, "gone")) == nil)

	listed := fixtures.run(&fixture, "", "link", "ls")
	fixtures.expect_ok(&fixture, listed)
	fixtures.expect_contains(&fixture, listed.out, "2 linked in")
	fixtures.expect_contains(&fixture, listed.out, fmt.aprintf("  fresh -> %s\n", krs.path_join(fixture.sources, "fresh/src")))
	fixtures.expect_contains(&fixture, listed.out, fmt.aprintf("  gone  -> %s (missing from shared/)", krs.path_join(fixture.sources, "gone/src")))
	fixtures.expect_contains(&fixture, listed.out, "1 link(s) need attention")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "ls")))
}

@(test)
link_ls_reports_each_broken_state_with_a_remedy :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	for name in ([]string{"gone", "dir", "file", "moved", "lost"}) {
		fixtures.link_fresh(&fixture, name)
	}

	testing.expect(t, os.remove(krs.path_join(fixture.shared, "gone")) == nil)

	testing.expect(t, os.remove(krs.path_join(fixture.shared, "dir")) == nil)
	testing.expect(t, os.make_directory(krs.path_join(fixture.shared, "dir")) == nil)

	testing.expect(t, os.remove(krs.path_join(fixture.shared, "file")) == nil)
	fixtures.write_file(t, krs.path_join(fixture.shared, "file"), "x")

	testing.expect(t, os.remove(krs.path_join(fixture.shared, "moved")) == nil)
	testing.expect(t, os.symlink(fixture.sources, krs.path_join(fixture.shared, "moved")) == nil)

	testing.expect(t, os.remove_all(krs.path_join(fixture.sources, "lost")) == nil)

	listed := fixtures.run(&fixture, "", "link", "ls")
	fixtures.expect_ok(&fixture, listed)
	fixtures.expect_contains(&fixture, listed.out, "(missing from shared/)")
	fixtures.expect_contains(&fixture, listed.out, "krs link gone")
	fixtures.expect_contains(&fixture, listed.out, "(replaced by a directory)")
	fixtures.expect_contains(&fixture, listed.out, "krs unlink dir")
	fixtures.expect_contains(&fixture, listed.out, "(replaced by a file)")
	fixtures.expect_contains(&fixture, listed.out, "points to")
	fixtures.expect_contains(&fixture, listed.out, "instead")
	fixtures.expect_contains(&fixture, listed.out, "(the source no longer exists)")
	fixtures.expect_contains(&fixture, listed.out, "5 link(s) need attention")
	testing.expect(t, !strings.contains(listed.out, "to relink one"))
}

@(test)
unlink_forgets_a_link_krs_did_not_make :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.link_fresh(&fixture, "dir")
	directory := krs.path_join(fixture.shared, "dir")
	testing.expect(t, os.remove(directory) == nil)
	testing.expect(t, os.make_directory(directory) == nil)

	result := fixtures.run(&fixture, "", "unlink", "dir")
	fixtures.expect_ok(&fixture, result)
	testing.expect(t, os.is_directory(directory))
	testing.expect(t, !strings.contains(fixtures.manifest_text(&fixture), "\"dir\""))
	fixtures.expect_contains(&fixture, result.out, "left")
	fixtures.expect_contains(&fixture, result.out, "krs did not make it")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "link", "dir"), "not managed by krs")
}

@(test)
unlink_and_link_recover_a_missing_link :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.link_fresh(&fixture, "gone")
	link := krs.path_join(fixture.shared, "gone")
	testing.expect(t, os.remove(link) == nil)

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "link", "gone"))
	testing.expect(t, krs.is_symbolic_link(link))

	testing.expect(t, os.remove(link) == nil)
	result := fixtures.run(&fixture, "", "unlink", "gone")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "no longer recorded as linked")
	testing.expect(t, !strings.contains(fixtures.manifest_text(&fixture), "\"gone\""))
}

@(test)
link_refuses_a_foreign_path_with_advice :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.link_fresh(&fixture, "file")
	path := krs.path_join(fixture.shared, "file")
	testing.expect(t, os.remove(path) == nil)
	fixtures.write_file(t, path, "x")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "link", "file"), "is not the link krs made")
	testing.expect_value(t, fixtures.read_file(path), "x")
}

@(test)
unlink_restore_without_a_release_changes_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.link_fresh(&fixture, "fresh")
	manifest := fixtures.manifest_text(&fixture)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "unlink", "fresh", "--restore", "--yes"), "has no recorded release to restore")
	testing.expect(t, krs.is_symbolic_link(krs.path_join(fixture.shared, "fresh")))
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)
}

@(test)
unlink_removes_a_link_whose_source_is_gone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.link_fresh(&fixture, "lost")
	testing.expect(t, os.remove_all(krs.path_join(fixture.sources, "lost")) == nil)

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "unlink", "lost"))
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "lost")))
}

@(test)
unlink_restore_refuses_a_foreign_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "link", "beta"))
	directory := krs.path_join(fixture.shared, "beta")
	testing.expect(t, os.remove(directory) == nil)
	testing.expect(t, os.make_directory(directory) == nil)
	manifest := fixtures.manifest_text(&fixture)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "unlink", "beta", "--restore", "--yes"), "is not the link krs made")
	testing.expect(t, os.is_directory(directory))
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)
}

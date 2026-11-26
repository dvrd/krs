package e2e

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

// beta v1.0.0 installed, then linked to its checkout, which then gets v1.1.0.
// Returns the commit of v1.1.0.
linked_beta_upgrade :: proc(fixture: ^fixtures.Fixture) -> string {
	fixtures.library_release(fixture, "beta", "v1.0.0")
	fixtures.project_imports(fixture, "beta")
	fixtures.expect_ok(fixture, fixtures.run(fixture, "", "install", "--yes"))
	fixtures.expect_ok(fixture, fixtures.run(fixture, "", "link", "beta"))
	return fixtures.library_release(fixture, "beta", "v1.1.0")
}

// The link is still in shared/, and the root's manifest still records it.
expect_beta_linked :: proc(fixture: ^fixtures.Fixture, loc := #caller_location) {
	link := krs.path_join(fixture.shared, "beta")
	source := krs.path_join(fixture.sources, "beta/src")
	testing.expect(fixture.t, krs.is_symbolic_link(link), "shared/beta is still a link", loc = loc)
	target, err := os.read_link(link, context.temp_allocator)
	testing.expect(fixture.t, err == nil, "the link can be read", loc = loc)
	testing.expect_value(fixture.t, target, source, loc = loc)
	fixtures.expect_contains(fixture, fixtures.manifest_text(fixture), fmt.aprintf("\"linked\": \"%s\"", source), loc)
}

// The project records v1.1.0 at its commit, with a content hash.
expect_beta_recorded :: proc(fixture: ^fixtures.Fixture, commit: string, loc := #caller_location) {
	record := fixtures.record_of(fixture, "beta", loc)
	testing.expect_value(fixture.t, record.tag, "v1.1.0", loc = loc)
	testing.expect_value(fixture.t, record.commit, commit, loc = loc)
	testing.expect(fixture.t, record.hash != "", "the record has a hash", loc = loc)
}

@(test)
update_lists_a_linked_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	linked_beta_upgrade(&fixture)
	recorded := fixtures.packages_text(&fixture)

	result := fixtures.run(&fixture, "", "update")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, fixtures.squeeze(result.out), "beta v1.0.0 -> v1.1.0 (linked)")
	testing.expect(t, !strings.contains(result.out, "at its highest tag"), result.out)
	testing.expect_value(t, fixtures.packages_text(&fixture), recorded)
	expect_beta_linked(&fixture)
}

@(test)
update_upgrade_keeps_the_link :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	commit := linked_beta_upgrade(&fixture)
	manifest := fixtures.manifest_text(&fixture)

	result := fixtures.run(&fixture, "", "update", "-u", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "beta v1.0.0 -> v1.1.0")
	fixtures.expect_contains(&fixture, result.out, "stays linked")
	expect_beta_recorded(&fixture, commit)
	expect_beta_linked(&fixture)
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)

	again := fixtures.run(&fixture, "", "update")
	fixtures.expect_ok(&fixture, again)
	fixtures.expect_contains(&fixture, again.out, "at its highest tag")

	// The recorded release is what --restore installs, and its hash matches.
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "unlink", "beta", "--restore", "--yes"))
	testing.expect(t, !krs.is_symbolic_link(krs.path_join(fixture.shared, "beta")))
	fixtures.expect_release(&fixture, "beta", "v1.1.0")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen"))
}

@(test)
update_upgrade_names_a_linked_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	commit := linked_beta_upgrade(&fixture)

	result := fixtures.run(&fixture, "", "update", "-u", "beta", "--yes")
	fixtures.expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(result.out, "unlink beta first"), result.out)
	fixtures.expect_contains(&fixture, result.out, "stays linked")
	expect_beta_recorded(&fixture, commit)
	expect_beta_linked(&fixture)
}

@(test)
update_upgrade_records_a_linked_package_without_installing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	commit := linked_beta_upgrade(&fixture)

	result := fixtures.run(&fixture, "", "update", "-u", "--install", "never", "--yes")
	fixtures.expect_ok(&fixture, result)
	expect_beta_recorded(&fixture, commit)
	expect_beta_linked(&fixture)
}

@(test)
update_upgrade_moves_linked_and_installed_packages_together :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	fixtures.library_release(&fixture, "gamma", "v0.1.0")
	commit := linked_beta_upgrade(&fixture)
	fixtures.project_imports(&fixture, "beta", "gamma")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.library_release(&fixture, "gamma", "v0.1.1")

	result := fixtures.run(&fixture, "", "update", "-u", "--yes")
	fixtures.expect_ok(&fixture, result)
	expect_beta_recorded(&fixture, commit)
	expect_beta_linked(&fixture)
	testing.expect_value(t, fixtures.record_of(&fixture, "gamma").tag, "v0.1.1")
	fixtures.expect_release(&fixture, "gamma", "v0.1.1")
}

@(test)
update_holds_a_pinned_linked_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	linked_beta_upgrade(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "beta"))
	recorded := fixtures.packages_text(&fixture)

	listed := fixtures.run(&fixture, "", "update")
	fixtures.expect_ok(&fixture, listed)
	fixtures.expect_contains(&fixture, listed.out, "(pinned; v1.1.0 available)")

	upgraded := fixtures.run(&fixture, "", "update", "-u", "--yes")
	fixtures.expect_ok(&fixture, upgraded)
	testing.expect_value(t, fixtures.packages_text(&fixture), recorded)
	expect_beta_linked(&fixture)
}

@(test)
update_global_reports_linked_packages :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	linked_beta_upgrade(&fixture)

	result := fixtures.run(&fixture, "", "update", "-g")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "linked, not checked: beta")
	testing.expect(t, !strings.contains(result.out, "v1.1.0"), result.out)
}

package e2e

import "core:os"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
update_vendor_not_created_when_nothing_is_chosen :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&a)
	b := fixtures.pinned_divergence(&a)
	defer fixtures.fixture_destroy(&b)

	fixtures.library_release(&a, "gamma", "v0.1.1")
	// Every upgrade starts selected; `a` deselects them all, then Enter.
	result := fixtures.run(&a, "a\n\n", "update", "-i", "--interactive-select", "all")
	fixtures.expect_ok(&a, result)
	fixtures.expect_contains(&a, result.out, "no upgrades were chosen")
	testing.expect(t, !os.exists(krs.path_join(a.project, krs.VENDOR_DIR)))
}

@(test)
update_interactive_takes_the_preselected_upgrades :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.interactive_fixture(&fixture)

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "\n", "update", "-i"))
	fixtures.expect_release(&fixture, "gamma", "v0.1.1")
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
}

@(test)
update_interactive_needs_a_terminal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.interactive_fixture(&fixture)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "-i"), "choosing upgrades needs a terminal")
}

@(test)
update_interactive_flags_are_checked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.interactive_fixture(&fixture)

	misuse := fixtures.run(&fixture, "", "install", "-i")
	testing.expect_value(t, misuse.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, misuse.err, "-i only applies to update")

	without := fixtures.run(&fixture, "", "update", "--interactive-select=all")
	testing.expect_value(t, without.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, without.err, "needs -i")

	bogus := fixtures.run(&fixture, "", "update", "-i", "--interactive-select=bogus")
	testing.expect_value(t, bogus.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, bogus.err, "not a valid")

	tagged := fixtures.run(&fixture, "", "update", "-i", "beta@v0.5.0")
	testing.expect_value(t, tagged.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, tagged.err, "cannot be combined with name@tag")
}

@(test)
update_interactive_toggles_by_number :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.interactive_fixture(&fixture)

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "1\n\n", "update", "-i"))
	fixtures.expect_release(&fixture, "beta", "v0.5.0")
	fixtures.expect_release(&fixture, "gamma", "v0.1.1")
}

@(test)
update_interactive_select_all_and_none :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.interactive_fixture(&fixture)

	none := fixtures.run(&fixture, "\n", "update", "-i", "--interactive-select=none")
	fixtures.expect_ok(&fixture, none)
	fixtures.expect_contains(&fixture, none.out, "no upgrades were chosen")
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
	fixtures.expect_release(&fixture, "gamma", "v0.1.0")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "\n", "update", "-i", "--interactive-select=all"))
	fixtures.expect_release(&fixture, "beta", "v0.5.0")
	fixtures.expect_release(&fixture, "gamma", "v0.1.1")
}

@(test)
update_interactive_quit_changes_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.interactive_fixture(&fixture)
	before := fixtures.packages_text(&fixture)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "q\n", "update", "-i"), "no upgrades were applied")
	testing.expect_value(t, fixtures.packages_text(&fixture), before)
	fixtures.expect_release(&fixture, "gamma", "v0.1.0")
}

@(test)
update_interactive_cancels_at_end_of_input :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.interactive_fixture(&fixture)
	before := fixtures.packages_text(&fixture)

	// "1" toggles beta; input then ends without Enter.
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "1", "update", "-i"), "no upgrades were applied")
	testing.expect_value(t, fixtures.packages_text(&fixture), before)
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
	fixtures.expect_release(&fixture, "gamma", "v0.1.0")
}

@(test)
update_interactive_needs_the_list :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.interactive_fixture(&fixture)

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
		result := fixtures.run(&fixture, "\n", ..row.arguments)
		testing.expectf(t, result.code == krs.EXIT_USAGE, "%v: exit %d, want %d\nerr: %s", row.arguments, result.code, krs.EXIT_USAGE, result.err)
		if row.printed {
			fixtures.expect_contains(&fixture, result.err, "-i shows the upgrade list")
		}
	}
	fixtures.expect_release(&fixture, "gamma", "v0.1.0")
}

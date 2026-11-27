package e2e

import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
status_reports_a_clean_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	result := fixtures.run(&fixture, "", "status")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "checked 1 package(s) of this project")
	fixtures.expect_contains(&fixture, result.out, "everything is in place")
	testing.expect(t, !strings.contains(result.out, "installed v0.1.0"), "a package in place is not listed")

	global := fixtures.run(&fixture, "", "status", "-g")
	fixtures.expect_ok(&fixture, global)
	fixtures.expect_contains(&fixture, global.out, "installed v0.1.0")
}

@(test)
status_reports_each_state :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")
	fixtures.write_file(t, krs.path_join(fixture.shared, "hand/hand.odin"), "package hand\n")
	fixtures.link_fresh(&fixture, "fresh")
	fixtures.link_fresh(&fixture, "gone")
	testing.expect(t, os.remove(krs.path_join(fixture.shared, "gone")) == nil)
	fixtures.project_imports(&fixture, "beta", "absent")

	// The project's own problems only: not the root's other links and
	// directories.
	project := fixtures.run(&fixture, "", "status")
	fixtures.expect_failure(&fixture, project, "2 package(s) need attention")
	fixtures.expect_contains(&fixture, project.out, "altered v0.1.0")
	fixtures.expect_contains(&fixture, project.out, "absent not installed")
	for absent in ([]string{"fresh", "gone", "hand"}) {
		testing.expectf(t, !strings.contains(project.out, absent), "%s is not this project's: %s", absent, project.out)
	}

	result := fixtures.run(&fixture, "", "status", "-g")
	fixtures.expect_failure(&fixture, result, "need attention")
	testing.expect(t, result.code == krs.EXIT_FAILED)
	fixtures.expect_contains(&fixture, result.out, "altered v0.1.0")
	fixtures.expect_contains(&fixture, result.out, "unmanaged")
	fixtures.expect_contains(&fixture, result.out, "linked -> ")
	fixtures.expect_contains(&fixture, result.out, "not imported here")
	fixtures.expect_contains(&fixture, result.out, "link broken (missing from shared/)")
	fixtures.expect_contains(&fixture, result.out, "not installed")
}

@(test)
status_reports_a_pin_that_differs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	repinned, _ := strings.replace_all(fixtures.packages_text(&fixture), "\"v0.1.0\"", "\"v0.2.0\"")
	fixtures.write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), repinned)
	result := fixtures.run(&fixture, "", "status")
	fixtures.expect_failure(&fixture, result, "need attention")
	fixtures.expect_contains(&fixture, result.out, "pin v0.2.0")
}

@(test)
status_writes_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n\nEDITED :: true\n")
	fixtures.link_fresh(&fixture, "fresh")

	manifest := fixtures.manifest_text(&fixture)
	packages := fixtures.packages_text(&fixture)
	fixtures.run(&fixture, "", "status")
	testing.expect(t, fixtures.manifest_text(&fixture) == manifest)
	testing.expect(t, fixtures.packages_text(&fixture) == packages)
}

@(test)
status_rejects_write_options :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "status", "--yes"), "status takes only --root and -g")
}

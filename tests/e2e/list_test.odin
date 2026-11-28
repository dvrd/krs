package e2e

import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
ls_lists_the_projects_packages_and_versions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	empty := fixtures.run(&fixture, "", "ls")
	fixtures.expect_ok(&fixture, empty)
	fixtures.expect_contains(&fixture, empty.out, "imports no shared: packages")

	fixtures.library_release(&fixture, "gamma", "v0.3.0")
	fixtures.library_release(&fixture, "beta", "v1.0.0", "gamma")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "beta"))

	listed := fixtures.run(&fixture, "", "ls")
	fixtures.expect_ok(&fixture, listed)
	out := fixtures.squeeze(listed.out)
	fixtures.expect_contains(&fixture, out, "2 package(s) in .krs/packages.json")
	fixtures.expect_contains(&fixture, out, "beta v1.0.0 imported installed pinned")
	fixtures.expect_contains(&fixture, out, "gamma v0.3.0 via beta installed")

	// A new import is listed before it is recorded, and ls changes nothing.
	fixtures.project_imports(&fixture, "beta", "delta")
	before := fixtures.packages_text(&fixture)
	changed := fixtures.run(&fixture, "", "ls")
	fixtures.expect_ok(&fixture, changed)
	fixtures.expect_contains(&fixture, fixtures.squeeze(changed.out), "delta imported not installed")
	fixtures.expect_contains(&fixture, changed.out, "run krs install")
	testing.expect_value(t, fixtures.packages_text(&fixture), before)
	testing.expect(t, !strings.contains(changed.err, "krs:"), changed.err)

	// An import another project installed is held by the root, not missing.
	fixtures.library_release(&fixture, "epsilon", "v0.5.0")
	other := krs.path_join(fixture.base, "other")
	fixtures.write_file(t, krs.path_join(other, "main.odin"), "package main\n\nimport \"shared:epsilon\"\n\nmain :: proc() {\n\t_ = epsilon\n}\n")
	fixtures.expect_ok(&fixture, fixtures.run_in(&fixture, other, "", "install", "--yes"))
	fixtures.project_imports(&fixture, "beta", "epsilon")
	held := fixtures.run(&fixture, "", "ls")
	fixtures.expect_ok(&fixture, held)
	fixtures.expect_contains(&fixture, fixtures.squeeze(held.out), "epsilon imported not recorded; root has v0.5.0")
}

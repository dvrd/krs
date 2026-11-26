package e2e

import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

// beta and gamma v1.0.0, both imported by the project and installed in the
// Odin root.
uninstall_fixture_install :: proc(fixture: ^fixtures.Fixture) {
	fixtures.library_release(fixture, "beta", "v1.0.0")
	fixtures.library_release(fixture, "gamma", "v1.0.0")
	fixtures.project_imports(fixture, "beta", "gamma")
	fixtures.expect_ok(fixture, fixtures.run(fixture, "", "install", "--yes"))
}

@(test)
uninstall_removes_a_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	uninstall_fixture_install(&fixture)
	fixtures.project_imports(&fixture, "gamma")

	result := fixtures.run(&fixture, "", "uninstall", "beta", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "beta v1.0.0")
	fixtures.expect_contains(&fixture, result.out, "may still need these packages")
	fixtures.expect_contains(&fixture, result.out, "removed beta from")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "beta")))
	testing.expect(t, !strings.contains(fixtures.manifest_text(&fixture), "\"beta\""))
	testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "\"beta\""))
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"gamma\"")
	testing.expect(t, os.exists(krs.path_join(fixture.shared, "gamma/gamma.odin")))
	testing.expect(t, !strings.contains(result.out, "still imported"))

	// The project is consistent again: install changes nothing.
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--frozen"))
}

@(test)
uninstall_warns_when_still_imported :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	uninstall_fixture_install(&fixture)

	result := fixtures.run(&fixture, "", "uninstall", "beta", "--yes")
	fixtures.expect_ok(&fixture, result)
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "beta")))
	testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "\"beta\""))
	fixtures.expect_contains(&fixture, result.out, "beta is still imported by: main.odin")
	warning := strings.index(result.out, "still imported by")
	install := strings.index(result.out, "krs install will install it again")
	testing.expectf(t, warning >= 0 && install > warning, "the note follows the warning: %s", result.out)

	// What the warning promises: the next install brings beta back.
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v1.0.0")
}

@(test)
uninstall_asks_first :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	uninstall_fixture_install(&fixture)
	packages := fixtures.packages_text(&fixture)
	manifest := fixtures.manifest_text(&fixture)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "uninstall", "beta"), "confirmation is needed")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "n\n", "uninstall", "beta"), "nothing was changed")
	testing.expect_value(t, fixtures.packages_text(&fixture), packages)
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)
	fixtures.expect_release(&fixture, "beta", "v1.0.0")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "y\n", "uninstall", "beta"))
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "beta")))
	testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "\"beta\""))

	bare := fixtures.run(&fixture, "", "uninstall")
	fixtures.expect_failure(&fixture, bare, "name the packages to uninstall")
}

@(test)
uninstall_refuses_unknown_and_linked_packages :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	uninstall_fixture_install(&fixture)
	packages := fixtures.packages_text(&fixture)
	manifest := fixtures.manifest_text(&fixture)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "uninstall", "nope", "--yes"), "nope is not recorded in .krs/packages.json")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "uninstall", "../x", "--yes"), "is not a usable package name")
	testing.expect_value(t, fixtures.packages_text(&fixture), packages)
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)

	fixtures.link_fresh(&fixture, "gamma")
	linked := fixtures.run(&fixture, "", "uninstall", "gamma", "--yes")
	fixtures.expect_failure(&fixture, linked, "run krs unlink gamma first")
	testing.expect(t, krs.is_symbolic_link(krs.path_join(fixture.shared, "gamma")))
	testing.expect_value(t, fixtures.packages_text(&fixture), packages)
}

@(test)
uninstall_in_vendor_mode_leaves_the_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	uninstall_fixture_install(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "vendor", "--yes"))
	root_manifest := fixtures.manifest_text(&fixture)
	vendor := krs.path_join(fixture.project, krs.VENDOR_DIR)

	result := fixtures.run(&fixture, "", "uninstall", "beta", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "/app/vendor:\n  beta v1.0.0\n")
	testing.expect(t, !strings.contains(result.out, "other projects using the Odin root"))
	testing.expect(t, !krs.path_present(krs.path_join(vendor, "beta")))
	testing.expect(t, !strings.contains(fixtures.read_file(krs.path_join(vendor, krs.MANIFEST_PATH)), "\"beta\""))
	testing.expect(t, os.exists(krs.path_join(vendor, "gamma/gamma.odin")))
	fixtures.expect_release(&fixture, "beta", "v1.0.0")
	testing.expect_value(t, fixtures.manifest_text(&fixture), root_manifest)
	testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "\"beta\""))
}

@(test)
uninstall_of_several_names_is_all_or_nothing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	uninstall_fixture_install(&fixture)
	packages := fixtures.packages_text(&fixture)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "uninstall", "beta", "nope", "--yes"), "nope is not recorded")
	fixtures.expect_release(&fixture, "beta", "v1.0.0")
	testing.expect_value(t, fixtures.packages_text(&fixture), packages)

	// Both named, one of them twice: each is removed once.
	fixtures.project_imports(&fixture)
	result := fixtures.run(&fixture, "", "uninstall", "beta", "gamma", "beta", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "removed beta, gamma from")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "beta")))
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "gamma")))
	testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "\"name\""))
}

@(test)
uninstall_warns_when_a_dependency_imports_it :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.library_release(&fixture, "alpha", "v1.0.0", "beta")
	fixtures.project_imports(&fixture, "alpha")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))

	result := fixtures.run(&fixture, "", "uninstall", "beta", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "beta is still imported by: alpha")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "beta")))
	fixtures.expect_release(&fixture, "alpha", "v1.0.0")
	testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "\"beta\""))
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"alpha\"")
}

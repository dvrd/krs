package e2e

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

// alpha v1.0.0 imports beta v0.1.0; the project imports alpha and has
// installed both into the Odin root.
vendor_fixture_install :: proc(fixture: ^fixtures.Fixture) {
	fixtures.library_release(fixture, "beta", "v0.1.0")
	fixtures.library_release(fixture, "alpha", "v1.0.0", "beta")
	fixtures.project_imports(fixture, "alpha")
	fixtures.expect_ok(fixture, fixtures.run(fixture, "", "install", "--yes"))
}

vendor_text :: proc(fixture: ^fixtures.Fixture) -> string {
	return fixtures.read_file(krs.path_join(fixture.project, fmt.aprintf("%s/%s", krs.VENDOR_DIR, krs.MANIFEST_PATH)))
}

@(test)
vendor_copies_every_dependency :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	root_manifest := fixtures.manifest_text(&fixture)

	result := fixtures.run(&fixture, "", "vendor", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "-collection:shared=vendor")
	testing.expect(t, os.exists(krs.path_join(fixture.project, "vendor/alpha/alpha.odin")))
	testing.expect(t, os.exists(krs.path_join(fixture.project, "vendor/beta/beta.odin")))
	testing.expect(t, os.exists(krs.path_join(fixture.project, "vendor/.krs/manifest.json")))
	fixtures.expect_contains(&fixture, fixtures.read_file(krs.path_join(fixture.project, "vendor/beta/beta.odin")), "RELEASE :: \"v0.1.0\"")
	fixtures.expect_contains(&fixture, vendor_text(&fixture), "\"path\": \"\"")
	testing.expect(t, !strings.contains(vendor_text(&fixture), fixture.sources))
	testing.expect_value(t, fixtures.manifest_text(&fixture), root_manifest)

	again := fixtures.run(&fixture, "", "vendor", "--yes")
	fixtures.expect_ok(&fixture, again)
	fixtures.expect_contains(&fixture, again.out, "this project already uses")
}

@(test)
update_in_vendor_mode_reports_dependants :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.4.0")
	fixtures.library_recording(&fixture, "alpha", "v1.0.0", "beta", "v0.4.0")
	fixtures.library_release(&fixture, "beta", "v0.4.2")
	fixtures.project_imports(&fixture, "alpha")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "vendor", "--yes"))

	result := fixtures.run(&fixture, "", "update", "beta@v0.4.2", "-u", "--yes")
	fixtures.expect_contains(&fixture, result.out, "alpha v1.0.0 recorded beta v0.4.0")
}

@(test)
vendor_files_are_not_project_imports :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "vendor", "--yes"))

	fixtures.project_imports(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "\"beta\""))
}

@(test)
vendor_refuses_an_existing_directory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	root_manifest := fixtures.manifest_text(&fixture)
	fixtures.write_file(t, krs.path_join(fixture.project, "vendor/bindings/lib.h"), "int f(void);\n")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "vendor", "--yes"), "already exists")
	testing.expect_value(t, fixtures.manifest_text(&fixture), root_manifest)
	testing.expect(t, !os.exists(krs.path_join(fixture.project, "vendor/.krs/manifest.json")))
}

@(test)
install_in_vendor_mode_writes_vendor :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "vendor", "--yes"))

	fixtures.library_release(&fixture, "gamma", "v0.1.0")
	fixtures.project_imports(&fixture, "alpha", "gamma")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	testing.expect(t, os.exists(krs.path_join(fixture.project, "vendor/gamma/gamma.odin")))
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "gamma")))
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"name\": \"gamma\"")
	fixtures.expect_contains(&fixture, vendor_text(&fixture), "\"name\": \"gamma\"")
}

@(test)
links_are_refused_in_vendor_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "vendor", "--yes"))

	fixtures.write_file(t, krs.path_join(fixture.sources, "fresh/src/fresh.odin"), "package fresh\n")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "link", "fresh"), "vendor mode")
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "unlink", "alpha"), "vendor mode")
	testing.expect(t, !krs.path_present(krs.path_join(fixture.shared, "fresh")))
}

@(test)
status_reports_vendor_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	vendor_fixture_install(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "vendor", "--yes"))

	result := fixtures.run(&fixture, "", "status")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "vendor mode")
	fixtures.expect_contains(&fixture, result.out, "everything is in place")
	fixtures.expect_contains(&fixture, fixtures.run(&fixture, "", "status", "-g").out, "installed v1.0.0")
}

@(test)
doctor_tests_vendor_in_vendor_mode :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.upgrades_fixture(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "vendor", "--yes"))
	manifest := fixtures.manifest_text(&fixture)

	test := fmt.aprintf("--doctor-test=%s", fixtures.beta_breaks_on(krs.path_join(fixture.project, krs.VENDOR_DIR)))
	result := fixtures.run(&fixture, "", "update", "-u", "--doctor", "--yes", test)
	testing.expectf(t, result.code == 1, "exit %d\nout: %s\nerr: %s", result.code, result.out, result.err)
	testing.expect(t, !strings.contains(result.out, "every project on this Odin root sees them"))
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)
	fixtures.expect_contains(&fixture, fixtures.read_file(krs.path_join(fixture.project, "vendor/beta/beta.odin")), "RELEASE :: \"v0.4.0\"")
	fixtures.expect_contains(&fixture, fixtures.read_file(krs.path_join(fixture.project, "vendor/gamma/gamma.odin")), "RELEASE :: \"v0.1.1\"")
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
}

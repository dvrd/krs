package unit

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

Vendor_Fixture :: struct {
	fixture: fixtures.Fixture,
	out:     strings.Builder,
	err:     strings.Builder,
	env:     krs.Env,
}

vendor_fixture_make :: proc(t: ^testing.T, vendor: ^Vendor_Fixture) {
	vendor.fixture = fixtures.fixture_make(t)
	vendor.out = strings.builder_make()
	vendor.err = strings.builder_make()
	vendor.env = krs.Env {
		project      = vendor.fixture.project,
		home         = vendor.fixture.home,
		default_root = vendor.fixture.root,
		out          = strings.to_writer(&vendor.out),
		err          = strings.to_writer(&vendor.err),
	}
}

// The project imports beta and records beta v0.1.0 in .krs/packages.json,
// with an empty tag when `tag` is "". Nothing is installed in the Odin root.
vendor_record_beta :: proc(t: ^testing.T, vendor: ^Vendor_Fixture, tag: string) {
	fixture := &vendor.fixture
	commit := fixtures.library_release(fixture, "beta", "v0.1.0")
	fixtures.project_imports(fixture, "beta")
	packages := fmt.tprintf(
		"{{\"format\": 1, \"packages\": [{{\"name\": \"beta\", \"source\": \"local\", \"tag\": \"%s\", \"commit\": \"%s\", \"hash\": \"\"}}]}}\n",
		tag,
		commit,
	)
	fixtures.write_file(t, krs.path_join(fixture.project, krs.PACKAGES_PATH), packages)
}

// Opens the project's state, runs vendor_enter on it and closes it.
vendor_enter_once :: proc(t: ^testing.T, vendor: ^Vendor_Fixture) -> (entered: bool, shared: string, vendored: bool) {
	state, opened := krs.state_open(&vendor.env, {yes = true})
	if !testing.expectf(t, opened, "state_open failed: %s", strings.to_string(vendor.err)) {
		return
	}
	defer krs.state_close(state)

	entered = krs.vendor_enter(state)
	return entered, state.shared, state.vendored
}

@(test)
vendor_enter_copies_the_recorded_release_into_vendor :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	vendor: Vendor_Fixture
	vendor_fixture_make(t, &vendor)
	defer fixtures.fixture_destroy(&vendor.fixture)

	vendor_record_beta(t, &vendor, "v0.1.0")
	fixtures.library_release(&vendor.fixture, "beta", "v0.2.0")
	entered, shared, vendored := vendor_enter_once(t, &vendor)
	testing.expectf(t, entered, "vendor_enter failed: %s", strings.to_string(vendor.err))

	directory := krs.path_join(vendor.fixture.project, krs.VENDOR_DIR)
	testing.expect(t, vendored)
	testing.expect(t, strings.has_suffix(shared, "/" + krs.VENDOR_DIR), shared)
	beta := fixtures.read_file(krs.path_join(directory, "beta/beta.odin"))
	testing.expect(t, strings.contains(beta, "RELEASE :: \"v0.1.0\""), beta)
	testing.expect(t, os.exists(krs.path_join(directory, krs.MANIFEST_PATH)))
	testing.expect_value(t, fixtures.read_file(krs.path_join(directory, ".gitignore")), ".krs-stage-*\n")
	testing.expect(t, strings.contains(strings.to_string(vendor.out), "-collection:shared=vendor"))
	testing.expect(t, !os.exists(krs.path_join(vendor.fixture.shared, "beta")))
}

@(test)
command_vendor_leaves_a_vendored_project_alone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	vendor: Vendor_Fixture
	vendor_fixture_make(t, &vendor)
	defer fixtures.fixture_destroy(&vendor.fixture)

	vendor_record_beta(t, &vendor, "v0.1.0")
	testing.expect(t, krs.command_vendor(&vendor.env, {yes = true}))
	manifest := krs.path_join(vendor.fixture.project, krs.VENDOR_DIR + "/" + krs.MANIFEST_PATH)
	before := fixtures.read_file(manifest)
	testing.expect(t, before != "")

	strings.builder_reset(&vendor.out)
	testing.expect(t, krs.command_vendor(&vendor.env, {yes = true}))
	testing.expect(t, strings.contains(strings.to_string(vendor.out), "this project already uses"))
	testing.expect_value(t, fixtures.read_file(manifest), before)

	strings.builder_reset(&vendor.err)
	testing.expect(t, !krs.command_vendor(&vendor.env, {frozen = true}))
	testing.expect(t, strings.contains(strings.to_string(vendor.err), "--frozen does not apply to vendor"))
}

@(test)
vendor_enter_refuses_an_existing_vendor_directory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	vendor: Vendor_Fixture
	vendor_fixture_make(t, &vendor)
	defer fixtures.fixture_destroy(&vendor.fixture)

	vendor_record_beta(t, &vendor, "v0.1.0")
	directory := krs.path_join(vendor.fixture.project, krs.VENDOR_DIR)
	testing.expect_value(t, os.make_directory_all(directory), nil)

	entered, shared, vendored := vendor_enter_once(t, &vendor)
	testing.expect(t, !entered)
	testing.expect(t, !vendored)
	testing.expect(t, strings.has_suffix(shared, "/root/shared"), shared)
	testing.expect(t, strings.contains(strings.to_string(vendor.err), "already exists"))
	testing.expect(t, !os.exists(krs.path_join(directory, "beta")))
}

@(test)
vendor_enter_refuses_a_project_without_recorded_releases :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	vendor: Vendor_Fixture
	vendor_fixture_make(t, &vendor)
	defer fixtures.fixture_destroy(&vendor.fixture)

	fixtures.project_imports(&vendor.fixture, "beta")
	entered, _, vendored := vendor_enter_once(t, &vendor)
	testing.expect(t, !entered)
	testing.expect(t, !vendored)
	testing.expect(t, strings.contains(strings.to_string(vendor.err), "records no packages"))

	strings.builder_reset(&vendor.err)
	vendor_record_beta(t, &vendor, "")
	entered, _, vendored = vendor_enter_once(t, &vendor)
	testing.expect(t, !entered)
	testing.expect(t, !vendored)
	testing.expect(t, strings.contains(strings.to_string(vendor.err), "beta has no recorded release"))
	testing.expect(t, !os.exists(krs.path_join(vendor.fixture.project, krs.VENDOR_DIR)))
}

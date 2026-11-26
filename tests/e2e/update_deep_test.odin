package e2e

import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

// beta v1.0.0 in the project, gamma v1.0.0 in tools/gen, both installed, then
// both libraries released again at v1.1.0.
deep_fixture :: proc(fixture: ^fixtures.Fixture) -> (gen: string) {
	fixtures.library_release(fixture, "beta", "v1.0.0")
	fixtures.library_release(fixture, "gamma", "v1.0.0")
	fixtures.project_imports(fixture, "beta")
	gen = krs.path_join(fixture.project, "tools/gen")
	fixtures.write_file(fixture.t, krs.path_join(gen, "main.odin"), "package main\n\nimport \"shared:gamma\"\n")
	fixtures.write_file(fixture.t, krs.path_join(gen, krs.PACKAGES_PATH), "{\"format\": 1, \"packages\": []}\n")
	fixtures.expect_ok(fixture, fixtures.run_in(fixture, gen, "", "install", "--yes"))
	fixtures.expect_ok(fixture, fixtures.run(fixture, "", "install", "--yes"))
	fixtures.library_release(fixture, "beta", "v1.1.0")
	fixtures.library_release(fixture, "gamma", "v1.1.0")

	return gen
}

@(test)
update_deep_lists_every_project :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	deep_fixture(&fixture)
	result := fixtures.run(&fixture, "", "update", "--deep")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "project .")
	fixtures.expect_contains(&fixture, result.out, "project tools/gen")
	fixtures.expect_contains(&fixture, result.out, "beta")
	fixtures.expect_contains(&fixture, result.out, "gamma")
	fixtures.expect_contains(&fixture, result.out, "v1.1.0")
}

@(test)
update_deep_resolves_a_relative_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	deep_fixture(&fixture)
	// fixture.project is <base>/app and fixture.root is <base>/root.
	result := fixtures.run(&fixture, "", "update", "--deep", "--root=../root")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "project .")
	fixtures.expect_contains(&fixture, result.out, "project tools/gen")
	fixtures.expect_contains(&fixture, result.out, "beta")
	fixtures.expect_contains(&fixture, result.out, "gamma")
}

@(test)
update_deep_upgrades_each_lockfile :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	gen := deep_fixture(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "--deep", "-u", "--yes"))
	parent := fixtures.packages_text(&fixture)
	child := fixtures.read_file(krs.path_join(gen, krs.PACKAGES_PATH))
	fixtures.expect_contains(&fixture, parent, "\"beta\"")
	fixtures.expect_contains(&fixture, parent, "v1.1.0")
	fixtures.expect_contains(&fixture, child, "\"gamma\"")
	fixtures.expect_contains(&fixture, child, "v1.1.0")
	testing.expect(t, !strings.contains(parent, "\"gamma\""))
	testing.expect(t, !strings.contains(child, "\"beta\""))
}

@(test)
update_package_file_selects_projects :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	deep_fixture(&fixture)
	result := fixtures.run(&fixture, "", "update", "--package-file=tools/*")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "project tools/gen")
	testing.expect(t, !strings.contains(result.out, "project ."))

	none := fixtures.run(&fixture, "", "update", "--package-file=nothing")
	fixtures.expect_failure(&fixture, none, "no project matches")
}

@(test)
update_deep_skips_vendor_and_hidden :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	deep_fixture(&fixture)
	fixtures.write_file(t, krs.path_join(fixture.project, "vendor/x/.krs/packages.json"), "{\"format\": 1, \"packages\": []}\n")
	fixtures.write_file(t, krs.path_join(fixture.project, ".cache/y/.krs/packages.json"), "{\"format\": 1, \"packages\": []}\n")
	result := fixtures.run(&fixture, "", "update", "--deep")
	fixtures.expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(result.out, "project vendor"))
	testing.expect(t, !strings.contains(result.out, "project .cache"))
}

@(test)
update_deep_flags_are_checked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	Misuse :: struct {
		arguments: []string,
		message:   string,
	}
	misuses := []Misuse {
		{{"install", "--deep"}, "only applies to update"},
		{{"update", "--deep", "-j"}, "cannot be combined with JSON output"},
		{{"update", "--deep", "-g"}, "--deep and --global cannot be combined"},
	}
	for misuse in misuses {
		result := fixtures.run(&fixture, "", ..misuse.arguments)
		testing.expectf(t, result.code == krs.EXIT_USAGE, "%v: exit %d, err: %s", misuse.arguments, result.code, result.err)
		fixtures.expect_contains(&fixture, result.err, misuse.message)
	}
}

@(test)
update_deep_skips_names_a_project_does_not_use :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	gen := deep_fixture(&fixture)
	other := krs.path_join(gen, "../other")
	fixtures.write_file(t, krs.path_join(other, "main.odin"), "package main\n\nimport \"shared:gamma\"\n")
	fixtures.write_file(t, krs.path_join(other, krs.PACKAGES_PATH), "{\"format\": 1, \"packages\": []}\n")
	before := fixtures.read_file(krs.path_join(other, krs.PACKAGES_PATH))
	result := fixtures.run(&fixture, "", "update", "-u", "beta", "--deep", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "v1.1.0")
	testing.expect_value(t, fixtures.read_file(krs.path_join(other, krs.PACKAGES_PATH)), before)
	fixtures.expect_contains(&fixture, result.out, "none of the named packages are used here")
}

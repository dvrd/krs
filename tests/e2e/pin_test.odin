package e2e

import "core:encoding/json"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

// The first byte of `text` that is not white space, or 0.
first_byte :: proc(text: string) -> byte {
	trimmed := strings.trim_left_space(text)
	return trimmed[0] if len(trimmed) > 0 else 0
}

@(test)
update_json_outputs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v1.0.0")
	fixtures.library_release(&fixture, "gamma", "v1.0.0")
	fixtures.library_release(&fixture, "delta", "v1.0.0")
	fixtures.project_imports(&fixture, "beta", "gamma", "delta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "delta"))
	beta_commit := fixtures.library_release(&fixture, "beta", "v2.0.0")
	fixtures.library_release(&fixture, "delta", "v1.0.1")
	recorded := fixtures.packages_text(&fixture)

	upgraded := fixtures.run(&fixture, "", "update", "--json-upgraded")
	fixtures.expect_ok(&fixture, upgraded)
	testing.expect_value(t, first_byte(upgraded.out), '{')
	tags: map[string]string
	testing.expect_value(t, json.unmarshal(transmute([]byte)upgraded.out, &tags), nil)
	testing.expect_value(t, len(tags), 1)
	testing.expect_value(t, tags["beta"], "v2.0.0")

	whole := fixtures.run(&fixture, "", "update", "-j")
	fixtures.expect_ok(&fixture, whole)
	testing.expect_value(t, first_byte(whole.out), '{')
	fixtures.expect_contains(&fixture, whole.out, "\"tag\": \"v2.0.0\"")
	testing.expect_value(t, strings.count(whole.out, "\"pinned\""), 1)
	file: krs.Packages_File
	testing.expect_value(t, json.unmarshal(transmute([]byte)whole.out, &file), nil)
	testing.expect_value(t, file.format, krs.FORMAT)
	testing.expect_value(t, len(file.packages), 3)
	for record in file.packages {
		switch record.name {
		case "beta":
			testing.expect_value(t, record.tag, "v2.0.0")
			testing.expect_value(t, record.commit, beta_commit)
			testing.expect_value(t, record.hash, "")
		case "gamma":
			testing.expect_value(t, record.tag, "v1.0.0")
			testing.expect(t, record.hash != "")
		case "delta":
			testing.expect_value(t, record.tag, "v1.0.0")
			testing.expect(t, record.pinned)
		case:
			testing.expectf(t, false, "unexpected package %s", record.name)
		}
	}
	testing.expect_value(t, fixtures.run(&fixture, "", "update", "--json-all").out, whole.out)

	deps := fixtures.run(&fixture, "", "update", "--json-deps")
	fixtures.expect_ok(&fixture, deps)
	testing.expect_value(t, first_byte(deps.out), '[')
	list: [dynamic]krs.Package_Record
	testing.expect_value(t, json.unmarshal(transmute([]byte)deps.out, &list), nil)
	testing.expect_value(t, len(list), 3)

	// The listing changes nothing, and CI can still fail on upgrades.
	testing.expect_value(t, fixtures.packages_text(&fixture), recorded)
	strict := fixtures.run(&fixture, "", "update", "--json-upgraded", "-e", "2")
	testing.expect_value(t, strict.code, krs.EXIT_FAILED)
	testing.expect_value(t, strict.out, upgraded.out)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "-j", "-g"), "--json-all applies to a project, not --global")

	// Warnings stay off stdout; the failure goes to stderr.
	fixtures.fixture_config(&fixture, {krs.path_join(fixture.base, "other-sources")})
	unavailable := fixtures.run(&fixture, "", "update", "--json-upgraded")
	fixtures.expect_failure(&fixture, unavailable, "could not check")
	testing.expect_value(t, unavailable.out, "")
}

@(test)
update_u_keeps_a_pinned_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "beta"))
	fixtures.library_release(&fixture, "beta", "v0.2.0")

	result := fixtures.run(&fixture, "", "update", "-u", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_contains(&fixture, result.out, "is pinned")
	fixtures.expect_release(&fixture, "beta", "v0.1.0")
}

@(test)
update_explicit_tag_on_a_pinned_package_needs_pin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.release_beta_upgrade(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "beta"))
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "beta@v0.2.0", "-u", "--yes"), "add --pin")
	fixtures.expect_release(&fixture, "beta", "v0.1.0")

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", "beta@v0.2.0", "-u", "--pin", "--yes"))
	fixtures.expect_release(&fixture, "beta", "v0.2.0")
	beta := fixtures.record_of(&fixture, "beta")
	testing.expect_value(t, beta.tag, "v0.2.0")
	testing.expect(t, beta.pinned)
}

@(test)
update_u_semver_skips_a_pinned_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.4.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "beta"))
	fixtures.library_release(&fixture, "beta", "v0.4.2")

	result := fixtures.run(&fixture, "", "update", "-u", "-t", "semver", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
	fixtures.expect_contains(&fixture, result.out, "beta is pinned at v0.4.0")
}

@(test)
repair_keeps_working_for_a_matching_pin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "beta"))
	extra := krs.path_join(fixture.shared, "beta/extra.txt")
	fixtures.write_file(t, extra, "x")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--repair", "--yes"))
	testing.expect(t, !os.exists(extra))
	fixtures.expect_release(&fixture, "beta", "v0.1.0")
}

@(test)
pin_and_unpin_change_only_the_flag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	manifest := fixtures.manifest_text(&fixture)

	pinned := fixtures.run(&fixture, "", "pin", "beta")
	fixtures.expect_ok(&fixture, pinned)
	fixtures.expect_contains(&fixture, pinned.out, "beta is pinned at v0.1.0")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"pinned\": true")
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)

	again := fixtures.run(&fixture, "", "pin", "beta")
	fixtures.expect_ok(&fixture, again)
	fixtures.expect_contains(&fixture, again.out, "beta is already pinned at v0.1.0")

	unpinned := fixtures.run(&fixture, "", "unpin", "beta")
	fixtures.expect_ok(&fixture, unpinned)
	fixtures.expect_contains(&fixture, unpinned.out, "beta is no longer pinned")
	testing.expect(t, !strings.contains(fixtures.packages_text(&fixture), "pinned"))
	testing.expect_value(t, fixtures.manifest_text(&fixture), manifest)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "pin", "gamma"), "is not recorded")
}

@(test)
install_keeps_a_pin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.library_release(&fixture, "gamma", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "beta"))

	// A new import makes install rewrite the lockfile; the pin survives it.
	fixtures.project_imports(&fixture, "beta", "gamma")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"name\": \"gamma\"")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"pinned\": true")
}

@(test)
dependency_cannot_move_a_pinned_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.4.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "beta"))

	fixtures.library_release(&fixture, "beta", "v0.4.2")
	fixtures.alpha_recording_beta(&fixture, "v1.0.0", "v0.4.2")
	fixtures.project_imports(&fixture, "alpha", "beta")

	result := fixtures.run(&fixture, "", "install", "--yes")
	fixtures.expect_ok(&fixture, result)
	fixtures.expect_release(&fixture, "beta", "v0.4.0")
	fixtures.expect_contains(&fixture, result.out, "was asked for explicitly")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"tag\": \"v0.4.0\"")
	fixtures.expect_contains(&fixture, fixtures.packages_text(&fixture), "\"pinned\": true")
}

@(test)
update_refuses_a_pinned_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "beta")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "beta"))
	fixtures.library_release(&fixture, "beta", "v0.2.0")

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "update", "beta", "-u", "--yes"), "is pinned")
	fixtures.expect_release(&fixture, "beta", "v0.1.0")
}

@(test)
install_refuses_a_pin_the_root_has_moved :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	a := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&a)

	fixtures.library_release(&a, "beta", "v0.4.0")
	fixtures.project_imports(&a, "beta")
	fixtures.expect_ok(&a, fixtures.run(&a, "", "install", "--yes"))
	fixtures.expect_ok(&a, fixtures.run(&a, "", "pin", "beta"))

	b := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&b)
	b.root = a.root
	b.shared = a.shared
	b.home = a.home
	b.sources = a.sources
	fixtures.library_release(&a, "beta", "v0.4.2")
	fixtures.project_imports(&b, "beta")
	fixtures.expect_ok(&b, fixtures.run(&b, "", "install", "--yes"))
	fixtures.expect_ok(&b, fixtures.run(&b, "", "update", "beta@v0.4.2", "-u", "--yes"))
	fixtures.expect_release(&a, "beta", "v0.4.2")

	recorded := fixtures.packages_text(&a)
	fixtures.expect_failure(&a, fixtures.run(&a, "", "install", "--yes"), "is pinned at v0.4.0")
	testing.expect_value(t, fixtures.packages_text(&a), recorded)
}

@(test)
update_interactive_skips_pinned :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.interactive_fixture(&fixture)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "pin", "gamma"))

	result := fixtures.run(&fixture, "\n", "update", "-i", "--interactive-select=all")
	fixtures.expect_ok(&fixture, result)
	testing.expect(t, !strings.contains(fixtures.squeeze(result.out), "gamma v0.1.0 -> v0.1.1"))
	fixtures.expect_release(&fixture, "gamma", "v0.1.0")
}

package unit

import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
link_state_tells_each_kind_of_link_apart :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	source := krs.path_join(fixture.sources, "beta/src")
	other := krs.path_join(fixture.sources, "other/src")
	os.make_directory_all(source)
	os.make_directory_all(other)
	target := krs.path_join(fixture.shared, "beta")
	record := krs.Manifest_Record{name = "beta", linked = source}

	state, current := krs.link_state(fixture.shared, record)
	testing.expect_value(t, state, krs.Link_State.Missing)
	testing.expect_value(t, krs.link_state_text(state, current), "missing from shared/")

	testing.expect_value(t, os.symlink(source, target), nil)
	state, current = krs.link_state(fixture.shared, record)
	testing.expect_value(t, state, krs.Link_State.Working)
	testing.expect_value(t, current, source)
	testing.expect_value(t, krs.link_state_text(state, current), "")

	testing.expect_value(t, os.remove_all(source), nil)
	state, current = krs.link_state(fixture.shared, record)
	testing.expect_value(t, state, krs.Link_State.Source_Missing)
	testing.expect_value(t, krs.link_state_text(state, current), "the source no longer exists")

	testing.expect_value(t, os.remove(target), nil)
	testing.expect_value(t, os.symlink(other, target), nil)
	state, current = krs.link_state(fixture.shared, record)
	testing.expect_value(t, state, krs.Link_State.Elsewhere)
	testing.expect_value(t, current, other)
	testing.expect_value(t, krs.link_state_text(state, current), strings.concatenate({"points to ", other, " instead"}))

	testing.expect_value(t, os.remove(target), nil)
	os.make_directory_all(target)
	state, current = krs.link_state(fixture.shared, record)
	testing.expect_value(t, state, krs.Link_State.Directory)
	testing.expect_value(t, krs.link_state_text(state, current), "replaced by a directory")

	testing.expect_value(t, os.remove_all(target), nil)
	fixtures.write_file(t, target, "not a link\n")
	state, current = krs.link_state(fixture.shared, record)
	testing.expect_value(t, state, krs.Link_State.File)
	testing.expect_value(t, krs.link_state_text(state, current), "replaced by a file")
}

@(test)
link_find_takes_the_first_checkout_with_a_src :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	first := krs.path_join(fixture.base, "first")
	os.make_directory_all(krs.path_join(first, "beta"))
	os.make_directory_all(krs.path_join(fixture.sources, "beta/src"))
	out := strings.builder_make()
	env := krs.Env {
		out = strings.to_writer(&out),
	}
	state := krs.State {
		env = &env,
	}
	append(&state.config.source_directories, first, fixture.sources)

	repository, found, _ := krs.link_find(&state, "beta")
	testing.expect(t, found)
	testing.expect_value(t, repository, krs.path_join(fixture.sources, "beta"))
	testing.expect(t, strings.contains(strings.to_string(out), "it has no src/"))

	_, found, _ = krs.link_find(&state, "gamma")
	testing.expect(t, !found)
}

@(test)
status_rows_flag_what_needs_attention :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.write_file(t, krs.path_join(fixture.shared, "alpha/alpha.odin"), "package alpha\n")
	fixtures.write_file(t, krs.path_join(fixture.shared, "beta/beta.odin"), "package beta\n")
	fixtures.write_file(t, krs.path_join(fixture.shared, "epsilon/epsilon.odin"), "package epsilon\n")
	source := krs.path_join(fixture.sources, "delta/src")
	os.make_directory_all(source)
	testing.expect_value(t, os.symlink(source, krs.path_join(fixture.shared, "delta")), nil)
	alpha_hash, hashed := krs.hash_directory(krs.path_join(fixture.shared, "alpha"))
	testing.expect(t, hashed)

	planning := planning_env(&fixture)
	state := krs.State {
		env    = &planning.env,
		shared = fixture.shared,
	}
	append(
		&state.manifest.packages,
		krs.Manifest_Record{name = "alpha", tag = "v0.1.0", hash = alpha_hash},
		krs.Manifest_Record{name = "beta", tag = "v0.2.0", hash = "stale"},
		krs.Manifest_Record{name = "gamma", tag = "v0.3.0", hash = "absent"},
		krs.Manifest_Record{name = "delta", linked = source},
	)
	append(&state.packages.packages, krs.Package_Record{name = "alpha", tag = "v0.0.9"})

	rows := krs.status_rows(&state, {"alpha", "beta", "zeta"})
	testing.expect_value(t, len(rows), 6)
	if len(rows) != 6 {
		return
	}

	Expected :: struct {
		name:      string,
		label:     string,
		attention: bool,
		used:      bool,
		notes:     string,
	}
	expected := []Expected {
		{"alpha", "installed v0.1.0", true, true, "pin v0.0.9"},
		{"beta", "altered v0.2.0", true, true, ""},
		{"delta", strings.concatenate({"linked -> ", source}), false, false, "not imported here"},
		{"epsilon", "unmanaged", false, false, ""},
		{"gamma", "missing v0.3.0", true, false, "not imported here"},
		{"zeta", "not installed", true, true, ""},
	}
	for row, index in rows {
		want := expected[index]
		testing.expect_value(t, row.name, want.name)
		testing.expect_value(t, row.label, want.label)
		testing.expectf(t, row.attention == want.attention, "%s attention: %v", row.name, row.attention)
		testing.expectf(t, row.used == want.used, "%s used: %v", row.name, row.used)
		notes: [dynamic]string
		for note in row.notes {
			append(&notes, string(note))
		}
		testing.expect_value(t, strings.join(notes[:], ", "), want.notes)
	}
}

package unit

import "core:encoding/json"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

PLAN_COMMIT_A :: "1111111111111111111111111111111111111111"
PLAN_COMMIT_B :: "2222222222222222222222222222222222222222"

packages_of :: proc(records: ..krs.Package_Record) -> krs.Packages_File {
	file := krs.Packages_File{format = krs.FORMAT}
	append(&file.packages, ..records)
	return file
}

// A decision as plan_drain leaves it, without touching Git.
decided :: proc(state: ^krs.State, name, tag: string, action: krs.Action, recorded := true) -> ^krs.Decision {
	decision := krs.decision_new(state, name)
	decision.action = action
	decision.tag = tag
	decision.commit = PLAN_COMMIT_A
	decision.source = krs.SOURCE_LOCAL
	decision.hash = "hash"
	decision.recorded = recorded
	return decision
}

@(test)
packages_equal_ignores_order_and_source_spelling :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	alpha := krs.Package_Record{name = "alpha", source = "local", tag = "v0.1.0", commit = PLAN_COMMIT_A, hash = "h1"}
	beta := krs.Package_Record{name = "beta", source = "local", tag = "v0.2.0", commit = PLAN_COMMIT_B, hash = "h2"}
	a := packages_of(alpha, beta)
	b := packages_of(beta, alpha)
	testing.expect(t, krs.packages_equal(&a, &b))

	// A file:// address and "local" are the same source.
	spelled := beta
	spelled.source = "file:///somewhere/beta"
	c := packages_of(alpha, spelled)
	testing.expect(t, krs.packages_equal(&a, &c))

	moved := beta
	moved.tag = "v0.3.0"
	d := packages_of(alpha, moved)
	testing.expect(t, !krs.packages_equal(&a, &d))

	pinned := beta
	pinned.pinned = true
	e := packages_of(alpha, pinned)
	testing.expect(t, !krs.packages_equal(&a, &e))

	shorter := packages_of(alpha)
	testing.expect(t, !krs.packages_equal(&a, &shorter))

	renamed := beta
	renamed.name = "gamma"
	f := packages_of(alpha, renamed)
	testing.expect(t, !krs.packages_equal(&a, &f))
}

@(test)
plan_packages_records_reached_packages_in_name_order :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	env := krs.Env{}
	state := krs.State {
		env = &env,
	}
	linked := krs.Package_Record{name = "delta", source = "local", tag = "v0.4.0", commit = PLAN_COMMIT_B, hash = "kept"}
	state.packages = packages_of(krs.Package_Record{name = "alpha", source = "local", tag = "v0.1.0", pinned = true}, linked)
	state.pin_names["gamma"] = true

	decided(&state, "gamma", "v0.3.0", .Install)
	decided(&state, "alpha", "v0.1.0", .Keep)
	decided(&state, "beta", "v0.2.0", .Install, recorded = false)
	decided(&state, "delta", "", .Linked)
	decided(&state, "epsilon", "", .Unmanaged)

	file := krs.plan_packages(&state)
	testing.expect_value(t, file.format, krs.FORMAT)
	testing.expect_value(t, len(file.packages), 3)
	if len(file.packages) != 3 {
		return
	}

	testing.expect_value(t, file.packages[0].name, "alpha")
	testing.expect(t, file.packages[0].pinned)
	testing.expect_value(t, file.packages[0].commit, PLAN_COMMIT_A)
	testing.expect_value(t, file.packages[1], linked)
	testing.expect_value(t, file.packages[2].name, "gamma")
	testing.expect_value(t, file.packages[2].tag, "v0.3.0")
	testing.expect_value(t, file.packages[2].hash, "hash")
	testing.expect(t, file.packages[2].pinned)
}

@(test)
plan_frozen_check_refuses_any_change :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	errors := strings.builder_make()
	env := krs.Env {
		err = strings.to_writer(&errors),
	}
	state := krs.State {
		env = &env,
	}
	decided(&state, "alpha", "v0.1.0", .Keep)
	state.packages = packages_of(krs.Package_Record{name = "alpha", source = "local", tag = "v0.1.0", commit = PLAN_COMMIT_A, hash = "hash"})
	same := krs.plan_packages(&state)
	testing.expect(t, krs.plan_frozen_check(&state, &same))

	state.decisions["alpha"].tag = "v0.2.0"
	changed := krs.plan_packages(&state)
	testing.expect(t, !krs.plan_frozen_check(&state, &changed))
	testing.expect(t, strings.contains(strings.to_string(errors), "--frozen: .krs/packages.json would change"))

	strings.builder_reset(&errors)
	append(&state.altered, "alpha")
	testing.expect(t, !krs.plan_frozen_check(&state, &same))
	testing.expect(t, strings.contains(strings.to_string(errors), "--frozen: alpha does not match its recorded hash"))

	clear(&state.altered)
	strings.builder_reset(&errors)
	decided(&state, "beta", "", .Unmanaged)
	append(&state.packages.packages, krs.Package_Record{name = "beta", tag = "v0.1.0"})
	testing.expect(t, !krs.plan_frozen_check(&state, &same))
	testing.expect(t, strings.contains(strings.to_string(errors), "cannot verify the recorded version of unmanaged package beta"))
}

@(test)
plan_record_only_writes_the_decided_versions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	planning, state := planning_state(&fixture)
	if state == nil {
		return
	}
	defer krs.state_close(state)

	decided(state, "beta", "v0.2.0", .Keep)
	testing.expect(t, krs.plan_record_only(state))
	testing.expect(t, strings.contains(strings.to_string(planning.out), "records the new versions"))

	written: krs.Packages_File
	err := json.unmarshal(transmute([]byte)fixtures.packages_text(&fixture), &written)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(written.packages), 1)
	if len(written.packages) == 1 {
		testing.expect_value(t, written.packages[0].name, "beta")
		testing.expect_value(t, written.packages[0].tag, "v0.2.0")
		testing.expect_value(t, written.packages[0].commit, PLAN_COMMIT_A)
	}

	// Nothing to write when the records already match.
	state.packages = written
	strings.builder_reset(&planning.out)
	testing.expect(t, krs.plan_record_only(state))
	testing.expect(t, strings.contains(strings.to_string(planning.out), "is already up to date"))
}

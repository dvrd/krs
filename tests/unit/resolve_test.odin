package unit

import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
pins_problem_rejects_malformed_dependency_records :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	valid := krs.Package_Record{name = "beta", source = "https://github.com/o/beta.git", tag = "v0.1.0", commit = PLAN_COMMIT_A}
	testing.expect_value(t, krs.pins_problem(packages_of(valid)), "")
	testing.expect_value(t, krs.pins_problem(packages_of(krs.Package_Record{name = "beta"})), "")

	bad_name := valid
	bad_name.name = "../beta"
	testing.expect_value(t, krs.pins_problem(packages_of(bad_name)), "has an invalid package name")

	bad_tag := valid
	bad_tag.tag = "1.0"
	testing.expect_value(t, krs.pins_problem(packages_of(bad_tag)), "records beta with an invalid tag")

	bad_commit := valid
	bad_commit.commit = "main"
	testing.expect_value(t, krs.pins_problem(packages_of(bad_commit)), "records beta with an invalid commit")

	bad_source := valid
	bad_source.source = "local\x1b[2J"
	testing.expect_value(t, krs.pins_problem(packages_of(bad_source)), "records beta with an invalid source")

	// The first bad record is reported, even after good ones.
	testing.expect_value(t, krs.pins_problem(packages_of(valid, bad_tag)), "records beta with an invalid tag")
}

@(test)
release_pins_reads_the_lockfile_of_a_release :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	beta_commit := fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.library_recording(&fixture, "alpha", "v0.1.0", "beta", "v0.1.0")
	gamma := fixtures.repository_make(&fixture, "gamma")
	fixtures.write_file(t, krs.path_join(gamma, krs.PACKAGES_PATH), "{\"format\": 1, \"packages\": [{\"name\": \"beta\", \"tag\": \"latest\"}]}\n")
	fixtures.library_release(&fixture, "gamma", "v0.1.0")
	delta := fixtures.repository_make(&fixture, "delta")
	fixtures.write_file(t, krs.path_join(delta, krs.PACKAGES_PATH), "not json\n")
	fixtures.library_release(&fixture, "delta", "v0.1.0")

	_, state := planning_state(&fixture)
	if state == nil {
		return
	}
	defer krs.state_close(state)

	pins_of :: proc(t: ^testing.T, fixture: ^fixtures.Fixture, name: string) -> (krs.Packages_File, string) {
		release, ok := krs.git_release_open(krs.path_join(fixture.sources, name), "v0.1.0", "")
		testing.expectf(t, ok, "cannot open %s v0.1.0", name)
		if !ok {
			return {}, "not opened"
		}
		defer krs.git_release_close(release)
		return krs.release_pins(release)
	}

	pins, problem := pins_of(t, &fixture, "alpha")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(pins.packages), 1)
	if len(pins.packages) == 1 {
		testing.expect_value(t, pins.packages[0].name, "beta")
		testing.expect_value(t, pins.packages[0].tag, "v0.1.0")
		testing.expect_value(t, pins.packages[0].commit, beta_commit)
	}

	// No lockfile is not a problem.
	pins, problem = pins_of(t, &fixture, "beta")
	testing.expect_value(t, problem, "")
	testing.expect_value(t, len(pins.packages), 0)

	pins, problem = pins_of(t, &fixture, "gamma")
	testing.expect_value(t, problem, "records beta with an invalid tag")

	_, problem = pins_of(t, &fixture, "delta")
	testing.expect(t, problem != "", "an unreadable lockfile must be a problem")
}

@(test)
reconcile_keeps_the_higher_compatible_version :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	out := strings.builder_make()
	errors := strings.builder_make()
	env := krs.Env {
		out = strings.to_writer(&out),
		err = strings.to_writer(&errors),
	}
	state := krs.State {
		env = &env,
	}

	chosen, ok := krs.reconcile(&state, "beta", "v0.1.0", "v0.1.3", "alpha v0.2.0")
	testing.expect(t, ok)
	testing.expect_value(t, chosen, "v0.1.3")
	chosen, ok = krs.reconcile(&state, "beta", "v1.4.0", "v1.2.0", "alpha v0.2.0")
	testing.expect(t, ok)
	testing.expect_value(t, chosen, "v1.4.0")
	testing.expect(t, strings.contains(strings.to_string(out), "are compatible; using v1.4.0"))

	// On major zero a new minor breaks; without a terminal that is a failure.
	chosen, ok = krs.reconcile(&state, "beta", "v0.1.0", "v0.2.0", "alpha v0.2.0")
	testing.expect(t, !ok)
	testing.expect_value(t, chosen, "")
	testing.expect(t, strings.contains(strings.to_string(errors), "beta needs a decision between v0.1.0 and v0.2.0"))

	chosen, ok = krs.reconcile(&state, "beta", "v1.0.0", "v2.0.0", "alpha v0.2.0")
	testing.expect(t, !ok)

	strings.builder_reset(&errors)
	chosen, ok = krs.reconcile(&state, "beta", "v0.1.0", "main", "alpha v0.2.0")
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(strings.to_string(errors), "beta: cannot compare v0.1.0 with main"))
}

@(test)
reconcile_asks_once_when_a_person_can_answer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	out := strings.builder_make()
	env := krs.Env {
		out         = strings.to_writer(&out),
		err         = strings.to_writer(&out),
		interactive = true,
	}
	state := krs.State {
		env = &env,
	}

	chosen, ok := krs.reconcile(&state, "beta", "v0.1.0", "v0.2.0", "alpha v0.2.0")
	testing.expect(t, !ok)
	testing.expect_value(t, chosen, "")
	question := state.version_question
	testing.expect_value(t, question.name, "beta")
	testing.expect_value(t, question.higher, "v0.2.0")
	testing.expect_value(t, question.lower, "v0.1.0")

	state.version_answers[question] = "v0.1.0"
	chosen, ok = krs.reconcile(&state, "beta", "v0.1.0", "v0.2.0", "alpha v0.2.0")
	testing.expect(t, ok)
	testing.expect_value(t, chosen, "v0.1.0")
}

@(test)
plan_drain_resolves_an_import_to_its_highest_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.library_release(&fixture, "beta", "v0.3.0")
	latest := fixtures.library_release(&fixture, "beta", "v0.2.0")
	highest := fixtures.git(t, krs.path_join(fixture.sources, "beta"), "rev-parse", "v0.3.0^{commit}")
	testing.expect(t, latest != highest)
	fixtures.project_imports(&fixture, "beta")

	_, state := planning_state(&fixture)
	if state == nil {
		return
	}
	defer krs.state_close(state)

	testing.expect(t, krs.plan_discover(state))
	testing.expect(t, krs.plan_drain(state))
	decision := state.decisions["beta"]
	testing.expect(t, decision != nil)
	if decision == nil {
		return
	}

	testing.expect_value(t, decision.action, krs.Action.Install)
	testing.expect_value(t, decision.tag, "v0.3.0")
	testing.expect_value(t, decision.commit, highest)
	testing.expect_value(t, decision.repository, krs.path_join(fixture.sources, "beta"))
	testing.expect(t, decision.recorded)
}

@(test)
plan_drain_follows_a_dependency_pin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.library_release(&fixture, "beta", "v0.1.1")
	fixtures.library_recording(&fixture, "alpha", "v0.1.0", "beta", "v0.1.0")
	fixtures.project_imports(&fixture, "alpha")

	_, state := planning_state(&fixture)
	if state == nil {
		return
	}
	defer krs.state_close(state)

	testing.expect(t, krs.plan_discover(state))
	testing.expect(t, krs.plan_drain(state))
	testing.expect_value(t, len(state.order), 2)
	beta := state.decisions["beta"]
	testing.expect(t, beta != nil)
	if beta != nil {
		// alpha recorded beta v0.1.0, so the newer v0.1.1 is not chosen.
		testing.expect_value(t, beta.tag, "v0.1.0")
		testing.expect(t, beta.recorded)
	}
}

@(test)
plan_drain_fails_for_an_import_with_no_repository :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.project_imports(&fixture, "nowhere")
	planning, state := planning_state(&fixture)
	if state == nil {
		return
	}
	defer krs.state_close(state)

	testing.expect(t, krs.plan_discover(state))
	testing.expect(t, !krs.plan_drain(state))
	testing.expect(t, strings.contains(strings.to_string(planning.err), "no repository for \"nowhere\""), strings.to_string(planning.err))
}

@(test)
frozen_root_conflict_allows_only_a_newer_compatible_release :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect(t, !krs.frozen_root_conflict("", "v0.4.1"))
	testing.expect(t, !krs.frozen_root_conflict("v0.4.1", "v0.4.1"))
	testing.expect(t, !krs.frozen_root_conflict("v0.4.0", "v0.4.1"))
	testing.expect(t, !krs.frozen_root_conflict("v1.2.0", "v1.3.0"))
	testing.expect(t, krs.frozen_root_conflict("v0.4.2", "v0.4.1"))
	testing.expect(t, krs.frozen_root_conflict("v0.5.0", "v0.4.1"))
	testing.expect(t, krs.frozen_root_conflict("v0.4.2", "v0.5.0"))
	testing.expect(t, krs.frozen_root_conflict("v1.9.0", "v2.0.0"))
}

package unit

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

// An Env for a fixture, with output kept in builders. Heap-allocated so the
// writers keep pointing at the builders.
Planning_Env :: struct {
	env: krs.Env,
	out: strings.Builder,
	err: strings.Builder,
}

planning_env :: proc(fixture: ^fixtures.Fixture) -> ^Planning_Env {
	planning := new(Planning_Env)
	planning.out = strings.builder_make()
	planning.err = strings.builder_make()
	planning.env = krs.Env {
		project      = fixture.project,
		home         = fixture.home,
		default_root = fixture.root,
		out          = strings.to_writer(&planning.out),
		err          = strings.to_writer(&planning.err),
	}
	return planning
}

// Opens a State on the fixture; the caller closes it with krs.state_close.
planning_state :: proc(fixture: ^fixtures.Fixture, options := krs.Options{}, loc := #caller_location) -> (^Planning_Env, ^krs.State) {
	planning := planning_env(fixture)
	state, ok := krs.state_open(&planning.env, options)
	testing.expectf(fixture.t, ok, "state_open failed: %s", strings.to_string(planning.err), loc = loc)
	return planning, state
}

@(test)
state_open_sets_the_project_and_odin_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	_, state := planning_state(&fixture)
	if state == nil {
		return
	}
	defer krs.state_close(state)

	project, _ := os.get_absolute_path(fixture.project, context.temp_allocator)
	root, _ := os.get_absolute_path(fixture.root, context.temp_allocator)
	testing.expect_value(t, state.scope.project, project)
	testing.expect_value(t, state.scope.root, root)
	testing.expect_value(t, state.shared, krs.path_join(root, "shared"))
	testing.expect(t, !state.vendored)
	testing.expect_value(t, len(state.config.source_directories), 1)
	testing.expect_value(t, len(state.packages.packages), 0)
	testing.expect_value(t, len(state.manifest.packages), 0)
}

@(test)
state_open_uses_vendor_when_the_project_has_one :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	vendor := krs.path_join(fixture.project, krs.VENDOR_DIR)
	fixtures.write_file(t, krs.path_join(vendor, krs.MANIFEST_PATH), "{\"format\": 1, \"packages\": []}\n")

	_, state := planning_state(&fixture)
	if state == nil {
		return
	}
	defer krs.state_close(state)

	testing.expect(t, state.vendored)
	testing.expect(t, strings.has_suffix(state.shared, "/app/vendor"), state.shared)
}

@(test)
state_open_fails_without_a_project_or_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	planning := planning_env(&fixture)
	planning.env.project = ""
	state, ok := krs.state_open(&planning.env, {})
	testing.expect(t, !ok && state == nil)
	testing.expect(t, strings.contains(strings.to_string(planning.err), "cannot locate the current project directory"))

	planning = planning_env(&fixture)
	planning.env.default_root = ""
	state, ok = krs.state_open(&planning.env, {})
	testing.expect(t, !ok && state == nil)
	testing.expect(t, strings.contains(strings.to_string(planning.err), "no Odin root"))

	planning = planning_env(&fixture)
	state, ok = krs.state_open(&planning.env, {root = krs.path_join(fixture.base, "absent")})
	testing.expect(t, !ok && state == nil)
	testing.expect(t, strings.contains(strings.to_string(planning.err), "does not exist"))
}

@(test)
report_once_prints_each_message_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	out := strings.builder_make()
	env := krs.Env {
		out = strings.to_writer(&out),
	}
	state := krs.State {
		env = &env,
	}
	krs.report_once(&state, "skipped %s: %v", "beta", "it has no src/")
	krs.report_once(&state, "skipped %s: %v", "beta", "it has no src/")
	krs.report_once(&state, "skipped %s: %v", "gamma", "it has no src/")

	text := strings.to_string(out)
	testing.expect_value(t, strings.count(text, "skipped beta: it has no src/"), 1)
	testing.expect_value(t, strings.count(text, "skipped gamma: it has no src/"), 1)
	testing.expect_value(t, len(state.reported), 2)
}

@(test)
plan_reset_forgets_every_decision :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	env := krs.Env{}
	state := krs.State {
		env = &env,
	}
	krs.decision_new(&state, "beta")
	append(&state.queue, krs.Request{name = "beta"})
	append(&state.altered, "beta")
	state.installed_hashes["beta"] = {hash = "abc", ok = true}
	append(&state.reported, krs.Painted("kept"))

	krs.plan_reset(&state)
	testing.expect_value(t, len(state.decisions), 0)
	testing.expect_value(t, len(state.order), 0)
	testing.expect_value(t, len(state.queue), 0)
	testing.expect_value(t, len(state.altered), 0)
	testing.expect_value(t, len(state.installed_hashes), 0)
	// Messages already printed stay printed once.
	testing.expect_value(t, len(state.reported), 1)
}

@(test)
plan_discover_queues_each_shared_import :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.project_imports(&fixture, "beta", "gamma")
	planning := planning_env(&fixture)
	state := krs.State {
		env = &planning.env,
	}
	testing.expect(t, krs.plan_discover(&state))
	testing.expect_value(t, len(state.queue), 2)

	names: [dynamic]string
	for request in state.queue {
		append(&names, request.name)
		testing.expect_value(t, request.by, "this project")
		testing.expect(t, request.recorded)
		testing.expect_value(t, request.kind, krs.Request_Kind.Dependency)
		testing.expect_value(t, request.tag, "")
	}
	testing.expect(t, slice.contains(names[:], "beta"))
	testing.expect(t, slice.contains(names[:], "gamma"))

	planning.env.project = krs.path_join(fixture.base, "absent")
	missing := krs.State {
		env = &planning.env,
	}
	testing.expect(t, !krs.plan_discover(&missing))
	testing.expect(t, strings.contains(strings.to_string(planning.err), "cannot read the Odin files"))
}

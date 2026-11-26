package unit

import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
directory_lock_is_exclusive_until_unlocked :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	failure := strings.builder_make()
	env := krs.Env{err = strings.to_writer(&failure)}

	first, ok := krs.directory_lock(&env, fixture.project)
	testing.expect(t, ok)
	testing.expect(t, first != nil)

	second, again := krs.directory_lock(&env, fixture.project)
	testing.expect(t, !again)
	testing.expect(t, second == nil)
	testing.expect(t, strings.contains(strings.to_string(failure), "another command may be using it"))

	// A different directory is independent.
	other, other_ok := krs.directory_lock(&env, fixture.root)
	testing.expect(t, other_ok)
	krs.directory_unlock(other)

	krs.directory_unlock(first)
	third, released := krs.directory_lock(&env, fixture.project)
	testing.expect(t, released)
	if released {
		krs.directory_unlock(third)
	}
}

@(test)
directory_lock_fails_on_a_missing_directory :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	failure := strings.builder_make()
	env := krs.Env{err = strings.to_writer(&failure)}

	handle, ok := krs.directory_lock(&env, krs.path_join(fixture.base, "absent"))
	testing.expect(t, !ok)
	testing.expect(t, handle == nil)
	testing.expect(t, strings.contains(strings.to_string(failure), "cannot open"))
}

@(test)
scope_locks_pair_with_scope_unlock :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	failure := strings.builder_make()
	env := krs.Env{err = strings.to_writer(&failure)}
	project, _ := os.get_absolute_path(fixture.project, context.temp_allocator)
	root, _ := os.get_absolute_path(fixture.root, context.temp_allocator)
	scope := krs.Journal_Scope{project = project, root = root}

	held: [2]^os.File
	testing.expect(t, krs.scope_lock(&env, scope, {}, &held))
	testing.expect(t, held[0] != nil)
	testing.expect(t, held[1] != nil)

	// Both directories are busy while the scope is held.
	rival: [2]^os.File
	testing.expect(t, !krs.scope_lock(&env, scope, {}, &rival))
	testing.expect(t, rival[0] == nil)

	krs.scope_unlock(&held)
	testing.expect(t, krs.scope_lock(&env, scope, {}, &rival))
	krs.scope_unlock(&rival)
	// Unlocking what was never locked does nothing.
	empty: [2]^os.File
	krs.scope_unlock(&empty)
}

@(test)
scope_lock_skips_what_the_caller_holds_and_shared_directories :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	failure := strings.builder_make()
	env := krs.Env{err = strings.to_writer(&failure)}
	project, _ := os.get_absolute_path(fixture.project, context.temp_allocator)
	root, _ := os.get_absolute_path(fixture.root, context.temp_allocator)
	scope := krs.Journal_Scope{project = project, root = root}

	// Recovery already owns the project, so only the root is locked.
	held: [2]^os.File
	testing.expect(t, krs.scope_lock(&env, scope, {project = project}, &held))
	testing.expect(t, held[0] == nil)
	testing.expect(t, held[1] != nil)
	krs.scope_unlock(&held)

	// A project that is its own root is locked once.
	same: [2]^os.File
	testing.expect(t, krs.scope_lock(&env, {project = project, root = project}, {}, &same))
	testing.expect(t, same[0] != nil)
	testing.expect(t, same[1] == nil)
	krs.scope_unlock(&same)

	// A recorded directory must already be in canonical form.
	relative: [2]^os.File
	testing.expect(t, !krs.scope_lock(&env, {project = "relative/path", root = root}, {}, &relative))
	testing.expect(t, strings.contains(strings.to_string(failure), "cannot resolve the recorded transaction directory"))
}

@(test)
state_lock_holds_both_directories_until_state_close :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	failure := strings.builder_make()
	env := krs.Env{project = fixture.project, err = strings.to_writer(&failure)}

	state := krs.State{env = &env}
	testing.expect(t, krs.state_lock(&state, fixture.root))
	testing.expect(t, state.locks[0] != nil)
	testing.expect(t, state.locks[1] != nil)
	testing.expect(t, strings.has_suffix(state.shared, "/root/shared"))
	testing.expect(t, strings.has_suffix(state.scope.project, "/app"))

	rival := krs.State{env = &env}
	testing.expect(t, !krs.state_lock(&rival, fixture.root))

	krs.state_close(&state)
	testing.expect(t, krs.state_lock(&rival, fixture.root))
	krs.state_close(&rival)
}

@(test)
state_lock_fails_when_the_root_cannot_be_resolved :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	failure := strings.builder_make()
	env := krs.Env{project = fixture.project, err = strings.to_writer(&failure)}

	state := krs.State{env = &env}
	testing.expect(t, !krs.state_lock(&state, krs.path_join(fixture.base, "absent")))
	testing.expect(t, state.locks[0] == nil || state.locks[1] == nil)
	krs.state_close(&state)
}

package krs

import "core:c"
import "core:os"

foreign import libc "system:c"

foreign libc {
	flock :: proc "c" (fd, operation: c.int) -> c.int ---
}

LOCK_EX :: 2
LOCK_NB :: 4
LOCK_UN :: 8

// Lock the directories themselves so a read-only command does not create a
// lock file. Closing the file handles releases the locks, including on exit.
state_lock :: proc(state: ^State, root: string) -> bool {
	project, err := os.get_absolute_path(state.env.project, context.temp_allocator)
	if err != nil {
		return fail(state.env, "cannot locate the project directory: %v", err)
	}

	root_path, root_err := os.get_absolute_path(root, context.temp_allocator)
	if root_err != nil {
		return fail(state.env, "cannot resolve the Odin root %s: %v", root, root_err)
	}

	state.scope = {project = project, root = root_path}
	state.shared = path_join(root_path, "shared")
	if !scope_lock(state.env, state.scope, {}, &state.locks) {
		return false
	}
	return true
}

// Current holds the locks already owned by the caller during recovery.
scope_lock :: proc(env: ^Env, scope, current: Journal_Scope, locks: ^[2]^os.File) -> bool {
	paths := [2]string{scope.project, scope.root}
	for path, index in paths {
		if path == current.project || path == current.root || (index == 1 && path == scope.project) {
			continue
		}

		if canonical, err := os.get_absolute_path(path, context.temp_allocator); err != nil || canonical != path {
			return fail(env, "cannot resolve the recorded transaction directory %s", path)
		}

		locks[index] = directory_lock(env, path) or_return
	}
	return true
}

directory_lock :: proc(env: ^Env, path: string) -> (handle: ^os.File, ok: bool) {
	file, err := os.open(path)
	if err != nil {
		return nil, fail(env, "cannot open %s: %v", path, err)
	}

	if flock(c.int(os.fd(file)), LOCK_EX | LOCK_NB) != 0 {
		os.close(file)
		return nil, fail(env, "cannot lock %s; another command may be using it", path)
	}
	return file, true
}

directory_unlock :: proc(handle: ^os.File) {
	flock(c.int(os.fd(handle)), LOCK_UN)
	os.close(handle)
}

scope_unlock :: proc(locks: ^[2]^os.File) {
	for handle in locks {
		if handle != nil {
			directory_unlock(handle)
		}
	}
}

state_close :: proc(state: ^State) {
	scope_unlock(&state.locks)
}

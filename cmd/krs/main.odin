package main

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:terminal"

import krs "../../src"

// `ODIN_ROOT`, or what `odin root` prints when it is unset.
default_root :: proc() -> string {
	root, found := os.lookup_env("ODIN_ROOT", context.allocator)
	if found && root != "" {
		return root
	}

	state, stdout, _, err := os.process_exec({command = {"odin", "root"}}, context.allocator)
	if err != nil || !state.exited || state.exit_code != 0 {
		return ""
	}

	return strings.trim_space(string(stdout))
}

main :: proc() {
	// krs runs once and exits; everything it allocates lives until then.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) == nil {
		context.allocator = virtual.arena_allocator(&arena)
	}

	project, _ := os.get_working_directory(context.allocator)
	home, _ := os.user_home_dir(context.allocator)

	env := krs.Env {
		project      = project,
		home         = home,
		find_root    = default_root,
		out          = os.to_writer(os.stdout),
		err          = os.to_writer(os.stderr),
		input        = os.to_reader(os.stdin),
		interactive  = terminal.is_terminal(os.stdin),
	}

	os.exit(krs.run(&env, os.args[1:]))
}

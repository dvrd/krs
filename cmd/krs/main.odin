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
	term := os.get_env("TERM", context.allocator)
	no_color := os.get_env("NO_COLOR", context.allocator) != ""
	no_animation := os.get_env("KRS_NO_ANIMATION", context.allocator) != ""
	style := krs.Output_Style{
		stdout = term != "dumb" && terminal.is_terminal(os.stdout),
		stderr = term != "dumb" && terminal.is_terminal(os.stderr),
		color  = !no_color,
	}
	env := krs.Env {
		project      = project,
		home         = home,
		find_root    = default_root,
		out          = os.to_writer(os.stdout),
		err          = os.to_writer(os.stderr),
		input        = os.to_reader(os.stdin),
		interactive  = terminal.is_terminal(os.stdin),
		style        = style,
	}

	progress := krs.Progress{output = env.err}
	width, _, measured := terminal.get_terminal_size()
	if style.stdout && style.stderr && style.color && !no_animation && (!measured || width >= 24) {
		env.progress = &progress
	}

	os.exit(krs.run(&env, os.args[1:]))
}

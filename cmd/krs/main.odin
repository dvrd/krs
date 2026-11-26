package main

import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sys/posix"
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

// The terminal modes from before terminal_raw_input(true), restored by
// terminal_raw_input(false). Valid only while raw mode is on.
@(private = "file")
terminal_saved: posix.termios
@(private = "file")
terminal_saved_valid: bool

// Signals that end krs from outside while the picker has the terminal raw.
// Ctrl-C, Ctrl-\ and Ctrl-Z raise nothing in raw mode (ISIG is off).
@(private = "file")
TERMINAL_SIGNALS :: [2]posix.Signal{.SIGTERM, .SIGHUP}
@(private = "file")
terminal_previous: [len(TERMINAL_SIGNALS)]posix.sigaction_t
@(private = "file")
terminal_installed: [len(TERMINAL_SIGNALS)]bool // terminal_on_signal handles it

// Raw mode for the picker: keys arrive byte by byte, without echo, and
// Ctrl-C arrives as 0x03 instead of killing krs, so the picker itself
// restores the terminal before it exits. SIGTERM and SIGHUP restore it in
// terminal_on_signal.
terminal_raw_input :: proc(enable: bool) -> bool {
	if !enable {
		if !terminal_saved_valid {
			return true
		}

		terminal_saved_valid = false
		// TCSADRAIN keeps what was typed ahead, such as the answer to the
		// confirmation that follows the picker.
		restored := posix.tcsetattr(posix.STDIN_FILENO, .TCSADRAIN, &terminal_saved) == .OK
		// After the modes: a signal in between finds them restored already.
		terminal_signals_restore()
		return restored
	}

	assert(!terminal_saved_valid) // raw mode does not nest
	if posix.tcgetattr(posix.STDIN_FILENO, &terminal_saved) != .OK {
		return false
	}

	// Before the modes change, so no signal finds the terminal raw and
	// unguarded.
	terminal_signals_install()
	raw := terminal_saved
	raw.c_lflag -= {.ICANON, .ECHO, .ISIG, .IEXTEN}
	raw.c_iflag -= {.ICRNL, .IXON}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	if posix.tcsetattr(posix.STDIN_FILENO, .TCSAFLUSH, &raw) != .OK {
		terminal_signals_restore()
		return false
	}

	terminal_saved_valid = true
	return true
}

// Saves each signal's action and puts terminal_on_signal in its place. A
// signal that was ignored, as under nohup, stays ignored.
@(private = "file")
terminal_signals_install :: proc() {
	action := posix.sigaction_t {
		sa_handler = terminal_on_signal,
	}
	posix.sigemptyset(&action.sa_mask)

	for signal, index in TERMINAL_SIGNALS {
		assert(!terminal_installed[index])
		if posix.sigaction(signal, &action, &terminal_previous[index]) != .OK {
			continue // the previous action stays in place
		}

		if rawptr(terminal_previous[index].sa_handler) == posix.SIG_IGN {
			posix.sigaction(signal, &terminal_previous[index], nil)
		} else {
			terminal_installed[index] = true
		}
	}
}

@(private = "file")
terminal_signals_restore :: proc() {
	for signal, index in TERMINAL_SIGNALS {
		if terminal_installed[index] {
			terminal_installed[index] = false
			posix.sigaction(signal, &terminal_previous[index], nil)
		}
	}
}

// Restores the terminal, then lets the signal do what it did before: the
// previous action is put back and the signal raised again; it is delivered
// once this handler returns. Only async-signal-safe calls: no allocation,
// no formatting.
@(private = "file")
terminal_on_signal :: proc "c" (signal: posix.Signal) {
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &terminal_saved)
	for watched, index in TERMINAL_SIGNALS {
		if watched == signal {
			posix.sigaction(signal, &terminal_previous[index], nil)
		}
	}
	posix.raise(signal)
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

	if env.interactive {
		env.raw_input = terminal_raw_input
	}

	progress := krs.Progress{output = env.err}
	width, _, measured := terminal.get_terminal_size()
	if style.stdout && style.stderr && style.color && !no_animation && (!measured || width >= 24) {
		env.progress = &progress
	}

	os.exit(krs.run(&env, os.args[1:]))
}

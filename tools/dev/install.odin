package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

SPINNER_FRAMES :: [?]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
SPINNER_TICK :: 90 * time.Millisecond
EXIT_INTERRUPTED :: 130
EXIT_TERMINATED :: 143

// Set by the signal handler, read by the build wait loop. The build child is in
// our process group and receives the signal itself.
received_signal: posix.Signal

on_signal :: proc "c" (sig: posix.Signal) {
	received_signal = sig
}

// icon prints a status icon when stdout is a terminal, colored unless NO_COLOR.
icon :: proc(color: int, glyph: string, to_stderr: bool) {
	terminal := os.get_env("TERM", context.allocator)
	if !os.is_tty(os.stdout) || terminal == "dumb" {
		return
	}

	writer := os.to_writer(os.stderr if to_stderr else os.stdout)
	if os.get_env("NO_COLOR", context.allocator) == "" {
		fmt.wprintf(writer, "\x1b[%dm%s\x1b[0m  ", color, glyph)
	} else {
		fmt.wprintf(writer, "%s  ", glyph)
	}
}

install_fail :: proc(message: string, code := EXIT_FAILED) -> int {
	assert(code != EXIT_OK)

	icon(31, "✕", true)
	fmt.eprintfln("krs: %s", message)
	return code
}

install :: proc() -> int {
	out := os.get_env("KRS_CHECK_DIR", context.allocator)
	if out == "" {
		tmp := os.get_env("TMPDIR", context.allocator)
		out = fmt.tprintf("%s/krs-check", tmp if tmp != "" else "/tmp")
	}

	bin_dir := os.get_env("KRS_INSTALL_DIR", context.allocator)
	if bin_dir == "" {
		bin_dir = fmt.tprintf("%s/.local/bin", os.get_env("HOME", context.allocator))
	}

	destination := fmt.tprintf("%s/krs", bin_dir)
	if os.is_dir(destination) {
		return install_fail(fmt.tprintf("cannot replace directory %s", destination))
	}

	handler: posix.sigaction_t
	handler.sa_handler = on_signal
	posix.sigemptyset(&handler.sa_mask)
	posix.sigaction(.SIGINT, &handler, nil)
	posix.sigaction(.SIGTERM, &handler, nil)

	log_path := fmt.tprintf("%s/krs-install.log", out)
	staged := fmt.tprintf("%s/.krs.%d", bin_dir, os.get_pid())
	defer os.remove(log_path)
	defer os.remove(staged)

	code := build(out, log_path)
	if code != EXIT_OK {
		return code
	}

	if !ensure_dir(bin_dir) {
		return install_fail(fmt.tprintf("cannot create %s", bin_dir))
	}

	if signal_code, stopped := interrupted(); stopped {
		return signal_code
	}

	if err := os.copy_file(staged, fmt.tprintf("%s/krs", out)); err != nil {
		return install_fail(fmt.tprintf("cannot stage %s", destination))
	}

	if posix.chmod(strings.clone_to_cstring(staged, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}) != .OK {
		return install_fail(fmt.tprintf("cannot copy KRS to %s", destination))
	}

	if signal_code, stopped := interrupted(); stopped {
		return signal_code
	}

	if err := os.rename(staged, destination); err != nil {
		return install_fail(fmt.tprintf("cannot replace %s", destination))
	}

	icon(32, "✓", false)
	fmt.printfln("krs: installed %s", destination)
	return EXIT_OK
}

// interrupted reports the exit code for a received SIGINT or SIGTERM.
interrupted :: proc() -> (code: int, stopped: bool) {
	if received_signal == nil {
		return EXIT_OK, false
	}
	return (EXIT_INTERRUPTED if received_signal == .SIGINT else EXIT_TERMINATED), true
}

ensure_dir :: proc(path: string) -> bool {
	assert(path != "")

	return os.is_dir(path) || os.make_directory_all(path) == nil
}

animated :: proc() -> bool {
	return(
		os.is_tty(os.stdout) &&
		os.is_tty(os.stderr) &&
		os.get_env("TERM", context.allocator) != "dumb" &&
		os.get_env("NO_COLOR", context.allocator) == "" &&
		os.get_env("KRS_NO_ANIMATION", context.allocator) == "" \
	)
}

// build runs `task build`, with a spinner when the terminal allows it. It
// returns the exit code to use: zero on success.
build :: proc(out, log_path: string) -> int {
	spin := animated()
	desc := os.Process_Desc{command = {"task", "build"}, stdout = os.stdout, stderr = os.stderr, stdin = os.stdin}

	log: ^os.File
	if spin {
		if !ensure_dir(out) {
			return install_fail(fmt.tprintf("cannot create %s", out))
		}

		opened, err := os.create(log_path)
		if err != nil {
			return install_fail(fmt.tprintf("cannot create %s", log_path))
		}

		log = opened
		desc.command = {"task", "build", "QUIET=true"}
		desc.stdout = log
		desc.stderr = log
	}
	defer if log != nil {
		os.close(log)
	}

	process, start_err := os.process_start(desc)
	if start_err != nil {
		return install_fail("could not build KRS")
	}

	frames := SPINNER_FRAMES
	state: os.Process_State
	for tick := 0; ; tick += 1 {
		waited, wait_err := os.process_wait(process, SPINNER_TICK)
		if wait_err == nil {
			state = waited
			break
		}

		if wait_err != .Timeout {
			return install_fail("could not build KRS")
		}

		if received_signal != nil {
			break
		}

		if spin {
			fmt.eprintf("\r\x1b[2K\x1b[31m%s\x1b[0m  Building KRS", frames[tick % len(frames)])
		}
	}

	if spin {
		fmt.eprint("\r\x1b[2K")
	}

	if received_signal != nil {
		// Reap the child, which received the same signal.
		_, _ = os.process_wait(process)
		return EXIT_INTERRUPTED if received_signal == .SIGINT else EXIT_TERMINATED
	}

	if spin {
		replay_log(log_path)
	}

	if state.exit_code != 0 {
		return install_fail("could not build KRS", state.exit_code)
	}
	return EXIT_OK
}

replay_log :: proc(log_path: string) {
	data, err := os.read_entire_file(log_path, context.temp_allocator)
	if err == nil {
		os.write(os.stderr, data)
	}
}

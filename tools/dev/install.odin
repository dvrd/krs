package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

SPINNER_FRAMES :: [?]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
SPINNER_TICK :: 90 * time.Millisecond
EXIT_INTERRUPTED :: 130
EXIT_TERMINATED :: 143

// The column after a step's label and after its duration.
STEP_LABEL_WIDTH :: 32
STEP_TIME_WIDTH :: 7

// Set by the signal handler, read by the step wait loop. A step's child is in
// our process group and receives the signal itself.
received_signal: posix.Signal

on_signal :: proc "c" (sig: posix.Signal) {
	received_signal = sig
}

// How `task install` shows its steps: a spinner on the running step when
// stdout and stderr are terminals, icons when stdout is one, colors unless
// NO_COLOR.
Display :: struct {
	animated: bool,
	icons:    bool,
	colored:  bool,
}

Step :: struct {
	label:   string,
	started: time.Tick,
}

// What the build needs, found by the steps before it.
Build :: struct {
	out:          string,
	version:      string,
	link_flags:   string,
	log_path:     string,
	odin_version: string,
	odin_root:    string,
	skipped:      bool, // nothing changed since the last build
}

display_make :: proc() -> Display {
	terminal := os.get_env("TERM", context.allocator)
	colored := os.get_env("NO_COLOR", context.allocator) == ""
	icons := os.is_tty(os.stdout) && terminal != "dumb"
	animated := icons && os.is_tty(os.stderr) && colored && os.get_env("KRS_NO_ANIMATION", context.allocator) == ""
	return Display{animated = animated, icons = icons, colored = colored}
}

// icon prints a status icon when stdout is a terminal, colored unless NO_COLOR.
icon :: proc(display: Display, color: int, glyph: string, to_stderr: bool) {
	if !display.icons {
		return
	}

	writer := os.to_writer(os.stderr if to_stderr else os.stdout)
	if display.colored {
		fmt.wprintf(writer, "\x1b[%dm%s\x1b[0m  ", color, glyph)
	} else {
		fmt.wprintf(writer, "%s  ", glyph)
	}
}

install_fail :: proc(display: Display, message: string, code := EXIT_FAILED) -> int {
	assert(code != EXIT_OK)

	icon(display, 31, "✕", true)
	fmt.eprintfln("krs: %s", message)
	return code
}

install :: proc() -> int {
	started := time.tick_now()
	display := display_make()
	bin_dir := os.get_env("KRS_INSTALL_DIR", context.allocator)
	if bin_dir == "" {
		bin_dir = fmt.tprintf("%s/.local/bin", os.get_env("HOME", context.allocator))
	}

	destination := fmt.tprintf("%s/krs", bin_dir)
	if os.is_dir(destination) {
		return install_fail(display, fmt.tprintf("cannot replace directory %s", destination))
	}

	build, code := build_begin(display)
	if code != EXIT_OK {
		return code
	}
	defer os.remove(build.log_path)

	if code = build_krs(display, &build); code != EXIT_OK {
		return code
	}

	if code = place(display, build, bin_dir, destination); code != EXIT_OK {
		return code
	}

	icon(display, 32, "✓", false)
	fmt.printfln("krs: installed %s (%s) in %s", destination, build.version, duration_text(time.tick_since(started)))
	return EXIT_OK
}

// prepare reports the compiler and libgit2 and reads the version: quick
// queries, so no spinner. The toolchain task has already checked them.
prepare :: proc(display: Display, build: ^Build) -> int {
	step := step_begin(display, "Checking the Odin compiler")
	odin_out, odin_started := capture({"odin", "version"})
	if !odin_started || odin_out.code != 0 {
		step_failed(display, step, "")
		return install_fail(display, "cannot run odin version")
	}

	actual := strings.trim_space(strings.trim_prefix(strings.trim_space(odin_out.text), "odin version "))
	expected_data, _ := os.read_entire_file("ODIN_VERSION", context.allocator)
	expected := strings.trim_space(string(expected_data))
	agreement := "as in ODIN_VERSION" if toolchain_matches(actual, expected) else fmt.tprintf("ODIN_VERSION has %s", expected)
	step_done(display, step, fmt.tprintf("%s, %s", actual, agreement))
	build.odin_version = actual
	build.odin_root = os.get_env("ODIN_ROOT", context.allocator)
	if build.odin_root == "" {
		build.odin_root = strings.trim_space(capture_text({"odin", "root"}))
	}
	build.odin_root = strings.trim_right(build.odin_root, "/")

	step = step_begin(display, "Finding libgit2")
	libdir, lib_started := capture({"pkg-config", "--variable=libdir", "libgit2"})
	if !lib_started || libdir.code != 0 {
		step_failed(display, step, "")
		return install_fail(display, "pkg-config cannot find libgit2")
	}

	directory := strings.trim_space(libdir.text)
	build.link_flags = link_flags(directory, ODIN_OS == .Darwin)
	step_done(display, step, fmt.tprintf("%s in %s", strings.trim_space(capture_text({"pkg-config", "--modversion", "libgit2"})), directory))

	step = step_begin(display, "Reading the version")
	source := "from Git tags"
	build.version = os.get_env("KRS_VERSION", context.allocator)
	if build.version != "" {
		source = "from KRS_VERSION"
	} else {
		described, _ := capture({"git", "describe", "--tags", "--match", "v[0-9]*", "--dirty"})
		build.version = strings.trim_space(described.text) if described.code == 0 else ""
	}

	if build.version == "" {
		build.version, source = "dev", "no release tag found"
	}
	step_done(display, step, fmt.tprintf("%s, %s", build.version, source))
	return EXIT_OK
}

// link_flags passes libgit2's directory to the linker, with an rpath where the
// loader does not search it by itself.
link_flags :: proc(directory: string, darwin: bool) -> string {
	assert(directory != "")

	if darwin {
		return fmt.tprintf("-L\"%s\"", directory)
	}
	return fmt.tprintf("-L\"%s\" -Wl,-rpath,%s", directory, directory)
}

// compile type-checks first, which fails fast and names the code's errors,
// then builds the optimized binary. Both report the compiler's own timings.
// The flags match the odin task in Taskfile.yml; change both together.
compile :: proc(display: Display, build: Build) -> int {
	check := step_begin(display, "Type-checking cmd/krs and src")
	output, code := step_command(display, check, {"odin", "check", "cmd/krs", "-vet", "-show-timings"}, build.log_path)
	if signal_code, stopped := interrupted(); stopped {
		step_clear(display)
		return signal_code
	}

	if code != 0 {
		step_failed(display, check, output)
		return install_fail(display, "KRS does not type-check", code)
	}
	step_done(display, check, timings_summary(output, {"parse files", "type check"}))

	binary := fmt.tprintf("%s/krs", build.out)
	optimize := step_begin(display, "Compiling with LLVM (-o:speed)")
	command := []string {
		"odin", "build", "cmd/krs", fmt.tprintf("-out:%s", binary), "-vet", "-o:speed", "-show-timings",
		fmt.tprintf("-define:KRS_VERSION=%s", build.version), fmt.tprintf("-extra-linker-flags:%s", build.link_flags),
	}
	output, code = step_command(display, optimize, command, build.log_path)
	if signal_code, stopped := interrupted(); stopped {
		step_clear(display)
		return signal_code
	}

	if code != 0 {
		step_failed(display, optimize, output)
		return install_fail(display, "could not build KRS", code)
	}
	step_done(display, optimize, timings_summary(output, {"LLVM API Code Gen", "ld-link"}))
	return EXIT_OK
}

// place copies the binary next to its destination, then renames it over the
// old one, so a running krs never sees a half-written file.
place :: proc(display: Display, build: Build, bin_dir, destination: string) -> int {
	step := step_begin(display, "Installing the binary")
	if !ensure_dir(bin_dir) {
		step_failed(display, step, "")
		return install_fail(display, fmt.tprintf("cannot create %s", bin_dir))
	}

	if signal_code, stopped := interrupted(); stopped {
		return signal_code
	}

	staged := fmt.tprintf("%s/.krs.%d", bin_dir, os.get_pid())
	defer os.remove(staged)
	if err := os.copy_file(staged, fmt.tprintf("%s/krs", build.out)); err != nil {
		step_failed(display, step, "")
		return install_fail(display, fmt.tprintf("cannot stage %s", destination))
	}

	mode := posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}
	if posix.chmod(strings.clone_to_cstring(staged, context.temp_allocator), mode) != .OK {
		step_failed(display, step, "")
		return install_fail(display, fmt.tprintf("cannot copy KRS to %s", destination))
	}

	if signal_code, stopped := interrupted(); stopped {
		return signal_code
	}

	if err := os.rename(staged, destination); err != nil {
		step_failed(display, step, "")
		return install_fail(display, fmt.tprintf("cannot replace %s", destination))
	}
	step_done(display, step, fmt.tprintf("to %s", bin_dir))
	return EXIT_OK
}

step_begin :: proc(display: Display, label: string) -> Step {
	assert(label != "")
	assert(len(label) <= STEP_LABEL_WIDTH)

	step := Step{label = label, started = time.tick_now()}
	if display.animated {
		step_spin(display, step, 0)
	}
	return step
}

step_spin :: proc(display: Display, step: Step, tick: int) {
	assert(display.animated)

	frames := SPINNER_FRAMES
	elapsed := time.tick_since(step.started)
	fmt.eprintf("\r\x1b[2K\x1b[31m%s\x1b[0m  %s", frames[tick % len(frames)], step.label)
	if elapsed >= time.Second {
		fmt.eprintf("  \x1b[2m%s\x1b[0m", duration_text(elapsed))
	}
}

step_clear :: proc(display: Display) {
	if display.animated {
		fmt.eprint("\r\x1b[2K")
	}
}

step_done :: proc(display: Display, step: Step, detail: string) {
	step_clear(display)
	icon(display, 32, "✓", false)
	elapsed := duration_text(time.tick_since(step.started))
	if display.colored && display.icons {
		fmt.printfln("%-*s  %*s  \x1b[2m%s\x1b[0m", STEP_LABEL_WIDTH, step.label, STEP_TIME_WIDTH, elapsed, detail)
	} else {
		fmt.printfln("krs: %-*s  %*s  %s", STEP_LABEL_WIDTH, step.label, STEP_TIME_WIDTH, elapsed, detail)
	}
}

// step_failed names the step and shows what its command printed.
step_failed :: proc(display: Display, step: Step, output: string) {
	step_clear(display)
	icon(display, 31, "✕", true)
	fmt.eprintfln("krs: %s failed", step.label)
	if output != "" {
		fmt.eprint(output)
	}
}

// step_command runs `command` with its output in the log, spinning while it
// runs. It returns the output and the exit code; -1 when it could not start.
step_command :: proc(display: Display, step: Step, command: []string, log_path: string) -> (output: string, code: int) {
	assert(len(command) > 0)

	log, create_err := os.create(log_path)
	if create_err != nil {
		return fmt.tprintf("cannot create %s\n", log_path), -1
	}

	process, start_err := os.process_start({command = command, stdout = log, stderr = log, stdin = os.stdin})
	if start_err != nil {
		os.close(log)
		return fmt.tprintf("cannot run %s: %v\n", command[0], start_err), -1
	}

	code = -1
	for tick := 1; ; tick += 1 {
		state, wait_err := os.process_wait(process, SPINNER_TICK)
		if wait_err == nil {
			code = state.exit_code
			break
		}

		if wait_err != .Timeout || received_signal != nil {
			// Reap the child, which received the same signal.
			_, _ = os.process_wait(process)
			break
		}

		if display.animated {
			step_spin(display, step, tick)
		}
	}
	os.close(log)

	data, _ := os.read_entire_file(log_path, context.allocator)
	return string(data), code
}

// timings_summary picks `phases` out of the compiler's -show-timings table,
// for example "parse files - 28.824 ms - 0.12%", and names them plainly.
timings_summary :: proc(output: string, phases: []string) -> string {
	parts: [dynamic]string
	for phase in phases {
		for line in strings.split_lines(output, context.temp_allocator) {
			fields := strings.split(line, " - ", context.temp_allocator)
			if len(fields) != 3 || strings.trim_space(fields[0]) != phase {
				continue
			}

			milliseconds, parsed := strconv.parse_f64(strings.trim_space(strings.trim_suffix(strings.trim_space(fields[1]), "ms")))
			if parsed {
				append(&parts, fmt.tprintf("%s %s", phase_name(phase), duration_text(time.Duration(milliseconds * f64(time.Millisecond)))))
			}
			break
		}
	}
	return strings.join(parts[:], ", ", context.temp_allocator)
}

phase_name :: proc(phase: string) -> string {
	switch phase {
	case "parse files":
		return "parsing"
	case "type check":
		return "type checking"
	case "LLVM API Code Gen":
		return "code generation"
	case "ld-link":
		return "linking"
	}
	return phase
}

// duration_text: "45ms" below a second, then "1.2s", then "1m05s".
duration_text :: proc(duration: time.Duration) -> string {
	assert(duration >= 0)

	if duration < time.Second {
		return fmt.tprintf("%dms", i64(duration / time.Millisecond))
	}

	if duration < time.Minute {
		return fmt.tprintf("%.1fs", time.duration_seconds(duration))
	}

	seconds := i64(duration / time.Second)
	return fmt.tprintf("%dm%02ds", seconds / 60, seconds % 60)
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

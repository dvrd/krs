package krs

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// `krs update -u --doctor`: upgrade, run the project's tests, and keep only
// the upgrades that pass. Every revert replays a snapshot of the lockfile
// through the normal journalled transaction.

DOCTOR_TEST_DEFAULT :: "odin test ."
DOCTOR_TEST_VENDOR :: "odin test . -collection:shared=vendor"
DOCTOR_OUTPUT_LINES :: 20 // lines of test output shown for a failure
DOCTOR_TIMEOUT :: 30 * 60 // seconds a doctor command may run without --doctor-timeout
DOCTOR_TIMEOUT_LIMIT :: 24 * 3600

Doctor_Run :: struct {
	passed: bool,
	output: string, // stdout and stderr, the last DOCTOR_OUTPUT_LINES lines
}

// One upgrade tried alone, with the test output when it broke the tests.
Doctor_Verdict :: struct {
	candidate: Update_Candidate,
	output:    string,
}

// The last DOCTOR_OUTPUT_LINES lines of `text`, without trailing blank lines.
doctor_tail :: proc(text: string) -> string {
	trimmed := strings.trim_right(text, "\r\n")
	start := len(trimmed)
	for _ in 0 ..< DOCTOR_OUTPUT_LINES {
		newline := strings.last_index_byte(trimmed[:start], '\n')
		if newline < 0 {
			return trimmed
		}
		start = newline
	}

	assert(start < len(trimmed))
	return trimmed[start + 1:]
}

// Seconds in a --doctor-timeout value: digits followed by s, m or h, from
// 1s to 24h. Rejects everything else.
doctor_timeout_seconds :: proc(text: string) -> (seconds: i64, ok: bool) {
	if len(text) < 2 {
		return 0, false
	}

	unit: i64
	switch text[len(text) - 1] {
	case 's':
		unit = 1
	case 'm':
		unit = 60
	case 'h':
		unit = 3600
	case:
		return 0, false
	}

	// At most six digits, so the multiplication below cannot overflow.
	digits := text[:len(text) - 1]
	if len(digits) > 6 {
		return 0, false
	}

	// Checked here because parse_i64 would accept a sign, 0x and underscores.
	for character in transmute([]byte)digits {
		if character < '0' || character > '9' {
			return 0, false
		}
	}

	number, parsed := strconv.parse_i64(digits, 10)
	if !parsed || number == 0 {
		return 0, false
	}

	seconds = number * unit
	if seconds > DOCTOR_TIMEOUT_LIMIT {
		return 0, false
	}
	return seconds, true
}

// Runs `command` with `/bin/sh -c` in the project directory, with
// ODIN_ROOT set to `root`. `ok` is false when the process could not run at
// all (not a test failure). A command still running after `seconds` is
// killed and counts as failed; only /bin/sh is killed, not its children.
doctor_command :: proc(env: ^Env, root, command: string, seconds: i64) -> (run: Doctor_Run, ok: bool) {
	assert(root != "")
	assert(command != "")
	assert(seconds > 0 && seconds <= DOCTOR_TIMEOUT_LIMIT)

	environment, _ := os.environ(context.temp_allocator)
	child_environment := make([dynamic]string, context.temp_allocator)
	for entry in environment {
		if strings.has_prefix(entry, "ODIN_ROOT=") {
			continue
		}
		append(&child_environment, entry)
	}
	append(&child_environment, fmt.tprintf("ODIN_ROOT=%s", root))

	// One file for both streams keeps them interleaved and lets the child
	// write without krs polling pipes.
	output, create_err := os.create_temp_file("", "krs-doctor-*")
	if create_err != nil {
		return run, fail(env, "cannot run %s: %v", command, create_err)
	}

	output_path := strings.clone(os.name(output), context.temp_allocator)
	defer os.remove(output_path)
	defer os.close(output)

	arguments := []string{"/bin/sh", "-c", command}
	progress_start(env, "Running tests")
	process, start_err := os.process_start(
		{working_dir = env.project, command = arguments, env = child_environment[:], stdout = output, stderr = output},
	)
	if start_err != nil {
		progress_stop(env)
		return run, fail(env, "cannot run %s: %v", command, start_err)
	}

	process_state, wait_err := os.process_wait(process, time.Duration(seconds) * time.Second)
	if wait_err == os.General_Error.Timeout {
		progress_stop(env)
		if kill_err := os.process_kill(process); kill_err != nil {
			warn(env, "cannot stop the test command: %v", kill_err)
		}

		_, _ = os.process_wait(process)
		run.passed = false
		run.output = fmt.aprintf("timed out after %ds", seconds)
		return run, true
	}

	progress_stop(env)
	if wait_err != nil {
		return run, fail(env, "cannot run %s: %v", command, wait_err)
	}

	data, read_err := os.read_entire_file(output_path, context.temp_allocator)
	if read_err != nil {
		return run, fail(env, "cannot read the output of %s: %v", command, read_err)
	}

	run.passed = process_state.exited && process_state.exit_code == 0
	run.output = strings.clone(doctor_tail(string(data)))
	return run, true
}

// The test command: --doctor-test, or the Odin test runner on the collection
// this project builds against.
doctor_test_command :: proc(options: Options, vendored: bool) -> string {
	if options.update.doctor_test != "" {
		return options.update.doctor_test
	}

	return DOCTOR_TEST_VENDOR if vendored else DOCTOR_TEST_DEFAULT
}

// Runs the install command (when set), then the test command.
doctor_check :: proc(env: ^Env, options: Options, root: string, vendored: bool) -> (run: Doctor_Run, ok: bool) {
	seconds := options.update.doctor_timeout if options.update.doctor_timeout > 0 else DOCTOR_TIMEOUT
	if options.update.doctor_install != "" {
		installed := doctor_command(env, root, options.update.doctor_install, seconds) or_return
		if !installed.passed {
			return installed, true
		}
	}

	return doctor_command(env, root, doctor_test_command(options, vendored), seconds)
}

// A copy of the project's lockfile records and the file's bytes, taken
// before a change so the change can be undone.
doctor_snapshot :: proc(env: ^Env, options: Options) -> (snapshot: Packages_File, bytes: []byte, ok: bool) {
	state := state_open(env, options) or_return
	snapshot.format = state.packages.format
	append(&snapshot.packages, ..state.packages.packages[:])
	state_close(state)

	path := path_join(env.project, PACKAGES_PATH)
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return snapshot, nil, fail(env, "cannot read %s: %v", path, err)
	}
	return snapshot, data, true
}

// Brings the project's lockfile and installed releases back to `snapshot`,
// through the normal journalled transaction, then checks the result.
doctor_restore :: proc(env: ^Env, options: Options, snapshot: Packages_File, snapshot_bytes: []byte) -> bool {
	assert(options.yes)

	state := state_open(env, options) or_return
	for record in snapshot.packages {
		current := packages_find(&state.packages, record.name)
		if current == nil || current.tag != record.tag || current.commit != record.commit || current.source != record.source {
			// .Update, never .Restore: a restore would replace a link.
			append(
				&state.queue,
				Request {
					name = record.name,
					tag = record.tag,
					commit = record.commit,
					source = record.source,
					by = "krs update --doctor",
					kind = .Update,
					recorded = true,
					source_trusted = true,
				},
			)
		}
	}

	applied := plan_discover(state) && plan_drain(state) && plan_apply(state, .Record)
	state_close(state)
	if !applied {
		return false
	}

	// plan_apply does not update state.packages: read the result afresh.
	check := state_open(env, options) or_return
	expected := snapshot
	equal := packages_equal(&check.packages, &expected)
	missing_name, missing_tag := "", ""
	extra_name := ""
	if !equal {
		for record in expected.packages {
			current := packages_find(&check.packages, record.name)
			if current == nil || current.tag != record.tag || current.commit != record.commit ||
			   current.hash != record.hash || current.pinned != record.pinned ||
			   source_identity(current.source) != source_identity(record.source) {
				missing_name, missing_tag = record.name, record.tag
				break
			}
		}

		for record in check.packages.packages {
			if missing_name == "" && packages_find(&expected, record.name) == nil {
				extra_name = record.name
				break
			}
		}
	}
	state_close(check)

	if !equal && missing_name != "" {
		return fail(env, "%s was not restored to %s", missing_name, missing_tag)
	}

	if !equal {
		return fail(env, "%s is still recorded after restoring the previous versions", extra_name)
	}

	path := path_join(env.project, PACKAGES_PATH)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || string(data) != string(snapshot_bytes) {
		return fail(env, "%s was not restored byte for byte", PACKAGES_PATH)
	}
	return true
}

// Prints what was kept and what broke the tests.
doctor_report :: proc(env: ^Env, kept, broken: []Doctor_Verdict) {
	for verdict in kept {
		success(env, "%s %s -> %s passes the tests", verdict.candidate.name, verdict.candidate.current, verdict.candidate.chosen)
	}

	for verdict in broken {
		candidate := verdict.candidate
		warn(env, "%s %s -> %s breaks the tests; kept %s", candidate.name, candidate.current, candidate.chosen, candidate.current)
		for line in strings.split_lines(verdict.output, context.temp_allocator) {
			say(env, "    %s", line)
		}
	}
}

// The command that moves every unpinned, unlinked package of `snapshot` back
// to its recorded release. It does not remove packages a trial added.
doctor_recovery :: proc(snapshot: Packages_File, linked: []string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "krs update -u --yes")
	named := 0
	for record in snapshot.packages {
		// update -u never moves a pinned package and refuses a linked one.
		if record.pinned || slice.contains(linked, record.name) {
			continue
		}

		fmt.sbprintf(&builder, " %s@%s", record.name, record.tag)
		named += 1
	}

	if named == 0 {
		return "krs install --yes"
	}
	return strings.to_string(builder)
}

// After a failed revert: the report so far, then how to get back by hand.
doctor_restore_failed :: proc(env: ^Env, linked: []string, snapshot: Packages_File, kept, broken: []Doctor_Verdict) -> bool {
	doctor_report(env, kept, broken)
	fail(env, "could not restore the previous versions; restore with: %s", doctor_recovery(snapshot, linked))
	for record in snapshot.packages {
		say(env, "    %s %s", record.name, record.tag)
	}
	return false
}

// `krs update -u --doctor`.
command_update_doctor :: proc(env: ^Env, options: Options, names: []string) -> bool {
	assert(options.update.doctor && options.update.upgrade)
	assert(!options.update.global && !options.update.pin && !options.update.interactive)
	assert(options.update.install != .Never)

	query := update_query_make(env, options, names) or_return
	defer update_query_destroy(query)

	// Collect. Every round opens and closes its own state: no lock is held
	// while the tests run.
	state := state_open(env, options) or_return
	if !state.vendored {
		for record in state.packages.packages {
			installed := manifest_find(&state.manifest, record.name)
			if record.pinned && installed != nil && (installed.linked != "" || installed.tag != record.tag) {
				fail(env, "%s is pinned at %s but %s holds another version; run krs update -u (or krs vendor) first", record.name, record.tag, state.shared)
				state_close(state)
				return false
			}
		}
	}

	// The baseline tests what the collection holds, and a revert restores what
	// the lockfile records: they must be the same version. vendor/ can lag
	// behind the lockfile too.
	for record in state.packages.packages {
		if record.pinned {
			continue
		}

		installed := manifest_find(&state.manifest, record.name)
		if installed != nil && installed.linked == "" && installed.tag != record.tag {
			fail(env, "%s: this project records %s but %s holds %s; run %s first so the tests see what is recorded", record.name, record.tag, state.shared, installed.tag, "krs install")
			state_close(state)
			return false
		}
	}

	found, found_ok := update_candidates(state, query)
	if !found_ok {
		state_close(state)
		return false
	}

	candidates := make([dynamic]Update_Candidate, context.temp_allocator)
	for candidate in found {
		if candidate.pinned || !candidate_upgrades(candidate) {
			continue
		}

		previous := packages_find(&state.packages, candidate.name)
		assert(previous != nil)
		append(&candidates, candidate)
	}

	snapshot := Packages_File{format = state.packages.format}
	append(&snapshot.packages, ..state.packages.packages[:])
	linked := make([dynamic]string, context.temp_allocator)
	for record in state.manifest.packages {
		if record.linked != "" {
			append(&linked, strings.clone(record.name, context.temp_allocator))
		}
	}
	vendored := state.vendored
	root := state.scope.root
	shared := state.shared
	state_close(state)

	if len(candidates) == 0 {
		success(env, "every package of this project is at its target")
		return true
	}

	// Consent: once, before anything changes.
	for candidate in candidates {
		compatibility := Version_Compatibility.Breaking
		if current, current_ok := parse_tag(candidate.current); current_ok {
			chosen, _ := parse_tag(candidate.chosen)
			compatibility = version_compatibility(current, chosen)
		}
		say_version_change(env, candidate.name, candidate.current, candidate.chosen, compatibility)
	}

	if !vendored {
		warn(env, "--doctor installs trial versions into %s; every project on this Odin root sees them until it finishes", shared)
	}

	if !options.yes {
		if !env.interactive {
			return fail(env, "confirmation is needed: run in a terminal, or pass --yes")
		}

		if !ask_yes(env, "Proceed?") {
			return fail(env, "nothing was changed")
		}
	}

	yes_options := options
	yes_options.yes = true

	// Before the baseline: its install command may change the lockfile.
	path := path_join(env.project, PACKAGES_PATH)
	before_bytes, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		return fail(env, "cannot read %s: %v", path, read_err)
	}

	// Baseline: the tests must pass before anything changes.
	info(env, "tests: %s", doctor_test_command(yes_options, vendored))
	note(env, "if this run stops early, restore with: %s", doctor_recovery(snapshot, linked[:]))
	baseline := doctor_check(env, yes_options, root, vendored) or_return
	if !baseline.passed {
		fail(env, "the tests fail before upgrading; --doctor needs a passing baseline")
		for line in strings.split_lines(baseline.output, context.temp_allocator) {
			say(env, "    %s", line)
		}
		return false
	}

	// All at once.
	{
		all_state := state_open(env, yes_options) or_return
		applied := update_apply(all_state, candidates[:], yes_options)
		state_close(all_state)
		if !applied {
			return false
		}
	}

	kept := make([dynamic]Doctor_Verdict, context.temp_allocator)
	broken := make([dynamic]Doctor_Verdict, context.temp_allocator)
	together, together_ran := doctor_check(env, yes_options, root, vendored)
	if !together_ran {
		if !doctor_restore(env, yes_options, snapshot, before_bytes) {
			return doctor_restore_failed(env, linked[:], snapshot, kept[:], broken[:])
		}
		return false
	}

	if together.passed {
		success(env, "%d upgrade(s) pass the tests", len(candidates))
		return true
	}

	warn(env, "the upgrades together break the tests; trying each one alone")
	if !doctor_restore(env, yes_options, snapshot, before_bytes) {
		return doctor_restore_failed(env, linked[:], snapshot, kept[:], broken[:])
	}

	// One at a time, in list order.
	for candidate in candidates {
		round_snapshot, round_bytes := doctor_snapshot(env, yes_options) or_return

		round_state := state_open(env, yes_options) or_return
		applied := update_apply(round_state, {candidate}, yes_options)
		state_close(round_state)
		if !applied {
			append(&broken, Doctor_Verdict{candidate = candidate, output = "could not install"})
			continue
		}

		alone, alone_ran := doctor_check(env, yes_options, root, vendored)
		if !alone_ran {
			if !doctor_restore(env, yes_options, round_snapshot, round_bytes) {
				return doctor_restore_failed(env, linked[:], round_snapshot, kept[:], broken[:])
			}
			return false
		}

		if alone.passed {
			append(&kept, Doctor_Verdict{candidate = candidate})
			continue
		}

		append(&broken, Doctor_Verdict{candidate = candidate, output = alone.output})
		if !doctor_restore(env, yes_options, round_snapshot, round_bytes) {
			return doctor_restore_failed(env, linked[:], round_snapshot, kept[:], broken[:])
		}
	}

	doctor_report(env, kept[:], broken[:])
	return len(broken) == 0
}

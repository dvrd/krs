package unit

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import krs "../../src"
import "../fixtures"

DOCTOR_TEST_PATH :: "PATH=/usr/bin:/bin"

// Runs `script` with /bin/sh in `directory`, waits up to `seconds`, and
// returns what the child wrote.
doctor_run :: proc(
	t: ^testing.T,
	fixture: ^fixtures.Fixture,
	directory, script: string,
	environment: []string,
	seconds: i64 = 5,
) -> (
	exited: bool,
	exit_code: int,
	timed_out: bool,
	output: string,
) {
	path := krs.path_join(fixture.base, "doctor.log")
	file, create_err := os.create(path)
	if !testing.expect_value(t, create_err, nil) {
		return
	}
	defer os.close(file)

	process, spawn_err := krs.doctor_spawn(directory, {"/bin/sh", "-c", script}, environment, file)
	if !testing.expect_value(t, spawn_err, nil) {
		return
	}

	wait_err: os.Error
	exited, exit_code, timed_out, wait_err = krs.doctor_wait(process, seconds)
	testing.expect_value(t, wait_err, nil)
	return exited, exit_code, timed_out, fixtures.read_file(path)
}

@(test)
doctor_wait_reports_the_exit_code :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	exited, code, timed_out, _ := doctor_run(t, &fixture, fixture.project, "exit 3", {DOCTOR_TEST_PATH})
	testing.expect(t, exited)
	testing.expect_value(t, code, 3)
	testing.expect(t, !timed_out)

	exited, code, timed_out, _ = doctor_run(t, &fixture, fixture.project, "true", {DOCTOR_TEST_PATH})
	testing.expect(t, exited)
	testing.expect_value(t, code, 0)
	testing.expect(t, !timed_out)
}

@(test)
doctor_spawn_uses_the_directory_environment_and_output :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	directory := krs.path_join(fixture.base, "doctor-workdir")
	testing.expect_value(t, os.make_directory_all(directory), nil)
	script := `echo to-stdout; echo to-stderr >&2; pwd -P; printf '%s\n' "$KRS_UNIT_NAME" "${HOME-no-home}"; read line || echo no-input`
	exited, code, _, output := doctor_run(t, &fixture, directory, script, {DOCTOR_TEST_PATH, "KRS_UNIT_NAME=from-test"})
	testing.expect(t, exited)
	testing.expect_value(t, code, 0)

	lines := strings.split_lines(strings.trim_space(output))
	if testing.expectf(t, len(lines) == 6, "unexpected output: %q", output) {
		testing.expect_value(t, lines[0], "to-stdout")
		testing.expect_value(t, lines[1], "to-stderr")
		testing.expect(t, strings.has_suffix(lines[2], "/doctor-workdir"), lines[2])
		testing.expect_value(t, lines[3], "from-test")
		testing.expect_value(t, lines[4], "no-home")
		testing.expect_value(t, lines[5], "no-input")
	}
}

@(test)
doctor_wait_times_out_and_stops_the_whole_group :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	// A background child would leave the marker after 4 s if it outlived the
	// timeout.
	marker := krs.path_join(fixture.base, "marker")
	script := strings.concatenate({"(sleep 4; touch '", marker, "') & sleep 10"})
	started := time.now()
	exited, code, timed_out, _ := doctor_run(t, &fixture, fixture.project, script, {DOCTOR_TEST_PATH}, 1)
	elapsed := time.since(started)
	testing.expect(t, timed_out)
	testing.expect(t, !exited)
	testing.expect_value(t, code, 0)
	testing.expectf(t, elapsed < 3 * time.Second, "the timeout took %v", elapsed)

	time.sleep(5 * time.Second - elapsed)
	testing.expectf(t, !os.exists(marker), "a child outlived the timeout and wrote %s", marker)
}

@(test)
doctor_spawn_reports_a_missing_directory_or_program :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	path := krs.path_join(fixture.base, "doctor.log")
	file, create_err := os.create(path)
	if !testing.expect_value(t, create_err, nil) {
		return
	}
	defer os.close(file)

	missing := krs.path_join(fixture.base, "missing")
	process, err := krs.doctor_spawn(missing, {"/bin/sh", "-c", "exit 0"}, {DOCTOR_TEST_PATH}, file)
	testing.expect(t, err != nil)
	testing.expect_value(t, process.pid, 0)

	process, err = krs.doctor_spawn(fixture.project, {krs.path_join(fixture.base, "no-such-program")}, {DOCTOR_TEST_PATH}, file)
	testing.expect(t, err != nil)
	testing.expect_value(t, process.pid, 0)
	testing.expect_value(t, fixtures.read_file(path), "")
}

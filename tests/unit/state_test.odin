package unit

import "core:io"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

// One scripted read: bytes to hand back, or an error to return.
Answer_Step :: struct {
	bytes: string,
	error: io.Error,
}

Answer_Reader :: struct {
	steps: [dynamic]Answer_Step,
	next:  int,
}

answer_reader_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	reader := cast(^Answer_Reader)data
	if mode != .Read {
		return 0, .Empty
	}

	if reader.next >= len(reader.steps) {
		return 0, .EOF
	}

	step := reader.steps[reader.next]
	reader.next += 1
	if step.error != nil {
		return 0, step.error
	}

	copy(p, step.bytes)
	return i64(len(step.bytes)), nil
}

// One byte per step, because ask_line reads one byte per call.
script_bytes :: proc(reader: ^Answer_Reader, text: string) {
	for index in 0 ..< len(text) {
		append(&reader.steps, Answer_Step{bytes = text[index:index + 1]})
	}
}

answering :: proc(reader: ^Answer_Reader, out, errors: ^strings.Builder) -> krs.Env {
	return krs.Env {
		out         = strings.to_writer(out),
		err         = strings.to_writer(errors),
		input       = io.Stream{procedure = answer_reader_proc, data = reader},
		interactive = true,
	}
}

@(test)
ask_line_reads_one_trimmed_line_and_reports_the_end :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	reader: Answer_Reader
	script_bytes(&reader, "  first  \nsecond")
	out := strings.builder_make()
	errors := strings.builder_make()
	env := answering(&reader, &out, &errors)

	line, ended := krs.ask_line_ended(&env)
	testing.expect_value(t, line, "first")
	testing.expect(t, !ended)

	line, ended = krs.ask_line_ended(&env)
	testing.expect_value(t, line, "second")
	testing.expect(t, ended)

	testing.expect_value(t, krs.ask_line(&env), "")
}

@(test)
ask_line_ends_on_a_read_error :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	reader: Answer_Reader
	append(&reader.steps, Answer_Step{bytes = "y"})
	append(&reader.steps, Answer_Step{error = .Unexpected_EOF})
	append(&reader.steps, Answer_Step{bytes = "\n"})
	out := strings.builder_make()
	errors := strings.builder_make()
	env := answering(&reader, &out, &errors)

	line, ended := krs.ask_line_ended(&env)
	testing.expect_value(t, line, "y")
	testing.expect(t, ended)
}

@(test)
ask_yes_accepts_only_yes_in_any_case :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	answers := []struct {
		text:     string,
		expected: bool,
	}{{"y\n", true}, {"YES\n", true}, {" Yes \n", true}, {"n\n", false}, {"\n", false}, {"yep\n", false}, {"", false}}
	for answer in answers {
		reader: Answer_Reader
		script_bytes(&reader, answer.text)
		out := strings.builder_make()
		errors := strings.builder_make()
		env := answering(&reader, &out, &errors)

		testing.expectf(t, krs.ask_yes(&env, "Proceed?") == answer.expected, "answer %q", answer.text)
		testing.expect(t, strings.contains(strings.to_string(out), "Proceed? [y/N] "))
	}
}

@(test)
json_record_problem_names_bad_json_and_newer_formats :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	file: krs.Packages_File
	testing.expect_value(t, krs.json_record_problem(transmute([]byte)string("{\"format\": 1, \"packages\": []}"), &file), "")
	testing.expect_value(t, file.format, 1)

	testing.expect_value(t, krs.json_record_problem(transmute([]byte)string("not json"), &file), "is not valid JSON")
	testing.expect_value(t, krs.json_record_problem(transmute([]byte)string("{\"format\": \"one\"}"), &file), "is not valid JSON")
	testing.expect_value(t, krs.json_record_problem(transmute([]byte)string("{\"format\": 2}"), &file), "was written by a newer krs (format 2)")
}

@(test)
load_packages_reports_missing_invalid_and_valid_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	failure := strings.builder_make()
	env := krs.Env {
		project = fixture.project,
		home    = fixture.home,
		err     = strings.to_writer(&failure),
	}

	// A missing file is an empty lockfile, not an error.
	file, ok := krs.load_packages(&env)
	testing.expect(t, ok)
	testing.expect_value(t, len(file.packages), 0)
	testing.expect_value(t, file.format, krs.FORMAT)

	path := krs.path_join(fixture.project, krs.PACKAGES_PATH)
	fixtures.write_file(t, path, "{broken")
	_, ok = krs.load_packages(&env)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(strings.to_string(failure), "is not valid JSON"))

	fixtures.write_file(t, path, "{\"format\": 1, \"packages\": [{\"name\": \"beta\", \"source\": \"local\", \"tag\": \"v0.1.0\", \"commit\": \"abc\", \"hash\": \"h\", \"pinned\": true}]}")
	file, ok = krs.load_packages(&env)
	testing.expect(t, ok)
	testing.expect_value(t, len(file.packages), 1)
	testing.expect_value(t, file.packages[0].name, "beta")
	testing.expect(t, file.packages[0].pinned)
}

@(test)
load_json_refuses_a_directory_and_a_missing_manifest_is_empty :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	failure := strings.builder_make()
	env := krs.Env {
		project = fixture.project,
		home    = fixture.home,
		err     = strings.to_writer(&failure),
	}

	manifest, ok := krs.load_manifest(&env, fixture.shared)
	testing.expect(t, ok)
	testing.expect_value(t, len(manifest.packages), 0)

	directory := krs.path_join(fixture.base, "directory.json")
	os.make_directory_all(directory)
	value: krs.Config
	found: bool
	found, ok = krs.load_json(&env, directory, &value)
	testing.expect(t, !ok)
	testing.expect(t, !found)
	testing.expect(t, strings.contains(strings.to_string(failure), "cannot read"))

	found, ok = krs.load_json(&env, krs.path_join(fixture.base, "absent.json"), &value)
	testing.expect(t, ok)
	testing.expect(t, !found)
}

@(test)
load_config_resolves_source_directories :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	out := strings.builder_make()
	failure := strings.builder_make()
	env := krs.Env {
		project = fixture.project,
		home    = fixture.home,
		out     = strings.to_writer(&out),
		err     = strings.to_writer(&failure),
	}

	fixtures.write_file(
		t,
		krs.path_join(fixture.home, krs.CONFIG_PATH),
		"{\"format\": 1, \"source_directories\": [\"~/libs/\", \"relative\", \"/absolute\"], \"libs\": {\"kessel\": {\"source\": \"github\", \"target\": \"dvrd/kessel\"}}}",
	)
	config, ok := krs.load_config(&env)
	testing.expect(t, ok)
	testing.expect_value(t, len(config.source_directories), 3)
	testing.expect_value(t, config.source_directories[0], krs.path_join(fixture.home, "libs"))
	testing.expect_value(t, config.source_directories[1], krs.path_join(fixture.project, "relative"))
	testing.expect_value(t, config.source_directories[2], "/absolute")
	testing.expect_value(t, config.libs["kessel"].target, "dvrd/kessel")

	fixtures.write_file(t, krs.path_join(fixture.home, krs.CONFIG_PATH), "{\"format\": 1, \"source_directories\": [\"\"]}")
	_, ok = krs.load_config(&env)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(strings.to_string(failure), "contains an empty source directory"))

	nowhere := krs.Env{err = strings.to_writer(&failure)}
	_, ok = krs.load_config(&nowhere)
	testing.expect(t, !ok)
}

@(test)
records_are_found_replaced_and_removed_by_name :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	packages: krs.Packages_File
	append(&packages.packages, krs.Package_Record{name = "alpha", tag = "v0.1.0"})
	append(&packages.packages, krs.Package_Record{name = "beta", tag = "v0.2.0"})
	testing.expect_value(t, krs.packages_find(&packages, "beta").tag, "v0.2.0")
	testing.expect(t, krs.packages_find(&packages, "gamma") == nil)
	krs.packages_find(&packages, "alpha").tag = "v0.1.1"
	testing.expect_value(t, packages.packages[0].tag, "v0.1.1")

	manifest: krs.Manifest_File
	krs.manifest_put(&manifest, {name = "alpha", tag = "v0.1.0"})
	krs.manifest_put(&manifest, {name = "beta", tag = "v0.2.0"})
	krs.manifest_put(&manifest, {name = "alpha", tag = "v0.3.0"})
	testing.expect_value(t, len(manifest.packages), 2)
	testing.expect_value(t, krs.manifest_find(&manifest, "alpha").tag, "v0.3.0")

	krs.manifest_remove(&manifest, "alpha")
	testing.expect_value(t, len(manifest.packages), 1)
	testing.expect(t, krs.manifest_find(&manifest, "alpha") == nil)
	krs.manifest_remove(&manifest, "absent")
	testing.expect_value(t, len(manifest.packages), 1)
	testing.expect_value(t, manifest.packages[0].name, "beta")
}

@(test)
path_present_counts_a_dangling_symbolic_link :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	file := krs.path_join(fixture.base, "file.txt")
	fixtures.write_file(t, file, "x")
	link := krs.path_join(fixture.base, "dangling")
	testing.expect(t, os.symlink(krs.path_join(fixture.base, "nowhere"), link) == nil)

	testing.expect(t, krs.path_present(file))
	testing.expect(t, krs.path_present(fixture.base))
	testing.expect(t, krs.path_present(link))
	testing.expect(t, krs.is_symbolic_link(link))
	testing.expect(t, !krs.is_symbolic_link(file))
	testing.expect(t, !krs.path_present(krs.path_join(fixture.base, "absent")))
}

package main

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
calls_command_matches_bare_run_calls :: proc(t: ^testing.T) {
	cases := [?]struct {
		line:    string,
		matches: bool,
	} {
		{"run(t, x)", true},
		{"\tfixtures.run_in(dir, args)", true},
		{"x := run(", true},
		{"os.run(", false},
		{"foo.run(", false},
		{"rerun(", false},
		{"run_it(", false},
		{"fixtures.runner(", false},
		{"xfixtures.run(", false},
		{"", false},
	}
	for example in cases {
		testing.expect_value(t, calls_command(example.line), example.matches)
	}
}

// make_tree creates a scratch repository layout and returns its root.
make_tree :: proc(t: ^testing.T, name: string, files: []struct {
		path, text: string,
	}) -> string {
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	root := fmt.tprintf("%s/krs-dev-layout-%s-%d", tmp if tmp != "" else "/tmp", name, os.get_pid())
	_ = os.remove_all(root)
	for dir in ([?]string{"src", "tests/unit", "tests/e2e"}) {
		err := os.make_directory_all(fmt.tprintf("%s/%s", root, dir))
		testing.expect(t, err == nil)
	}

	for file in files {
		err := os.write_entire_file(fmt.tprintf("%s/%s", root, file.path), file.text)
		testing.expect(t, err == nil)
	}
	return root
}

problems_of :: proc(t: ^testing.T, name: string, files: []struct {
		path, text: string,
	}) -> []string {
	root := make_tree(t, name, files)
	defer os.remove_all(root)

	problems := layout_problems(root, context.temp_allocator)
	return problems[:]
}

@(test)
layout_accepts_a_matching_tree :: proc(t: ^testing.T) {
	problems := problems_of(t, "valid", {
		{"src/a.odin", "package krs\n"},
		{"tests/unit/a_test.odin", "package t\n\n@(test)\nx :: proc() {}\nrun_it(\n"},
		{"tests/e2e/b_test.odin", "package e\n"},
	})
	testing.expect_value(t, len(problems), 0)
}

@(test)
layout_reports_a_source_without_a_test :: proc(t: ^testing.T) {
	problems := problems_of(t, "missing", {{"src/foo.odin", "package krs\n"}})
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect_value(t, problems[0], "src/foo.odin has no tests/unit/foo_test.odin")
	}
}

@(test)
layout_reports_misnamed_test_files :: proc(t: ^testing.T) {
	problems := problems_of(t, "named", {
		{"tests/unit/helper.odin", "package t\n"},
		{"tests/e2e/helper.odin", "package e\n"},
	})
	testing.expect_value(t, len(problems), 2)
	if len(problems) == 2 {
		testing.expect_value(t, problems[0], "tests/unit/helper.odin is not named *_test.odin")
		testing.expect_value(t, problems[1], "tests/e2e/helper.odin is not named *_test.odin")
	}
}

@(test)
layout_reports_a_test_without_a_source :: proc(t: ^testing.T) {
	problems := problems_of(t, "orphan", {{"tests/unit/zed_test.odin", "package t\n\n@(test)\nx :: proc() {}\n"}})
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect_value(t, problems[0], "tests/unit/zed_test.odin has no src/zed.odin")
	}
}

@(test)
layout_reports_a_test_file_without_tests :: proc(t: ^testing.T) {
	problems := problems_of(t, "empty", {
		{"src/a.odin", "package krs\n"},
		{"tests/unit/a_test.odin", "package t\n  @(test)\n"},
	})
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect_value(t, problems[0], "tests/unit/a_test.odin has no @(test)")
	}
}

@(test)
layout_reports_unit_tests_that_run_commands :: proc(t: ^testing.T) {
	problems := problems_of(t, "runs", {
		{"src/a.odin", "package krs\n"},
		{"tests/unit/a_test.odin", "package t\n\n@(test)\nx :: proc() {\n\tfixtures.run_in(d)\n}\n"},
	})
	testing.expect_value(t, len(problems), 1)
	if len(problems) == 1 {
		testing.expect_value(
			t,
			problems[0],
			"tests/unit/a_test.odin calls run or run_in; unit tests call procedures, not commands",
		)
	}
}

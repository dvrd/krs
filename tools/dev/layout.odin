package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// PENDING lists src files still waiting for unit tests; remove each as its
// tests/unit/<x>_test.odin lands. Must end empty.
PENDING :: [?]string{}

test_layout :: proc(root: string) -> bool {
	problems := layout_problems(root, context.allocator)
	for problem in problems {
		fmt.eprintfln("check-test-layout: %s", problem)
	}
	return len(problems) == 0
}

// layout_problems checks that tests/unit mirrors src and that nothing in
// tests/unit or tests/e2e is out of place. Only top-level files are scanned.
layout_problems :: proc(root: string, allocator := context.allocator) -> [dynamic]string {
	problems := make([dynamic]string, allocator)
	sources, sources_err := odin_files(root, "src", allocator)
	units, units_err := odin_files(root, "tests/unit", allocator)
	e2es, e2es_err := odin_files(root, "tests/e2e", allocator)
	if sources_err != nil {
		append(&problems, fmt.aprintf("cannot read src: %v", sources_err, allocator = allocator))
	}

	if units_err != nil {
		append(&problems, fmt.aprintf("cannot read tests/unit: %v", units_err, allocator = allocator))
	}

	if e2es_err != nil {
		append(&problems, fmt.aprintf("cannot read tests/e2e: %v", e2es_err, allocator = allocator))
	}

	pending := PENDING
	for source in sources {
		name := strings.trim_suffix(source, ".odin")
		unit := fmt.aprintf("%s_test.odin", name, allocator = allocator)
		if !is_file_in(root, "tests/unit", unit) && !slice.contains(pending[:], name) {
			append(&problems, fmt.aprintf("src/%s has no tests/unit/%s", source, unit, allocator = allocator))
		}
	}

	for name in pending {
		unit := fmt.aprintf("%s_test.odin", name, allocator = allocator)
		if is_file_in(root, "tests/unit", unit) {
			append(
				&problems,
				fmt.aprintf("%s has tests/unit/%s; remove it from pending", name, unit, allocator = allocator),
			)
		}
	}

	for file in units {
		if !strings.has_suffix(file, "_test.odin") {
			append(&problems, fmt.aprintf("tests/unit/%s is not named *_test.odin", file, allocator = allocator))
		}
	}

	for file in e2es {
		if !strings.has_suffix(file, "_test.odin") {
			append(&problems, fmt.aprintf("tests/e2e/%s is not named *_test.odin", file, allocator = allocator))
		}
	}

	for file in units {
		if !strings.has_suffix(file, "_test.odin") {
			continue
		}

		name := strings.trim_suffix(file, "_test.odin")
		if !is_file_in(root, "src", fmt.tprintf("%s.odin", name)) {
			append(
				&problems,
				fmt.aprintf("tests/unit/%s has no src/%s.odin", file, name, allocator = allocator),
			)
		}

		text := read_text(root, "tests/unit", file)
		if !has_test_attribute(text) {
			append(&problems, fmt.aprintf("tests/unit/%s has no @(test)", file, allocator = allocator))
		}
	}

	for file in units {
		if calls_any_command(read_text(root, "tests/unit", file)) {
			append(
				&problems,
				fmt.aprintf(
					"tests/unit/%s calls run or run_in; unit tests call procedures, not commands",
					file,
					allocator = allocator,
				),
			)
		}
	}
	return problems
}

// odin_files returns the sorted names of the .odin files directly in root/dir.
// err is set when the directory cannot be read; an empty directory is not an error.
odin_files :: proc(root, dir: string, allocator := context.allocator) -> (names: []string, err: os.Error) {
	path := fmt.tprintf("%s/%s", root, dir)
	entries, read_err := os.read_all_directory_by_path(path, context.temp_allocator)
	if read_err != nil {
		return nil, read_err
	}

	found := make([dynamic]string, allocator)
	for entry in entries {
		if entry.type != .Directory && strings.has_suffix(entry.name, ".odin") {
			append(&found, strings.clone(entry.name, allocator))
		}
	}

	slice.sort(found[:])
	return found[:], nil
}

is_file_in :: proc(root, dir, name: string) -> bool {
	return os.is_file(fmt.tprintf("%s/%s/%s", root, dir, name))
}

read_text :: proc(root, dir, name: string) -> string {
	data, err := os.read_entire_file(fmt.tprintf("%s/%s/%s", root, dir, name), context.temp_allocator)
	if err != nil {
		return ""
	}
	return string(data)
}

has_test_attribute :: proc(text: string) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if is_test_attribute(line) {
			return true
		}
	}
	return false
}

// is_test_attribute reports whether a line is an attribute list such as
// `@(test)` or `@(test, private)` that names `test`.
is_test_attribute :: proc(line: string) -> bool {
	trimmed := strings.trim_right_space(line)
	if !strings.has_prefix(trimmed, "@(") {
		return false
	}

	body := trimmed[len("@("):]
	close := strings.index_byte(body, ')')
	if close < 0 {
		return false
	}

	rest := body[:close]
	for element in strings.split_iterator(&rest, ",") {
		name := strings.trim_space(element)
		equals := strings.index_byte(name, '=')
		if equals >= 0 {
			name = strings.trim_space(name[:equals])
		}

		if name == "test" {
			return true
		}
	}
	return false
}

calls_any_command :: proc(text: string) -> bool {
	code := code_only(text, context.temp_allocator)
	rest := code
	for line in strings.split_lines_iterator(&rest) {
		if calls_command(line) {
			return true
		}
	}
	return false
}

// code_only returns a copy of text with comments, string contents and rune
// literals blanked to spaces. Newlines are kept so line numbers do not change.
code_only :: proc(text: string, allocator := context.allocator) -> string {
	out := make([]u8, len(text), allocator)
	copy(out, text)

	blank :: proc(out: []u8, i: int) {
		if out[i] != '\n' {
			out[i] = ' '
		}
	}

	i := 0
	for i < len(text) {
		c := text[i]
		switch {
		case c == '/' && i + 1 < len(text) && text[i + 1] == '/':
			for i < len(text) && text[i] != '\n' {
				blank(out, i)
				i += 1
			}
		case c == '/' && i + 1 < len(text) && text[i + 1] == '*':
			depth := 0
			for i < len(text) {
				if text[i] == '/' && i + 1 < len(text) && text[i + 1] == '*' {
					depth += 1
					blank(out, i)
					blank(out, i + 1)
					i += 2
				} else if text[i] == '*' && i + 1 < len(text) && text[i + 1] == '/' {
					depth -= 1
					blank(out, i)
					blank(out, i + 1)
					i += 2
					if depth == 0 {
						break
					}
				} else {
					blank(out, i)
					i += 1
				}
			}
		case c == '"' || c == '\'':
			i += 1
			for i < len(text) && text[i] != c && text[i] != '\n' {
				if text[i] == '\\' && i + 1 < len(text) && text[i + 1] != '\n' {
					blank(out, i)
					i += 1
				}
				blank(out, i)
				i += 1
			}
			i += 1
		case c == '`':
			i += 1
			for i < len(text) && text[i] != '`' {
				blank(out, i)
				i += 1
			}
			i += 1
		case:
			i += 1
		}
	}
	return string(out)
}

// calls_command matches (^|[^A-Za-z0-9_.])(fixtures\.)?(run|run_in)\( on one
// line without a regex library.
calls_command :: proc(line: string) -> bool {
	for i in 0 ..< len(line) {
		if !strings.has_prefix(line[i:], "run(") && !strings.has_prefix(line[i:], "run_in(") {
			continue
		}

		if boundary_before(line, i) {
			return true
		}

		if strings.has_suffix(line[:i], "fixtures.") && boundary_before(line, i - len("fixtures.")) {
			return true
		}
	}
	return false
}

// boundary_before reports whether index start begins the line or follows a
// character that cannot be part of a longer name.
boundary_before :: proc(line: string, start: int) -> bool {
	assert(start >= 0)
	assert(start <= len(line))

	if start == 0 {
		return true
	}

	c := line[start - 1]
	word := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.'
	return !word
}

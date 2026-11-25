package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

import krs "../src"

// A throwaway machine: a home with krs settings, a source directory of Git
// repositories, an Odin root and a project. Nothing outside `base` is touched.
Fixture :: struct {
	t:       ^testing.T,
	base:    string,
	home:    string,
	sources: string,
	root:    string,
	shared:  string,
	project: string,
}

Result :: struct {
	code: int,
	out:  string,
	err:  string,
}

fixture_make :: proc(t: ^testing.T) -> Fixture {
	temporary, _ := os.temp_directory(context.allocator)
	base, err := os.make_directory_temp(temporary, "krs-test-*", context.allocator)
	testing.expectf(t, err == nil, "cannot create a temporary directory: %v", err)

	fixture := Fixture {
		t       = t,
		base    = base,
		home    = krs.path_join(base, "home"),
		sources = krs.path_join(base, "sources"),
		root    = krs.path_join(base, "root"),
		shared  = krs.path_join(base, "root/shared"),
		project = krs.path_join(base, "app"),
	}
	os.make_directory_all(fixture.sources)
	os.make_directory_all(fixture.shared)
	os.make_directory_all(fixture.project)
	fixture_config(&fixture, {fixture.sources})

	return fixture
}

fixture_destroy :: proc(fixture: ^Fixture) {
	os.remove_all(fixture.base)
}

fixture_config :: proc(fixture: ^Fixture, directories: []string) {
	quoted: [dynamic]string
	for directory in directories {
		append(&quoted, fmt.aprintf("\"%s\"", directory))
	}

	text := fmt.aprintf("{{\"format\": 1, \"source_directories\": [%s]}}\n", strings.join(quoted[:], ", "))
	write_file(fixture.t, krs.path_join(fixture.home, krs.CONFIG_PATH), text)
}

write_file :: proc(t: ^testing.T, path, text: string) {
	os.make_directory_all(krs.path_directory(path))
	err := os.write_entire_file(path, text)
	testing.expectf(t, err == nil, "cannot write %s: %v", path, err)
}

read_file :: proc(path: string) -> string {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return ""
	}

	return string(data)
}

git :: proc(t: ^testing.T, directory: string, arguments: ..string) -> string {
	command: [dynamic]string
	append(&command, "git", "-C", directory)
	append(&command, "-c", "user.name=krs", "-c", "user.email=krs@example.invalid")
	append(&command, "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-c", "init.defaultBranch=main")
	append(&command, ..arguments)

	state, stdout, stderr, err := os.process_exec({command = command[:]}, context.allocator)
	testing.expectf(t, err == nil && state.exit_code == 0, "git %v failed: %s", arguments, string(stderr))

	return strings.trim_space(string(stdout))
}

// Creates an empty repository `name` in the fixture's source directory.
repository_make :: proc(fixture: ^Fixture, name: string) -> string {
	path := krs.path_join(fixture.sources, name)
	os.make_directory_all(path)
	git(fixture.t, path, "init", "--quiet")

	return path
}

// Commits everything in the repository and tags the commit.
repository_release :: proc(fixture: ^Fixture, name, tag: string) -> string {
	path := krs.path_join(fixture.sources, name)
	git(fixture.t, path, "add", "-A")
	git(fixture.t, path, "commit", "--quiet", "--allow-empty", "-m", tag)
	git(fixture.t, path, "tag", tag)

	return git(fixture.t, path, "rev-parse", "HEAD")
}

// A one-file library whose constant shows which release was installed.
library_release :: proc(fixture: ^Fixture, name, tag: string, imports: ..string) -> string {
	path := krs.path_join(fixture.sources, name)
	if !os.is_directory(path) {
		repository_make(fixture, name)
	}

	source := strings.builder_make()
	fmt.sbprintf(&source, "package %s\n\n", name)
	for imported in imports {
		fmt.sbprintf(&source, "import \"shared:%s\"\n", imported)
	}
	fmt.sbprintf(&source, "\nRELEASE :: \"%s\"\n", tag)
	write_file(fixture.t, krs.path_join(path, fmt.aprintf("src/%s.odin", name)), strings.to_string(source))

	return repository_release(fixture, name, tag)
}

project_imports :: proc(fixture: ^Fixture, imports: ..string) {
	source := strings.builder_make()
	fmt.sbprintf(&source, "package main\n\n")
	for imported in imports {
		fmt.sbprintf(&source, "import \"shared:%s\"\n", imported)
	}
	fmt.sbprintf(&source, "\nmain :: proc() {{\n}}\n")
	write_file(fixture.t, krs.path_join(fixture.project, "main.odin"), strings.to_string(source))
}

// Runs a krs command in the fixture. With `input`, a person is answering.
run :: proc(fixture: ^Fixture, input: string, arguments: ..string) -> Result {
	out := strings.builder_make()
	err := strings.builder_make()
	reader: strings.Reader

	env := krs.Env {
		project      = fixture.project,
		home         = fixture.home,
		default_root = fixture.root,
		out          = strings.to_writer(&out),
		err          = strings.to_writer(&err),
		input        = strings.to_reader(&reader, input),
		interactive  = input != "",
		download_tags = github_fixture_download,
	}
	code := krs.run(&env, arguments)

	return {code = code, out = strings.to_string(out), err = strings.to_string(err)}
}

expect_ok :: proc(fixture: ^Fixture, result: Result, loc := #caller_location) {
	testing.expectf(fixture.t, result.code == 0, "krs failed (%d)\nout: %s\nerr: %s", result.code, result.out, result.err, loc = loc)
}

expect_failure :: proc(fixture: ^Fixture, result: Result, message: string, loc := #caller_location) {
	testing.expectf(fixture.t, result.code == 1, "krs should have failed\nout: %s\nerr: %s", result.out, result.err, loc = loc)
	testing.expectf(fixture.t, strings.contains(result.err, message), "expected \"%s\" in: %s", message, result.err, loc = loc)
}

expect_contains :: proc(fixture: ^Fixture, text, part: string, loc := #caller_location) {
	testing.expectf(fixture.t, strings.contains(text, part), "expected \"%s\" in: %s", part, text, loc = loc)
}

expect_release :: proc(fixture: ^Fixture, name, tag: string, loc := #caller_location) {
	path := krs.path_join(fixture.shared, fmt.aprintf("%s/%s.odin", name, name))
	expect_contains(fixture, read_file(path), fmt.aprintf("RELEASE :: \"%s\"", tag), loc)
}

packages_text :: proc(fixture: ^Fixture) -> string {
	return read_file(krs.path_join(fixture.project, krs.PACKAGES_PATH))
}

manifest_text :: proc(fixture: ^Fixture) -> string {
	return read_file(krs.path_join(fixture.shared, krs.MANIFEST_PATH))
}

package unit

import "core:os"
import "core:slice"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
excluded_directories_are_tests_examples_and_testdata :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	for name in ([]string{"tests", "examples", "testdata"}) {
		testing.expectf(t, krs.is_excluded_directory(name), "%q should be excluded", name)
	}

	for name in ([]string{"", "test", "Tests", "example", "src", "data"}) {
		testing.expectf(t, !krs.is_excluded_directory(name), "%q should not be excluded", name)
	}

	testing.expect(t, krs.is_in_excluded_directory("tests/a.odin"))
	testing.expect(t, krs.is_in_excluded_directory("pkg/examples/deep/a.odin"))
	testing.expect(t, !krs.is_in_excluded_directory("pkg/a.odin"))
	// Only directories count, not the file's own name.
	testing.expect(t, !krs.is_in_excluded_directory("tests"))
	testing.expect(t, !krs.is_in_excluded_directory("pkg/tests"))
}

@(test)
licence_files_are_recognised_by_prefix_in_any_case :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	for name in ([]string{"LICENSE", "license.md", "Licence", "LICENCE-MIT", "NOTICE", "notice.txt", "COPYING", "Copying.lesser"}) {
		testing.expectf(t, krs.is_licence_file(name), "%q should be a licence file", name)
	}

	for name in ([]string{"", "README.md", "my_license", "licen", "unlicense.txt"}) {
		testing.expectf(t, !krs.is_licence_file(name), "%q should not be a licence file", name)
	}

	for name in ([]string{".DS_Store", "Thumbs.db", "ehthumbs.db", "desktop.ini", "._alpha.odin"}) {
		testing.expectf(t, krs.is_os_metadata(name), "%q should be OS metadata", name)
	}

	for name in ([]string{"", "alpha.odin", ".gitignore", "_a", ".DS_Store2", "thumbs.db"}) {
		testing.expectf(t, !krs.is_os_metadata(name), "%q should not be OS metadata", name)
	}
}

@(test)
install_paths_refuse_unsafe_components_and_case_clashes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	safe := []krs.Selected_File{{install_path = "a.odin"}, {install_path = "assets/run.js"}, {install_path = "b.odin"}}
	testing.expect_value(t, krs.select_install_path_problem(safe), "")
	testing.expect_value(t, krs.select_install_path_problem({}), "")

	git_directory := []krs.Selected_File{{install_path = "a.odin"}, {install_path = "x/.git/config"}}
	testing.expect_value(t, krs.select_install_path_problem(git_directory), "x/.git/config is reserved for Git metadata")

	escaping := []krs.Selected_File{{install_path = "a/../b.odin"}}
	testing.expect_value(t, krs.select_install_path_problem(escaping), "a/../b.odin is not a usable name")

	clash := []krs.Selected_File{{install_path = "Alpha.odin"}, {install_path = "alpha.odin"}}
	testing.expect_value(t, krs.select_install_path_problem(clash), "Alpha.odin and alpha.odin differ only in letter case")
}

@(test)
hash_directory_is_stable_and_follows_content :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	first := krs.path_join(fixture.base, "first")
	second := krs.path_join(fixture.base, "second")
	for directory in ([]string{first, second}) {
		fixtures.write_file(t, krs.path_join(directory, "a.odin"), "package a\n")
		fixtures.write_file(t, krs.path_join(directory, "assets/b.js"), "b\n")
	}

	hash, ok := krs.hash_directory(first)
	testing.expect(t, ok)
	testing.expect_value(t, len(hash), 64)
	again, _ := krs.hash_directory(first)
	testing.expect_value(t, again, hash)
	copy_hash, _ := krs.hash_directory(second)
	testing.expect_value(t, copy_hash, hash)

	// OS metadata does not count as a change.
	fixtures.write_file(t, krs.path_join(second, ".DS_Store"), "noise")
	ignoring, _ := krs.hash_directory(second)
	testing.expect_value(t, ignoring, hash)

	fixtures.write_file(t, krs.path_join(second, "assets/b.js"), "changed\n")
	changed, _ := krs.hash_directory(second)
	testing.expect(t, changed != hash)

	_, found := krs.hash_directory(krs.path_join(fixture.base, "missing"))
	testing.expect(t, !found)
	_, is_file := krs.hash_directory(krs.path_join(first, "a.odin"))
	testing.expect(t, !is_file)
}

@(test)
hasher_separates_paths_from_contents :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	hash_of :: proc(path, data: string) -> string {
		hasher: krs.Hasher
		krs.hasher_init(&hasher)
		krs.hasher_add(&hasher, path, transmute([]byte)data)
		return krs.hasher_finish(&hasher)
	}

	testing.expect_value(t, hash_of("ab", "c"), hash_of("ab", "c"))
	testing.expect(t, hash_of("ab", "c") != hash_of("a", "bc"))
	testing.expect(t, hash_of("a", "") != hash_of("b", ""))
}

@(test)
select_files_prefers_src_and_skips_excluded_directories :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	path := fixtures.repository_make(&fixture, "alpha")
	fixtures.write_file(t, krs.path_join(path, "src/alpha.odin"), "package alpha\n\nimport \"shared:beta\"\nimport \"shared:alpha\"\nRUNTIME :: #load(\"assets/runtime.js\", string)\n")
	fixtures.write_file(t, krs.path_join(path, "src/assets/runtime.js"), "export const released = true\n")
	fixtures.write_file(t, krs.path_join(path, "src/assets/unused.js"), "unused\n")
	fixtures.write_file(t, krs.path_join(path, "src/examples/demo.odin"), "package demo\n\nimport \"shared:gamma\"\n")
	fixtures.write_file(t, krs.path_join(path, "src/.DS_Store"), "noise")
	fixtures.write_file(t, krs.path_join(path, "outside.odin"), "package outside\n")
	fixtures.write_file(t, krs.path_join(path, "LICENSE"), "licence\n")
	fixtures.write_file(t, krs.path_join(path, "src/NOTICE.txt"), "notice\n")
	fixtures.write_file(t, krs.path_join(path, "README.md"), "# alpha\n")

	selection, ok := krs.select_files({repository = path}, "alpha")
	testing.expect(t, ok)
	testing.expect_value(t, selection.problem, "")
	testing.expect_value(t, selection.prefix, "src/")
	testing.expect(t, selection.has_odin_files)
	testing.expect_value(t, len(selection.warnings), 0)
	testing.expect(t, slice.equal(selection.imports[:], []string{"beta"}))

	installed: [dynamic]string
	for file in selection.files {
		append(&installed, file.install_path)
	}
	testing.expect(t, slice.equal(installed[:], []string{"LICENSE", "NOTICE.txt", "alpha.odin", "assets/runtime.js"}))
}

@(test)
select_files_warns_about_a_load_outside_the_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	path := fixtures.repository_make(&fixture, "alpha")
	fixtures.write_file(t, krs.path_join(path, "alpha.odin"), "package alpha\n\nA :: #load(\"../secret.txt\", string)\nB :: #load(\"missing.txt\", string)\n")

	selection, ok := krs.select_files({repository = path}, "alpha")
	testing.expect(t, ok)
	testing.expect_value(t, selection.prefix, "")
	testing.expect_value(t, len(selection.files), 1)
	testing.expect_value(t, len(selection.warnings), 2)
}

@(test)
list_files_walks_by_kind :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	base := krs.path_join(fixture.base, "tree")
	fixtures.write_file(t, krs.path_join(base, "a.odin"), "package a\n")
	fixtures.write_file(t, krs.path_join(base, "sub/b.odin"), "package b\n")
	fixtures.write_file(t, krs.path_join(base, ".DS_Store"), "noise")
	fixtures.write_file(t, krs.path_join(base, ".git/config"), "x")
	fixtures.write_file(t, krs.path_join(base, ".hidden/c.odin"), "package c\n")
	fixtures.write_file(t, krs.path_join(base, "nested/.krs/packages.json"), "{}")
	fixtures.write_file(t, krs.path_join(base, "nested/d.odin"), "package d\n")

	source: [dynamic]string
	testing.expect(t, krs.list_files(base, "", .Source, &source))
	slice.sort(source[:])
	testing.expect(
		t,
		slice.equal(source[:], []string{".DS_Store", ".hidden/c.odin", "a.odin", "nested/.krs/packages.json", "nested/d.odin", "sub/b.odin"}),
	)

	project: [dynamic]string
	testing.expect(t, krs.list_files(base, "", .Project, &project, true))
	slice.sort(project[:])
	testing.expect(t, slice.equal(project[:], []string{".DS_Store", "a.odin", "sub/b.odin"}))

	installed: [dynamic]string
	testing.expect(t, krs.list_files(base, "", .Installed, &installed))
	testing.expect(t, !slice.contains(installed[:], ".DS_Store"))
	testing.expect(t, slice.contains(installed[:], ".git/config"))

	// An installed package holds regular files only.
	testing.expect(t, os.symlink("a.odin", krs.path_join(base, "link.odin")) == nil)
	more: [dynamic]string
	testing.expect(t, !krs.list_files(base, "", .Installed, &more))
	testing.expect(t, !krs.list_files(base, "missing", .Source, &more))
}

package unit

import "core:testing"

import krs "../../src"

@(test)
relative_paths_cannot_escape :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	cleaned, ok := krs.path_clean_relative("src/a/../b/./c.js")
	testing.expect(t, ok)
	testing.expect_value(t, cleaned, "src/b/c.js")

	_, escaped := krs.path_clean_relative("src/../../etc/passwd")
	testing.expect(t, !escaped)
	_, absolute := krs.path_clean_relative("/etc/passwd")
	testing.expect(t, !absolute)

	testing.expect(t, krs.is_package_name("saba"))
	testing.expect(t, krs.is_package_name("odin-http_2"))
	testing.expect(t, !krs.is_package_name(".."))
	testing.expect(t, !krs.is_package_name("a/b"))
	testing.expect(t, !krs.is_package_name(""))
}

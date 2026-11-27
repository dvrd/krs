package unit

import "core:testing"

import krs "../../src"

@(test)
list_origin_names_why_the_project_has_a_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	testing.expect_value(t, krs.list_origin("surf", {"surf", "async"}, {"saba"}), "imported")
	testing.expect_value(t, krs.list_origin("aws", {"surf"}, {"saba", "surf"}), "via saba, surf")
	testing.expect_value(t, krs.list_origin("old", {"surf"}, {}), "not used")
}

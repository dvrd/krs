package unit

import "core:c"
import "core:testing"

import krs "../../src"

// The foreign procedures of src/libgit2.odin are private to the package, so
// they are exercised through git.odin's tests. What is public is the part
// that must match libgit2's C ABI: constants, enums and struct layouts.

@(test)
object_types_match_libgit2_numbering :: proc(t: ^testing.T) {
	testing.expect_value(t, int(krs.Git_Object_Type.Commit), 1)
	testing.expect_value(t, int(krs.Git_Object_Type.Tree), 2)
	testing.expect_value(t, int(krs.Git_Object_Type.Blob), 3)
	testing.expect_value(t, size_of(krs.Git_Object_Type), size_of(c.int))
}

@(test)
file_modes_match_git_tree_entry_modes :: proc(t: ^testing.T) {
	testing.expect_value(t, int(krs.Git_Filemode.Unreadable), 0)
	testing.expect_value(t, int(krs.Git_Filemode.Tree), 0o040000)
	testing.expect_value(t, int(krs.Git_Filemode.Blob), 0o100644)
	testing.expect_value(t, int(krs.Git_Filemode.Blob_Executable), 0o100755)
	testing.expect_value(t, int(krs.Git_Filemode.Link), 0o120000)
	testing.expect_value(t, int(krs.Git_Filemode.Commit), 0o160000)
	testing.expect_value(t, size_of(krs.Git_Filemode), size_of(c.int))
}

@(test)
flags_and_error_codes_match_libgit2_headers :: proc(t: ^testing.T) {
	testing.expect_value(t, krs.GIT_REPOSITORY_OPEN_NO_SEARCH, 1)
	testing.expect_value(t, krs.GIT_TREEWALK_PRE, 0)
	testing.expect_value(t, krs.GIT_ENOTFOUND, -3)
	testing.expect_value(t, int(krs.Git_Download_Tags.Auto), 1)
	testing.expect_value(t, size_of(krs.Git_Download_Tags), size_of(c.int))
}

@(test)
string_array_has_the_layout_of_git_strarray :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(krs.Git_String_Array), size_of(rawptr) + size_of(c.size_t))
	testing.expect_value(t, offset_of(krs.Git_String_Array, strings), 0)
	testing.expect_value(t, offset_of(krs.Git_String_Array, count), size_of(rawptr))

	// A zeroed array is the empty one libgit2 expects as an output argument.
	empty: krs.Git_String_Array
	testing.expect(t, empty.strings == nil)
	testing.expect_value(t, empty.count, 0)
}

@(test)
opaque_handles_are_never_copied_by_value :: proc(t: ^testing.T) {
	// Handles cross the boundary as pointers only; their Odin types are
	// empty so that a stray by-value use is visible in review.
	testing.expect_value(t, size_of(krs.Git_Repository), 0)
	testing.expect_value(t, size_of(krs.Git_Object), 0)
	testing.expect_value(t, size_of(krs.Git_Tree), 0)
	testing.expect_value(t, size_of(krs.Git_Remote), 0)
	testing.expect_value(t, size_of(krs.Git_Config), 0)
}

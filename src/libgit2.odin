package krs

import "core:c"

foreign import libgit2 "system:git2"

Git_Repository :: struct {}
Git_Reference :: struct {}
Git_Object :: struct {}
Git_Oid :: struct {}
Git_Tree :: struct {}
Git_Tree_Entry :: struct {}
Git_Remote :: struct {}
Git_Config :: struct {}

Git_Object_Type :: enum c.int {
	Commit = 1,
	Tree   = 2,
	Blob   = 3,
}

Git_Download_Tags :: enum c.int {
	Auto = 1,
}

Git_String_Array :: struct {
	strings: [^]cstring,
	count:   c.size_t,
}

Git_Tree_Visitor :: #type proc "c" (
	root: cstring,
	entry: ^Git_Tree_Entry,
	payload: rawptr,
) -> c.int

GIT_REPOSITORY_OPEN_NO_SEARCH :: 1
GIT_TREEWALK_PRE :: 0
GIT_ENOTFOUND :: -3

@(default_calling_convention = "c", private = "package")
foreign libgit2 {
	git_libgit2_init :: proc() -> c.int ---
	git_libgit2_shutdown :: proc() -> c.int ---

	git_repository_open_ext :: proc(out: ^^Git_Repository, path: cstring, flags: c.uint, ceiling_dirs: cstring) -> c.int ---
	git_repository_init :: proc(out: ^^Git_Repository, path: cstring, is_bare: c.uint) -> c.int ---
	git_repository_path :: proc(repo: ^Git_Repository) -> cstring ---
	git_repository_workdir :: proc(repo: ^Git_Repository) -> cstring ---
	git_repository_config :: proc(out: ^^Git_Config, repo: ^Git_Repository) -> c.int ---
	git_repository_config_snapshot :: proc(out: ^^Git_Config, repo: ^Git_Repository) -> c.int ---
	git_config_get_string :: proc(out: ^cstring, config: ^Git_Config, name: cstring) -> c.int ---
	git_config_set_bool :: proc(config: ^Git_Config, name: cstring, value: c.int) -> c.int ---
	git_config_free :: proc(config: ^Git_Config) ---
	git_repository_free :: proc(repo: ^Git_Repository) ---

	git_tag_list :: proc(out: ^Git_String_Array, repo: ^Git_Repository) -> c.int ---
	git_strarray_dispose :: proc(array: ^Git_String_Array) ---
	git_reference_lookup :: proc(out: ^^Git_Reference, repo: ^Git_Repository, name: cstring) -> c.int ---
	git_reference_peel :: proc(out: ^^Git_Object, ref: ^Git_Reference, kind: Git_Object_Type) -> c.int ---
	git_reference_free :: proc(ref: ^Git_Reference) ---

	git_object_id :: proc(object: ^Git_Object) -> ^Git_Oid ---
	git_oid_tostr :: proc(out: [^]byte, size: c.size_t, id: ^Git_Oid) -> cstring ---
	git_object_free :: proc(object: ^Git_Object) ---
	git_commit_tree :: proc(out: ^^Git_Tree, commit: ^Git_Object) -> c.int ---

	git_tree_walk :: proc(tree: ^Git_Tree, mode: c.int, visitor: Git_Tree_Visitor, payload: rawptr) -> c.int ---
	git_tree_entry_name :: proc(entry: ^Git_Tree_Entry) -> cstring ---
	git_tree_entry_type :: proc(entry: ^Git_Tree_Entry) -> Git_Object_Type ---
	git_tree_entry_bypath :: proc(out: ^^Git_Tree_Entry, tree: ^Git_Tree, path: cstring) -> c.int ---
	git_tree_entry_to_object :: proc(out: ^^Git_Object, repo: ^Git_Repository, entry: ^Git_Tree_Entry) -> c.int ---
	git_tree_entry_free :: proc(entry: ^Git_Tree_Entry) ---
	git_tree_free :: proc(tree: ^Git_Tree) ---
	git_blob_rawcontent :: proc(blob: ^Git_Object) -> [^]byte ---
	git_blob_rawsize :: proc(blob: ^Git_Object) -> u64 ---

	git_remote_lookup :: proc(out: ^^Git_Remote, repo: ^Git_Repository, name: cstring) -> c.int ---
	git_remote_create :: proc(out: ^^Git_Remote, repo: ^Git_Repository, name, url: cstring) -> c.int ---
	git_remote_url :: proc(remote: ^Git_Remote) -> cstring ---
	git_remote_create_anonymous :: proc(out: ^^Git_Remote, repo: ^Git_Repository, url: cstring) -> c.int ---
	git_remote_set_instance_url :: proc(remote: ^Git_Remote, url: cstring) -> c.int ---
	git_remote_download :: proc(remote: ^Git_Remote, refspecs: ^Git_String_Array, opts: rawptr) -> c.int ---
	git_remote_update_tips :: proc(remote: ^Git_Remote, callbacks: rawptr, flags: c.uint, tags: Git_Download_Tags, reflog_message: cstring) -> c.int ---
	git_remote_free :: proc(remote: ^Git_Remote) ---
}

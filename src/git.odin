package krs

import "base:runtime"
import "core:c"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

Git_Release :: struct {
	repository: ^Git_Repository,
	tree:       ^Git_Tree,
}

// Open a bare repository or the top of a working tree, including linked worktrees.
git_open :: proc(directory: string) -> (repo: ^Git_Repository, ok: bool) {
	if directory == "" || strings.index_byte(directory, 0) >= 0 {
		return nil, false
	}
	path, err := os.get_absolute_path(directory, context.temp_allocator)
	if err != nil || git_libgit2_init() < 0 {
		return nil, false
	}
	defer if !ok {
		git_close(repo)
	}

	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	if git_repository_open_ext(&repo, c_path, GIT_REPOSITORY_OPEN_NO_SEARCH, nil) != 0 {
		return
	}
	root := git_repository_workdir(repo)
	if root == nil {
		root = git_repository_path(repo)
	}
	ok = path_trim_trailing_slash(string(root)) == path
	return
}

git_close :: proc(repo: ^Git_Repository) {
	git_repository_free(repo)
	git_libgit2_shutdown()
}

git_semver_tags :: proc(repo: ^Git_Repository) -> (tags: [dynamic]string) {
	names: Git_String_Array
	if git_tag_list(&names, repo) != 0 {
		return
	}
	defer git_strarray_dispose(&names)

	for name in names.strings[:names.count] {
		tag := string(name)
		if _, valid := parse_tag(tag); valid {
			append(&tags, strings.clone(tag))
		}
	}

	return
}

git_resolve_tag :: proc(repo: ^Git_Repository, tag: string) -> (commit: ^Git_Object, ok: bool) {
	if _, valid := parse_tag(tag); !valid {
		return nil, false
	}
	name := strings.concatenate({"refs/tags/", tag}, context.temp_allocator)
	c_name := strings.clone_to_cstring(name, context.temp_allocator)
	reference: ^Git_Reference
	if git_reference_lookup(&reference, repo, c_name) != 0 {
		return nil, false
	}
	defer git_reference_free(reference)

	ok = git_reference_peel(&commit, reference, .Commit) == 0
	return
}

git_tag_commit :: proc(directory, tag: string) -> (commit_id: string, ok: bool) {
	repo := git_open(directory) or_return
	defer git_close(repo)

	commit := git_resolve_tag(repo, tag) or_return
	defer git_object_free(commit)

	id: [65]byte
	text := git_oid_tostr(raw_data(id[:]), len(id), git_object_id(commit))
	return strings.clone(string(text)), true
}

// Keep the verified tree open while listing and reading its files. An expected
// commit prevents a tag that changes during the command from changing the
// contents under a recorded or newly resolved commit ID.
git_release_open :: proc(
	directory, tag, expected_commit: string,
) -> (
	release: Git_Release,
	ok: bool,
) {
	release.repository = git_open(directory) or_return
	defer if !ok {
		git_close(release.repository)
	}

	commit := git_resolve_tag(release.repository, tag) or_return
	defer git_object_free(commit)

	id: [65]byte
	if expected_commit != "" &&
	   string(git_oid_tostr(raw_data(id[:]), len(id), git_object_id(commit))) != expected_commit {
		return
	}

	ok = git_commit_tree(&release.tree, commit) == 0
	return
}

git_release_close :: proc(release: Git_Release) {
	git_tree_free(release.tree)
	git_close(release.repository)
}

// Why a path component read from a release tree cannot be installed, or ""
// when it is safe. Every tree name that becomes a filesystem path must pass
// through here.
git_tree_name_problem :: proc(name: string) -> string {
	if name == "" || name == "." || name == ".." {
		return "is not a usable name"
	}

	for index in 0 ..< len(name) {
		if name[index] < 0x20 || name[index] == 0x7f {
			return "has a control character"
		}
	}

	if git_tree_name_is_git_metadata(name) {
		return "is reserved for Git metadata"
	}

	return ""
}

// True when the name reads as ".git" once ASCII letter case and the code
// points that filesystems ignore are set aside.
@(private = "file")
git_tree_name_is_git_metadata :: proc(name: string) -> bool {
	folded: [dynamic]byte
	defer delete(folded)

	rest := name
	for len(rest) > 0 {
		r, size := utf8.decode_rune_in_string(rest)
		rest = rest[size:]
		if git_tree_rune_is_ignorable(r) {
			continue
		}

		if r >= 0x80 {
			return false
		}

		lower := r + ('a' - 'A') if 'A' <= r && r <= 'Z' else r
		append(&folded, byte(lower))
		if len(folded) > len(".git") {
			return false
		}
	}

	return string(folded[:]) == ".git"
}

@(private = "file")
git_tree_rune_is_ignorable :: proc(r: rune) -> bool {
	switch r {
	case 0x200C ..= 0x200F, 0x202A ..= 0x202E, 0x206A ..= 0x206F, 0xFEFF:
		return true
	}

	return false
}

// Lists the regular files of a release. Symbolic links and submodules are
// never installed; `skipped` maps each one's path to what it is.
git_list_files :: proc(release: Git_Release) -> (files: [dynamic]string, skipped: map[string]string, ok: bool) {
	Walk :: struct {
		files:   ^[dynamic]string,
		skipped: ^map[string]string,
		ctx:     runtime.Context,
	}
	walk := Walk {
		files   = &files,
		skipped = &skipped,
		ctx     = context,
	}
	visit :: proc "c" (root: cstring, entry: ^Git_Tree_Entry, payload: rawptr) -> c.int {
		walk := cast(^Walk)payload
		context = walk.ctx

		name := string(git_tree_entry_name(entry))
		if name == "" || name == "." || name == ".." || strings.index_byte(name, '/') >= 0 {
			return -1
		}

		path := strings.concatenate({string(root), name})
		mode := git_tree_entry_filemode(entry)
		if mode == .Link {
			walk.skipped[path] = "a symbolic link"
			return 0
		}

		if git_tree_entry_type(entry) == .Commit {
			walk.skipped[path] = "a submodule"
			return 0
		}

		if mode == .Blob || mode == .Blob_Executable {
			append(walk.files, path)
		}
		return 0
	}

	ok = git_tree_walk(release.tree, GIT_TREEWALK_PRE, visit, &walk) == 0
	return
}

Git_Blob_Status :: enum {
	Read,
	Missing,
	Failed,
}

git_read_file :: proc(release: Git_Release, path: string) -> (data: []byte, status: Git_Blob_Status) {
	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	entry: ^Git_Tree_Entry
	result := git_tree_entry_bypath(&entry, release.tree, c_path)
	if result == GIT_ENOTFOUND {
		return nil, .Missing
	}

	if result != 0 {
		return nil, .Failed
	}
	defer git_tree_entry_free(entry)
	if git_tree_entry_type(entry) != .Blob {
		return nil, .Failed
	}

	// A symbolic link is a blob holding its target path, never content.
	if git_tree_entry_filemode(entry) == .Link {
		return nil, .Failed
	}

	blob: ^Git_Object
	if git_tree_entry_to_object(&blob, release.repository, entry) != 0 {
		return nil, .Failed
	}
	defer git_object_free(blob)

	size := git_blob_rawsize(blob)
	if size > u64(max(int)) {
		return nil, .Failed
	}

	if size == 0 {
		return nil, .Read
	}

	content := git_blob_rawcontent(blob)
	return slice.clone(content[:int(size)]), .Read
}

// A remote address may carry a user name or token; that must never reach a
// committed file.
strip_credentials :: proc(address: string) -> string {
	scheme_end := strings.index(address, "://")
	if scheme_end < 0 {
		return address
	}

	rest := address[scheme_end + 3:]
	host_end := strings.index_byte(rest, '/')
	if host_end < 0 {
		host_end = len(rest)
	}

	at := strings.last_index_byte(rest[:host_end], '@')
	if at < 0 {
		return address
	}

	return strings.concatenate({address[:scheme_end + 3], rest[at + 1:]})
}

SOURCE_LOCAL :: "local"

// Keep project pins portable. Fetch still uses the configured origin URL.
source_identity :: proc(address: string) -> string {
	if address == "" {
		return ""
	}

	if strings.has_prefix(address, "file://") {
		return SOURCE_LOCAL
	}

	suffix := strings.index_any(address, "?#")
	bare := address[:suffix] if suffix >= 0 else address

	if strings.index(address, "://") < 0 {
		colon := strings.index_byte(address, ':')
		slash := strings.index_byte(address, '/')
		if colon < 0 || (slash >= 0 && slash < colon) {
			return SOURCE_LOCAL
		}

		if repository, valid := github_repository_from_ssh(bare); valid {
			return github_origin(repository)
		}
		return address // SCP-style SSH address.
	}

	if repository, valid := github_repository_from_ssh(bare); valid {
		return github_origin(repository)
	}

	clean := strip_credentials(bare)
	if repository, valid := github_repository_from_origin(clean); valid {
		return github_origin(repository)
	}

	return clean
}

// Where a repository comes from: its `origin`, or `local` when it has none.
git_source :: proc(repo: ^Git_Repository) -> string {
	remote: ^Git_Remote
	if git_remote_lookup(&remote, repo, "origin") != 0 {
		return SOURCE_LOCAL
	}
	defer git_remote_free(remote)

	address := string(git_remote_url(remote))
	if address == "" {
		return SOURCE_LOCAL
	}

	return strings.clone(source_identity(address))
}

package unit

import "core:testing"

import krs "../../src"

@(test)
tree_names_reject_git_metadata_and_controls :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// "‌" is ZERO WIDTH NON-JOINER, which some filesystems ignore.
	for bad in ([]string{".git", ".GIT", ".Git", ".g‌it", "a\x1bb", "", ".", ".."}) {
		testing.expectf(t, krs.git_tree_name_problem(bad) != "", "%q should be refused", bad)
	}

	for good in ([]string{".github", "git", "x.odin"}) {
		testing.expectf(t, krs.git_tree_name_problem(good) == "", "%q should be allowed", good)
	}
}

@(test)
source_never_carries_credentials :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	testing.expect_value(t, krs.strip_credentials("https://user:token@github.com/o/r.git"), "https://github.com/o/r.git")
	testing.expect_value(t, krs.strip_credentials("https://github.com/o/r.git"), "https://github.com/o/r.git")
	testing.expect_value(t, krs.strip_credentials("git@github.com:o/r.git"), "git@github.com:o/r.git")
	testing.expect_value(t, krs.source_identity("https://user:token@github.com/o/r.git?token=second#secret"), "https://github.com/o/r.git")
	testing.expect_value(t, krs.source_identity("file:///some/local/repo.git"), "local")
}

@(test)
ssh_github_origins_share_the_https_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	testing.expect_value(t, krs.source_identity("git@github.com:Owner/Repo.git"), "https://github.com/owner/repo.git")
	testing.expect_value(t, krs.source_identity("git@github.com:owner/repo"), "https://github.com/owner/repo.git")
	testing.expect_value(t, krs.source_identity("ssh://git@github.com/owner/repo.git"), "https://github.com/owner/repo.git")
	testing.expect_value(t, krs.source_identity("ssh://git@github.com:22/owner/repo.git"), "https://github.com/owner/repo.git")
	// Not GitHub: unchanged.
	testing.expect_value(t, krs.source_identity("git@gitlab.com:o/r.git"), "git@gitlab.com:o/r.git")
	// Malformed GitHub SSH address: unchanged, never a wrong repository.
	testing.expect_value(t, krs.source_identity("git@github.com:onlyowner"), "git@github.com:onlyowner")
}

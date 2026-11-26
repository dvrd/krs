package unit

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
repository_cache_key_separates_cached_lookups :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	local := krs.repository_cache_key("/sources/beta", false)
	cached := krs.repository_cache_key("/sources/beta", true)
	testing.expect_value(t, local, "/sources/beta")
	testing.expect(t, local != cached)
	testing.expect(t, strings.has_prefix(cached, "/sources/beta"))
	testing.expect(t, krs.repository_cache_key("/sources/gamma", true) != cached)
}

@(test)
repository_has_tag_matches_whole_tags :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	repository := krs.Repository{}
	append(&repository.tags, "v0.1.0", "v1.2.0")
	testing.expect(t, krs.repository_has_tag(&repository, "v0.1.0"))
	testing.expect(t, krs.repository_has_tag(&repository, "v1.2.0"))
	testing.expect(t, !krs.repository_has_tag(&repository, "v1.2"))
	testing.expect(t, !krs.repository_has_tag(&repository, "1.2.0"))
	testing.expect(t, !krs.repository_has_tag(&repository, ""))
}

@(test)
repository_read_lists_semantic_version_tags :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	path := krs.path_join(fixture.sources, "beta")
	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.library_release(&fixture, "beta", "v0.2.0")
	fixtures.git(t, path, "tag", "latest")
	untagged := fixtures.repository_make(&fixture, "gamma")
	fixtures.write_file(t, krs.path_join(untagged, "src/gamma.odin"), "package gamma\n")
	fixtures.repository_release(&fixture, "gamma", "stable")
	plain := krs.path_join(fixture.sources, "plain")
	os.make_directory_all(plain)

	_, state := planning_state(&fixture)
	if state == nil {
		return
	}
	defer krs.state_close(state)

	repository, reason := krs.repository_read(path, false)
	testing.expect_value(t, reason, "")
	testing.expect_value(t, repository.path, path)
	testing.expect_value(t, repository.source, krs.SOURCE_LOCAL)
	testing.expect_value(t, len(repository.tags), 2)
	testing.expect(t, slice.contains(repository.tags[:], "v0.1.0"))
	testing.expect(t, slice.contains(repository.tags[:], "v0.2.0"))

	_, reason = krs.repository_read(untagged, false)
	testing.expect_value(t, reason, "it has no semantic-version tag")
	_, reason = krs.repository_read(plain, false)
	testing.expect_value(t, reason, "it is not a Git repository")
	// A working checkout is never taken for the GitHub cache.
	_, reason = krs.repository_read(path, true)
	testing.expect_value(t, reason, "it is not a bare cached repository with an origin")

	// repository_open reads each repository once per command.
	krs.repository_open(state, path)
	krs.repository_open(state, path)
	testing.expect_value(t, state.counts.repository_opens, 1)
	krs.repository_forget(state, path)
	krs.repository_open(state, path)
	testing.expect_value(t, state.counts.repository_opens, 2)
}

@(test)
repository_find_searches_the_source_directories :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	planning, state := planning_state(&fixture)
	if state == nil {
		return
	}
	defer krs.state_close(state)

	repository, found := krs.repository_find(state, "beta", "v0.1.0", "")
	testing.expect(t, found)
	testing.expect_value(t, repository.path, krs.path_join(fixture.sources, "beta"))

	repository, found = krs.repository_find(state, "beta", "", "")
	testing.expect(t, found)

	_, found = krs.repository_find(state, "beta", "v9.0.0", "")
	testing.expect(t, !found)
	testing.expect(t, strings.contains(strings.to_string(planning.out), "it has no tag v9.0.0"))

	strings.builder_reset(&planning.out)
	_, found = krs.repository_find(state, "beta", "v0.1.0", "https://github.com/someone/beta.git")
	testing.expect(t, !found)
	testing.expect(t, strings.contains(strings.to_string(planning.out), "not the recorded https://github.com/someone/beta.git"))

	_, found = krs.repository_find(state, "nowhere", "", "")
	testing.expect(t, !found)
}

@(test)
repository_tag_commit_rejects_a_moved_tag :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	path := krs.path_join(fixture.sources, "beta")
	commit := fixtures.library_release(&fixture, "beta", "v0.1.0")
	planning, state := planning_state(&fixture)
	if state == nil {
		return
	}
	defer krs.state_close(state)

	resolved, ok := krs.repository_tag_commit(&planning.env, path, "beta", "v0.1.0", "")
	testing.expect(t, ok)
	testing.expect_value(t, resolved, commit)
	resolved, ok = krs.repository_tag_commit(&planning.env, path, "beta", "v0.1.0", commit)
	testing.expect(t, ok)

	resolved, ok = krs.repository_tag_commit(&planning.env, path, "beta", "v0.1.0", PLAN_COMMIT_A)
	testing.expect(t, !ok)
	testing.expect_value(t, resolved, "")
	testing.expect(t, strings.contains(strings.to_string(planning.err), "a published tag must not move"))

	strings.builder_reset(&planning.err)
	_, ok = krs.repository_tag_commit(&planning.env, path, "beta", "v9.9.9", "")
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(strings.to_string(planning.err), "cannot resolve tag v9.9.9"))

	// state_tag_commit resolves once and still checks the expected commit.
	resolved, ok = krs.state_tag_commit(state, path, "beta", "v0.1.0", "")
	testing.expect(t, ok)
	testing.expect_value(t, resolved, commit)
	_, ok = krs.state_tag_commit(state, path, "beta", "v0.1.0", PLAN_COMMIT_A)
	testing.expect(t, !ok)
	testing.expect_value(t, state.counts.tag_resolves, 1)
}

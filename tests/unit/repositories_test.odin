package unit

import "core:os"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
github_targets_accept_owner_slash_repo :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	repository, ok := krs.github_repository("DVRD/Kessel")
	testing.expect(t, ok)
	testing.expect_value(t, repository.owner, "dvrd")
	testing.expect_value(t, repository.name, "kessel")

	repository, ok = krs.github_repository("dvrd/odin.json")
	testing.expect(t, ok)
	testing.expect_value(t, repository.name, "odin.json")

	for bad in ([]string{"", "kessel", "/kessel", "dvrd/", "dvrd/kessel.git", "dvrd/KESSEL.GIT", "-dvrd/kessel", "dvrd-/kessel", "dv.rd/kessel", "dv_rd/kessel", "dvrd/.hidden", "dvrd/a/b", "dvrd/a b"}) {
		_, valid := krs.github_repository(bad)
		testing.expectf(t, !valid, "%q should be rejected", bad)
	}
}

@(test)
github_origin_round_trips_through_from_origin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	repository, _ := krs.github_repository("Owner/Repo")
	testing.expect_value(t, krs.github_locator(repository), "owner/repo")

	origin := krs.github_origin(repository)
	testing.expect_value(t, origin, "https://github.com/owner/repo.git")

	again, ok := krs.github_repository_from_origin(origin)
	testing.expect(t, ok)
	testing.expect_value(t, again, repository)

	without_suffix, found := krs.github_repository_from_origin("https://github.com/owner/repo")
	testing.expect(t, found)
	testing.expect_value(t, without_suffix, repository)

	for bad in ([]string{"", "owner/repo", "http://github.com/owner/repo.git", "https://gitlab.com/owner/repo.git", "https://github.com/owner"}) {
		_, valid := krs.github_repository_from_origin(bad)
		testing.expectf(t, !valid, "%q should be rejected", bad)
	}
}

@(test)
github_ssh_addresses_share_the_https_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	expected, _ := krs.github_repository("owner/repo")
	for address in ([]string{"git@github.com:owner/repo.git", "git@github.com:Owner/Repo", "ssh://git@github.com/owner/repo.git", "ssh://git@github.com:22/owner/repo.git", "GIT@GITHUB.COM:owner/repo"}) {
		repository, ok := krs.github_repository_from_ssh(address)
		testing.expectf(t, ok, "%q should be accepted", address)
		testing.expect_value(t, repository, expected)
	}

	for address in ([]string{"git@gitlab.com:owner/repo.git", "ssh://git@github.com:/owner/repo", "ssh://git@github.com:x/owner/repo", "ssh://git@github.com:22", "ssh://git@github.comowner/repo", "https://github.com/owner/repo.git", "git@github.com:owner"}) {
		_, ok := krs.github_repository_from_ssh(address)
		testing.expectf(t, !ok, "%q should be rejected", address)
	}
}

@(test)
github_cache_path_lies_under_the_home_store :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	env := krs.Env{home = fixture.home}
	repository, _ := krs.github_repository("owner/repo")

	store := krs.repository_store(&env)
	testing.expect(t, strings.has_prefix(store, fixture.home))
	testing.expect_value(t, krs.github_store(&env), krs.path_join(store, "github"))
	testing.expect_value(t, krs.github_cache_path(&env, repository), krs.path_join(krs.github_store(&env), "owner/repo"))
}

@(test)
cache_create_records_the_origin_of_a_local_github_copy :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	fixtures.github_fixture_release(&fixture, "owner", "repo", "v1.0.0")

	out := strings.builder_make()
	failure := strings.builder_make()
	env := krs.Env {
		home          = fixture.home,
		out           = strings.to_writer(&out),
		err           = strings.to_writer(&failure),
		download_tags = fixtures.github_fixture_download,
	}
	repository, _ := krs.github_repository("owner/repo")
	target := krs.github_cache_path(&env, repository)
	directory := krs.path_directory(target)
	os.make_directory_all(directory)

	origin := krs.github_origin(repository)
	testing.expectf(t, krs.cache_create(&env, directory, target, origin), "cache_create failed: %s", strings.to_string(failure))
	testing.expect(t, os.is_directory(target))

	repo, opened := krs.git_open(target)
	testing.expect(t, opened)
	if !opened {
		return
	}
	defer krs.git_close(repo)

	address, found := krs.cached_origin(repo)
	testing.expect(t, found)
	testing.expect_value(t, address, origin)
	testing.expect_value(t, len(krs.git_semver_tags(repo)), 1)
}

@(test)
cache_create_refuses_a_repository_without_release_tags :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	remote := krs.path_join(fixture.base, "github/owner/repo")
	os.make_directory_all(remote)
	fixtures.git(t, remote, "init", "--quiet")
	fixtures.git(t, remote, "commit", "--quiet", "--allow-empty", "-m", "first")

	out := strings.builder_make()
	failure := strings.builder_make()
	env := krs.Env {
		home          = fixture.home,
		out           = strings.to_writer(&out),
		err           = strings.to_writer(&failure),
		download_tags = fixtures.github_fixture_download,
	}
	repository, _ := krs.github_repository("owner/repo")
	target := krs.github_cache_path(&env, repository)
	directory := krs.path_directory(target)
	os.make_directory_all(directory)

	testing.expect(t, !krs.cache_create(&env, directory, target, krs.github_origin(repository)))
	testing.expect(t, strings.contains(strings.to_string(failure), "has no semantic-version tag"))
	testing.expect(t, !os.exists(target))
}

@(test)
cached_origin_is_absent_without_an_origin_remote :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	path := fixtures.repository_make(&fixture, "plain")

	repo, opened := krs.git_open(path)
	testing.expect(t, opened)
	if !opened {
		return
	}
	defer krs.git_close(repo)

	_, found := krs.cached_origin(repo)
	testing.expect(t, !found)
}

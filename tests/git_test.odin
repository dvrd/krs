package tests

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"

import krs "../src"

@(test)
install_reads_annotated_tag_from_a_packed_bare_repository :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	commit := library_release(&fixture, "beta", "v1.0.0")
	repository := krs.path_join(fixture.sources, "beta")
	git(t, repository, "tag", "-a", "-m", "release", "v1.0.1", commit)
	git(t, repository, "mv", "src/beta.odin", "src/unreleased.odin")
	git(t, repository, "commit", "--quiet", "-m", "unreleased")
	bare := krs.path_join(fixture.base, "bare")
	os.make_directory_all(bare)
	git(t, bare, "clone", "--quiet", "--bare", repository, "beta")
	git(t, krs.path_join(bare, "beta"), "gc", "--quiet")
	fixture_config(&fixture, {bare})
	project_imports(&fixture, "beta")

	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_release(&fixture, "beta", "v1.0.0")
	expect_contains(&fixture, packages_text(&fixture), "\"tag\": \"v1.0.1\"")
	expect_contains(&fixture, packages_text(&fixture), commit)
	testing.expect(t, !os.exists(krs.path_join(fixture.shared, "beta/unreleased.odin")))
}

@(test)
install_reads_tags_from_a_linked_worktree :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	library_release(&fixture, "beta", "v1.0.0")
	repository := krs.path_join(fixture.sources, "beta")
	worktrees := krs.path_join(fixture.base, "worktrees")
	os.make_directory_all(worktrees)
	git(t, repository, "worktree", "add", "--quiet", "--detach", krs.path_join(worktrees, "beta"))
	fixture_config(&fixture, {worktrees})
	project_imports(&fixture, "beta")

	write_file(t, krs.path_join(worktrees, "beta/src/beta.odin"), "package beta\n")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_release(&fixture, "beta", "v1.0.0")
}

// Emulate GitHub with local Git objects after checking the requested HTTPS
// URL. The CLI always uses libgit2's network transport for this URL.
github_fixture_download :: proc(env: ^krs.Env, repo: ^krs.Git_Repository, directory, origin: string) -> bool {
	repository, valid := krs.github_repository_from_origin(origin)
	if !valid || origin != krs.github_origin(repository) {
		return krs.fail(env, "unexpected transport URL %q", origin)
	}
	remote := krs.path_join(krs.path_directory(env.home), "github")
	return krs.git_download_tags(env, repo, directory, krs.path_join(remote, krs.github_locator(repository)))
}

github_fixture_release :: proc(fixture: ^Fixture, owner, name, tag: string) -> string {
	previous := fixture.sources
	defer fixture.sources = previous
	fixture.sources = krs.path_join(fixture.base, krs.path_join("github", owner))
	return library_release(fixture, name, tag)
}

github_fixture_config :: proc(fixture: ^Fixture, name, target: string, source := "github") {
	config := krs.Config{format = 1}
	config.libs[name] = {source = source, target = target}
	data, err := json.marshal(config)
	testing.expect_value(fixture.t, err, nil)
	write_file(fixture.t, krs.path_join(fixture.home, krs.CONFIG_PATH), string(data))
}

@(test)
fetch_uses_a_github_locator_and_preserves_existing_cached_tags :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	first := github_fixture_release(&fixture, "dvrd", "beta", "v1.0.0")
	expect_ok(&fixture, run(&fixture, "", "fetch", "Dvrd/Beta"))
	cache := krs.path_join(fixture.home, ".local/shared/krs/repos/github/dvrd/beta")
	testing.expect_value(t, git(t, cache, "rev-parse", "--is-bare-repository"), "true")
	testing.expect_value(t, git(t, cache, "config", "--get", "remote.origin.url"), "https://github.com/dvrd/beta.git")
	testing.expect_value(t, git(t, cache, "rev-parse", "refs/tags/v1.0.0"), first)

	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_release(&fixture, "beta", "v1.0.0")

	second := github_fixture_release(&fixture, "dvrd", "beta", "v1.1.0")
	origin := krs.path_join(fixture.base, "github/dvrd/beta")
	git(t, origin, "tag", "--force", "v1.0.0", second)
	expect_ok(&fixture, run(&fixture, "", "fetch", "dvrd/beta"))
	testing.expect_value(t, git(t, cache, "rev-parse", "refs/tags/v1.0.0"), first)
	testing.expect_value(t, git(t, cache, "rev-parse", "refs/tags/v1.1.0"), second)
	expect_ok(&fixture, run(&fixture, "", "update", "beta", "--yes"))
	expect_release(&fixture, "beta", "v1.1.0")
}

@(test)
install_fetches_only_configured_github_libraries_and_can_reinstall_frozen :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	commit := github_fixture_release(&fixture, "dvrd", "project-kessel", "v1.0.0")
	project_imports(&fixture, "kessel")
	expect_failure(&fixture, run(&fixture, "", "install", "--yes"), "no repository for \"kessel\"")
	testing.expect(t, !os.exists(krs.path_join(fixture.home, ".local/shared/krs/repos")))

	write_file(t, krs.path_join(fixture.home, krs.CONFIG_PATH),
		`{"libs":{"kessel":{"source":"github","target":"dvrd/project-kessel"}}}`)
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	packages := packages_text(&fixture)
	expect_contains(&fixture, packages, "\"name\": \"kessel\"")
	expect_contains(&fixture, packages, "https://github.com/dvrd/project-kessel.git")
	expect_contains(&fixture, packages, commit)
	cache := krs.path_join(fixture.home, ".local/shared/krs/repos/github/dvrd/project-kessel")
	testing.expect(t, os.is_directory(cache))

	// A fresh Odin root with the same project pin can re-fetch the exact commit.
	testing.expect_value(t, os.remove_all(cache), nil)
	other_root := krs.path_join(fixture.base, "other-root")
	os.make_directory_all(other_root)
	expect_ok(&fixture, run(&fixture, "", "install", "--frozen", fmt.aprintf("--root=%s", other_root)))
	testing.expect_value(t, packages_text(&fixture), packages)

	// A populated cache remains sufficient after the remote vanishes.
	remote := krs.path_join(fixture.base, "github/dvrd/project-kessel")
	testing.expect_value(t, os.rename(remote, krs.path_join(fixture.base, "offline-origin")), nil)
	offline_root := krs.path_join(fixture.base, "offline-root")
	os.make_directory_all(offline_root)
	expect_ok(&fixture, run(&fixture, "", "install", "--frozen", fmt.aprintf("--root=%s", offline_root)))
	expect_contains(&fixture, read_file(krs.path_join(offline_root, "shared/kessel/project-kessel.odin")), "v1.0.0")
}

@(test)
configured_github_origin_cannot_replace_a_recorded_origin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	github_fixture_release(&fixture, "first", "beta", "v1.0.0")
	github_fixture_release(&fixture, "second", "beta", "v1.0.0")
	github_fixture_config(&fixture, "beta", "first/beta")
	project_imports(&fixture, "beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	pin := packages_text(&fixture)

	github_fixture_config(&fixture, "beta", "second/beta")
	other_root := krs.path_join(fixture.base, "other-root")
	os.make_directory_all(other_root)
	store := krs.path_join(fixture.home, ".local/shared/krs/repos/github")
	testing.expect_value(t, os.remove_all(krs.path_join(store, "first/beta")), nil)
	expect_failure(&fixture, run(&fixture, "", "install", "--yes", fmt.aprintf("--root=%s", other_root)),
		"does not match the recorded origin")
	testing.expect_value(t, packages_text(&fixture), pin)
	testing.expect(t, !os.exists(krs.path_join(store, "second/beta")))
}

@(test)
install_uses_the_configured_owner_when_cached_names_collide :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	github_fixture_release(&fixture, "first", "beta", "v1.0.0")
	github_fixture_release(&fixture, "second", "beta", "v2.0.0")
	expect_ok(&fixture, run(&fixture, "", "fetch", "first/beta"))
	expect_ok(&fixture, run(&fixture, "", "fetch", "second/beta"))
	project_imports(&fixture, "beta")

	result := run(&fixture, "", "install", "--yes")
	expect_failure(&fixture, result, "no repository for \"beta\"")
	expect_contains(&fixture, result.out, "more than one cached GitHub repository matches beta")

	github_fixture_config(&fixture, "beta", "first/beta")
	expect_ok(&fixture, run(&fixture, "", "install", "--yes"))
	expect_release(&fixture, "beta", "v1.0.0")
}

@(test)
fetch_rejects_urls_and_invalid_github_locators :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	for target in ([]string{"https://github.com/dvrd/kessel", "http://example.org/dvrd/kessel", "dvrd/kessel/extra", "../kessel", "kessel", "dvrd/kessel?x"}) {
		expect_failure(&fixture, run(&fixture, "", "fetch", target), "expected a GitHub repository in owner/repo form")
	}

	project_imports(&fixture, "kessel")
	github_fixture_config(&fixture, "kessel", "dvrd/kessel", "gitlab")
	expect_failure(&fixture, run(&fixture, "", "install", "--yes"), "libs.kessel must use source github")
	testing.expect(t, !os.exists(krs.path_join(fixture.home, ".local/shared/krs/repos")))
}

@(test)
fetch_leaves_no_cache_entry_if_github_has_no_release :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	remote := krs.path_join(fixture.base, "github/dvrd/beta")
	os.make_directory_all(remote)
	git(t, remote, "init", "--quiet")
	git(t, remote, "commit", "--quiet", "--allow-empty", "-m", "unreleased")
	expect_failure(&fixture, run(&fixture, "", "fetch", "dvrd/beta"), "has no semantic-version tag")
	store := krs.path_join(fixture.home, ".local/shared/krs/repos/github/dvrd")
	entries, err := os.read_all_directory_by_path(store, context.allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(entries), 0)

	github_fixture_release(&fixture, "dvrd", "beta", "v1.0.0")
	expect_ok(&fixture, run(&fixture, "", "fetch", "dvrd/beta"))
}

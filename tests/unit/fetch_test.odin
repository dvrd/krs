package unit

import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import krs "../../src"
import "../fixtures"

@(test)
library_github_resolves_a_configured_lib :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	out := strings.builder_make()
	env := krs.Env{out = strings.to_writer(&out)}
	config: krs.Config
	config.libs["kessel"] = {source = "github", target = "DVRD/Kessel"}

	repository, ok := krs.library_github(&env, config, "kessel", true)
	testing.expect(t, ok)
	testing.expect_value(t, repository, krs.GitHub_Repository{owner = "dvrd", name = "kessel"})
	testing.expect_value(t, strings.to_string(out), "")
}

@(test)
library_github_rejects_unknown_and_malformed_libs :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	out := strings.builder_make()
	env := krs.Env{out = strings.to_writer(&out)}
	config: krs.Config
	config.libs["local"] = {source = "path", target = "dvrd/kessel"}
	config.libs["broken"] = {source = "github", target = "not-a-repository"}

	_, ok := krs.library_github(&env, config, "unknown", false)
	testing.expect(t, !ok)
	testing.expect_value(t, strings.to_string(out), "")

	_, ok = krs.library_github(&env, config, "local", true)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(strings.to_string(out), "libs.local must use source github"))

	strings.builder_reset(&out)
	_, ok = krs.library_github(&env, config, "broken", true)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(strings.to_string(out), "libs.broken.target must be a GitHub owner/repo"))

	strings.builder_reset(&out)
	_, ok = krs.library_github(&env, config, "broken", false)
	testing.expect(t, !ok)
	testing.expect_value(t, strings.to_string(out), "")
}

@(test)
command_fetch_rejects_a_malformed_target_without_touching_the_store :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	out := strings.builder_make()
	errors := strings.builder_make()
	env := krs.Env{home = fixture.home, out = strings.to_writer(&out), err = strings.to_writer(&errors)}
	for target in ([]string{"kessel", "dvrd/kessel.git", "dv.rd/kessel", "/kessel"}) {
		strings.builder_reset(&errors)
		testing.expectf(t, !krs.command_fetch(&env, target), "%s should be rejected", target)
		testing.expect(t, strings.contains(strings.to_string(errors), "expected a GitHub repository in owner/repo form"))
	}
	testing.expect(t, !os.exists(krs.repository_store(&env)))
}

@(test)
command_fetch_all_counts_bad_libs_and_accepts_none :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	out := strings.builder_make()
	errors := strings.builder_make()
	env := krs.Env{home = fixture.home, project = fixture.project, out = strings.to_writer(&out), err = strings.to_writer(&errors)}
	testing.expect(t, krs.command_fetch_all(&env))
	testing.expect(t, strings.contains(strings.to_string(out), "this project has no dependencies"))

	// Only the libs the project imports are checked; c is never read.
	config := `{"format": 1, "source_directories": [], "libs": {"a": {"source": "path", "target": "x/a"}, "b": {"source": "github", "target": "bad"}, "c": {"source": "path", "target": "x/c"}}}`
	fixtures.write_file(t, krs.path_join(fixture.home, krs.CONFIG_PATH), config)
	fixtures.write_file(t, krs.path_join(fixture.project, "main.odin"), "package main\n\nimport \"shared:a\"\nimport \"shared:b\"\n")
	strings.builder_reset(&out)
	testing.expect(t, !krs.command_fetch_all(&env))
	testing.expect(t, strings.contains(strings.to_string(errors), "could not fetch 2 of 2 GitHub package(s)"))
	testing.expect(t, strings.contains(strings.to_string(out), "libs.a must use source github"))
	testing.expect(t, strings.contains(strings.to_string(out), "libs.b.target must be a GitHub owner/repo"))
	testing.expect(t, !strings.contains(strings.to_string(out), "libs.c"))
	testing.expect(t, !os.exists(krs.repository_store(&env)))
}

@(test)
package_github_uses_the_lib_or_an_existing_cache :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	out := strings.builder_make()
	env := krs.Env{home = fixture.home, out = strings.to_writer(&out)}
	config := krs.Config{libs = make(map[string]krs.Library_Source)}
	config.libs["kessel"] = krs.Library_Source{source = "github", target = "dvrd/kessel"}

	github, from_github, valid := krs.package_github(&env, config, "kessel", "")
	testing.expect(t, from_github && valid)
	testing.expect_value(t, krs.github_locator(github), "dvrd/kessel")

	// An origin without a cache entry is not fetched: krs never creates one
	// the user did not configure.
	_, from_github, _ = krs.package_github(&env, config, "surf", "https://github.com/dvrd/surf.git")
	testing.expect(t, !from_github)

	cached := krs.GitHub_Repository{owner = "dvrd", name = "surf"}
	os.make_directory_all(krs.github_cache_path(&env, cached))
	github, from_github, valid = krs.package_github(&env, config, "surf", "https://github.com/dvrd/surf.git")
	testing.expect(t, from_github && valid)
	testing.expect_value(t, krs.github_locator(github), "dvrd/surf")

	_, from_github, _ = krs.package_github(&env, config, "local", "/src/local")
	testing.expect(t, !from_github)

	// Not recorded and not configured: the one cached repository of that
	// name, as install would choose it; two owners make it ambiguous.
	_, from_github, _ = krs.package_github(&env, config, "saba", "")
	testing.expect(t, !from_github)

	os.make_directory_all(krs.github_cache_path(&env, krs.GitHub_Repository{owner = "dvrd", name = "saba"}))
	github, from_github, valid = krs.package_github(&env, config, "saba", "")
	testing.expect(t, from_github && valid)
	testing.expect_value(t, krs.github_locator(github), "dvrd/saba")

	os.make_directory_all(krs.github_cache_path(&env, krs.GitHub_Repository{owner = "other", name = "saba"}))
	_, from_github, valid = krs.package_github(&env, config, "saba", "")
	testing.expect(t, from_github && !valid)
	testing.expect(t, strings.contains(strings.to_string(out), "more than one cached GitHub repository matches saba"))
}

// An empty bare repository in the fixture, opened through krs; close it with
// krs.git_close.
fetch_bare_repository :: proc(t: ^testing.T, fixture: ^fixtures.Fixture) -> (repo: ^krs.Git_Repository, path: string) {
	path = krs.path_join(fixture.base, "cache.git")
	fixtures.git(t, fixture.base, "init", "--quiet", "--bare", path)
	opened: bool
	repo, opened = krs.git_open(path)
	testing.expectf(t, opened, "cannot open %s", path)
	return repo, path
}

@(test)
git_download_tags_brings_every_tag_from_a_local_repository :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.library_release(&fixture, "beta", "v0.1.0")
	fixtures.library_release(&fixture, "beta", "v0.2.0")
	repo, path := fetch_bare_repository(t, &fixture)
	if repo == nil {
		return
	}
	defer krs.git_close(repo)

	errors := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&errors)}
	testing.expectf(t, krs.git_download_tags(&env, repo, path, krs.path_join(fixture.sources, "beta")), "%s", strings.to_string(errors))

	tags := krs.git_semver_tags(repo)
	slice.sort(tags[:])
	testing.expect_value(t, len(tags), 2)
	if len(tags) == 2 {
		testing.expect_value(t, tags[0], "v0.1.0")
		testing.expect_value(t, tags[1], "v0.2.0")
	}
}

@(test)
git_download_tags_fails_for_a_missing_origin :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	repo, path := fetch_bare_repository(t, &fixture)
	if repo == nil {
		return
	}
	defer krs.git_close(repo)

	errors := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&errors)}
	testing.expect(t, !krs.git_download_tags(&env, repo, path, krs.path_join(fixture.base, "missing")))
	testing.expect(t, strings.contains(strings.to_string(errors), "cannot fetch tags from the origin of"))
	testing.expect_value(t, len(krs.git_semver_tags(repo)), 0)
}

@(test)
fetch_github_tags_hands_the_origin_to_the_download_hook :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	repo, path := fetch_bare_repository(t, &fixture)
	if repo == nil {
		return
	}
	defer krs.git_close(repo)

	errors := strings.builder_make()
	env := krs.Env {
		home          = fixture.home,
		err           = strings.to_writer(&errors),
		download_tags = proc(env: ^krs.Env, repo: ^krs.Git_Repository, directory, origin: string) -> bool {
			return krs.fail(env, "hook got %s for %s", origin, krs.path_base(directory))
		},
	}
	testing.expect(t, !krs.fetch_github_tags(&env, repo, path, "https://github.com/dvrd/kessel.git"))
	testing.expect(t, strings.contains(strings.to_string(errors), "hook got https://github.com/dvrd/kessel.git for cache.git"))
}

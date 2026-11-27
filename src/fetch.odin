package krs

import "core:os"
import "core:slice"
import "core:strings"

command_fetch :: proc(env: ^Env, target: string) -> bool {
	repository, valid := github_repository(target)
	if !valid {
		return fail(env, "expected a GitHub repository in owner/repo form")
	}
	return cache_github_repository(env, repository)
}

// Refreshes the GitHub releases of this project's dependencies: the packages
// .krs/packages.json records and the `shared:` names the project imports.
// Libraries nothing here uses are left alone. A bad entry or a failed fetch
// is counted; the rest still run.
command_fetch_all :: proc(env: ^Env) -> bool {
	config := load_config(env) or_return
	packages := load_packages(env) or_return
	imports, scanned := scan_directory_imports(env.project, path_base(env.project), true)
	if !scanned {
		return fail(env, "cannot read the Odin files under %s", env.project)
	}

	names := make([dynamic]string, context.temp_allocator)
	for record in packages.packages {
		append_unique(&names, record.name)
	}

	for imported in imports {
		append_unique(&names, imported)
	}
	slice.sort(names[:])

	fetched, failed, local := 0, 0, 0
	for name in names {
		source := ""
		if record := packages_find(&packages, name); record != nil {
			source = record.source
		}

		github, from_github, valid := package_github(env, config, name, source)
		if !from_github {
			local += 1
			continue
		}

		if !valid || !cache_github_repository(env, github) {
			failed += 1
			continue
		}
		fetched += 1
	}

	if failed > 0 {
		return fail(env, "could not fetch %d of %d GitHub package(s)", failed, failed + fetched)
	}

	if fetched == 0 {
		if local > 0 {
			info(env, "no dependency of this project comes from GitHub; nothing to fetch")
		} else {
			info(env, "this project has no dependencies; nothing to fetch")
		}
	}
	return true
}

// Where package `name` is fetched from: its configured lib, the GitHub origin
// `source` records when that repository is already cached, or, with no record,
// the one cached repository of that name. Never a cache entry the user did not
// configure. `from_github` is false for a local
// package; `valid` is false for a lib entry that is reported as broken.
package_github :: proc(env: ^Env, config: Config, name, source: string) -> (github: GitHub_Repository, from_github, valid: bool) {
	if _, configured := config.libs[name]; configured {
		github, valid = library_github(env, config, name, true)
		return github, true, valid
	}

	if source == "" {
		// Not recorded yet: the cached repository install would choose, the
		// one owner/<name> in the cache. Two make the name ambiguous.
		matches := github_cached_matches(env, name)
		switch len(matches) {
		case 0:
			return {}, false, false
		case 1:
			return matches[0], true, true
		}

		warn(env, "more than one cached GitHub repository matches %s; select one in %s", name, "config.json libs")
		return {}, true, false
	}

	origin, parsed := github_repository_from_origin(source_identity(source))
	if !parsed || !os.is_directory(github_cache_path(env, origin)) {
		return {}, false, false
	}
	return origin, true, true
}

// The cached GitHub repositories named `name`, under any owner.
github_cached_matches :: proc(env: ^Env, name: string) -> []GitHub_Repository {
	matches := make([dynamic]GitHub_Repository, context.temp_allocator)
	owners, err := os.read_all_directory_by_path(github_store(env), context.temp_allocator)
	if err != nil {
		return matches[:]
	}

	for owner in owners {
		if owner.type != .Directory {
			continue
		}

		locator, valid := github_repository(path_join(owner.name, name))
		if valid && os.is_directory(github_cache_path(env, locator)) {
			append(&matches, locator)
		}
	}
	return matches[:]
}

// Validates `libs.<name>`; a problem is reported as a warning when `report`.
library_github :: proc(env: ^Env, config: Config, name: string, report: bool) -> (repository: GitHub_Repository, ok: bool) {
	library := config.libs[name]
	if library.source != "github" {
		if report {
			warn(env, "libs.%s must use source github", name)
		}
		return {}, false
	}

	github, valid := github_repository(library.target)
	if !valid {
		if report {
			warn(env, "libs.%s.target must be a GitHub owner/repo", name)
		}
		return {}, false
	}

	return github, true
}

// Refreshes the cache behind one package before it is checked; see
// package_github. A failure is a warning, not an error.
refresh_package_cache :: proc(state: ^State, name, source: string) {
	github, from_github, valid := package_github(state.env, state.config, name, source)
	if !from_github || !valid {
		return
	}

	if !cache_github_repository(state.env, github) {
		warn(state.env, "could not refresh %s; using the cached tags", name)
	}
}

fetch_github_tags :: proc(env: ^Env, repo: ^Git_Repository, directory, origin: string) -> bool {
	progress_start(env, "Fetching GitHub tags")
	defer progress_stop(env)

	if env.download_tags != nil {
		return env.download_tags(env, repo, directory, origin)
	}

	// Fetch uses the explicit HTTPS GitHub origin. Keep redirects and URL
	// rewrites from selecting another destination.
	config: ^Git_Config
	if git_repository_config(&config, repo) != 0 {
		return fail(env, "cannot open fetch settings for %s", origin)
	}
	defer git_config_free(config)
	if git_config_set_bool(config, "http.followRedirects", 0) != 0 {
		return fail(env, "cannot disable redirects for %s", origin)
	}
	return git_download_tags(env, repo, directory, origin)
}

git_download_tags :: proc(env: ^Env, repo: ^Git_Repository, directory, address: string) -> bool {
	// Use the given URL without inheriting origin's refspecs or pruning.
	url := strings.clone_to_cstring(address, context.temp_allocator)
	remote: ^Git_Remote
	if git_remote_create_anonymous(&remote, repo, url) != 0 {
		return fail(env, "cannot open the origin of %s", directory)
	}
	defer git_remote_free(remote)
	if git_remote_set_instance_url(remote, url) != 0 {
		return fail(env, "cannot set the origin URL of %s", directory)
	}

	// Download all tags. Auto-follow publishes the downloaded tags without
	// overwriting an existing local tag, even if it could fast-forward.
	refspecs := [?]cstring{"refs/tags/*:refs/tags/*"}
	tags := Git_String_Array {
		strings = raw_data(refspecs[:]),
		count   = len(refspecs),
	}
	if result := git_remote_download(remote, &tags, nil); result != 0 {
		return fail(
			env,
			"cannot fetch tags from the origin of %s (libgit2 error %d)",
			directory,
			result,
		)
	}

	if result := git_remote_update_tips(remote, nil, 0, .Auto, "krs fetch origin"); result != 0 {
		return fail(env, "cannot record fetched tags for %s (libgit2 error %d)", directory, result)
	}

	return true
}

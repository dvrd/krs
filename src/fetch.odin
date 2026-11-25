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

// Refreshes every GitHub library named in the settings. A bad entry or a
// failed fetch is counted, the rest still run.
command_fetch_all :: proc(env: ^Env) -> bool {
	config := load_config(env) or_return
	if len(config.libs) == 0 {
		info(env, "no libs in %s; nothing to fetch", path_join(env.home, CONFIG_PATH))
		return true
	}

	keys, _ := slice.map_keys(config.libs, context.temp_allocator)
	slice.sort(keys)
	failed := 0

	for name in keys {
		github, valid := library_github(env, config, name, true)
		if !valid || !cache_github_repository(env, github) {
			failed += 1
		}
	}

	if failed > 0 {
		return fail(env, "could not fetch %d of %d lib(s)", failed, len(keys))
	}

	return true
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

// Refreshes the cache behind one package before it is checked: the configured
// lib, or an existing cache entry of its GitHub origin. Never creates a cache
// entry the user did not configure. A failure is a warning, not an error.
refresh_package_cache :: proc(state: ^State, name, source: string) {
	github: GitHub_Repository
	if _, configured := state.config.libs[name]; configured {
		valid: bool
		github, valid = library_github(state.env, state.config, name, true)
		if !valid {
			return
		}
	} else {
		valid: bool
		github, valid = github_repository_from_origin(source_identity(source))
		if !valid || !os.is_directory(github_cache_path(state.env, github)) {
			return
		}
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

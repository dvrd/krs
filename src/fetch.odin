package krs

import "core:strings"

command_fetch :: proc(env: ^Env, target: string) -> bool {
	repository, valid := github_repository(target)
	if !valid {
		return fail(env, "expected a GitHub repository in owner/repo form")
	}
	return cache_github_repository(env, repository)
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

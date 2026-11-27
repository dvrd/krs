package krs

import "core:fmt"
import "core:os"
import "core:strings"

Repository :: struct {
	path:      string,
	source:    string,
	tags:      [dynamic]string,
	tag_times: map[string]i64, // filled on demand by repository_load_times
}

Repository_Lookup :: struct {
	repository: Repository,
	reason:     string, // why the path is not usable, or ""
}

repository_cache_key :: proc(path: string, cached: bool) -> string {
	return strings.concatenate({path, "\x00cached" if cached else ""})
}

// Opens a repository once per command; a fetch forgets the lookup.
repository_open :: proc(state: ^State, path: string, cached := false) -> (repository: Repository, reason: string) {
	key := repository_cache_key(path, cached)
	if lookup, hit := state.repositories[key]; hit {
		assert(lookup.reason != "" || lookup.repository.path == path)
		return lookup.repository, lookup.reason
	}

	repository, reason = repository_read(path, cached)
	state.repositories[key] = {repository, reason}
	state.counts.repository_opens += 1
	return
}

// Drops what this command learned about a repository that was written to.
repository_forget :: proc(state: ^State, path: string) {
	delete_key(&state.repositories, repository_cache_key(path, true))
	delete_key(&state.repositories, repository_cache_key(path, false))

	// Collect first: never delete from a map while iterating it.
	stale := make([dynamic][2]string, context.temp_allocator)
	for key in state.tag_commits {
		if key[0] == path {
			append(&stale, key)
		}
	}

	for key in stale {
		delete_key(&state.tag_commits, key)
	}
}

repository_read :: proc(path: string, cached: bool) -> (repository: Repository, reason: string) {
	repo, ok := git_open(path)
	if !ok {
		return {}, "it is not a Git repository"
	}

	defer git_close(repo)

	repository.path = path
	repository.tags = git_semver_tags(repo)
	if len(repository.tags) == 0 {
		return {}, "it has no semantic-version tag"
	}

	if cached {
		address, found := cached_origin(repo)
		if !found || git_repository_workdir(repo) != nil {
			return {}, "it is not a bare cached repository with an origin"
		}
		repository.source = source_identity(address)
	} else {
		repository.source = git_source(repo)
	}

	return repository, ""
}

// Commit times are read only when a target or format needs them.
repository_load_times :: proc(state: ^State, repository: ^Repository) -> bool {
	if len(repository.tag_times) > 0 {
		return true
	}

	repo, ok := git_open(repository.path)
	if !ok {
		warn(state.env, "cannot read the tag dates of %s", repository.path)
		return false
	}
	repository.tag_times = git_tag_times(repo, repository.tags[:])
	git_close(repo)

	// Keep the times for this command; the lookup does not record `cached`,
	// so match it by path.
	for _, &lookup in state.repositories {
		if lookup.repository.path == repository.path {
			lookup.repository.tag_times = repository.tag_times
		}
	}
	return true
}

repository_has_tag :: proc(repository: ^Repository, tag: string) -> bool {
	for existing in repository.tags {
		if existing == tag {
			return true
		}
	}

	return false
}

repository_candidate :: proc(state: ^State, path, tag, origin: string, cached := false) -> (repository: Repository, ok: bool) {
	if !os.is_directory(path) {
		return {}, false
	}

	reason: string
	repository, reason = repository_open(state, path, cached)
	if reason == "" && cached {
		if _, valid := github_repository_from_origin(repository.source); !valid {
			reason = "it has no HTTPS GitHub origin"
		}
	}

	if reason == "" && tag != "" && !repository_has_tag(&repository, tag) {
		reason = fmt.aprintf("it has no tag %s", tag)
	}

	// A checkout recorded while it had no remote may have gained one since;
	// it is still the same checkout, and installing still checks the
	// recorded commit. The other way round stays a different repository.
	gained_origin := origin == SOURCE_LOCAL && !cached
	if reason == "" && origin != "" && origin != repository.source && !gained_origin {
		reason = fmt.aprintf("it comes from %s, not the recorded %s", repository.source, origin)
	}

	if reason != "" {
		report_once(state, "skipped %s: %v", path, reason)
		return {}, false
	}
	return repository, true
}

// The repository of an installed record. Records in a committed vendor/
// carry no machine path, so look the repository up again.
manifest_repository :: proc(state: ^State, record: Manifest_Record) -> string {
	if record.path != "" {
		return record.path
	}

	repository, found := repository_find(state, record.name, record.tag, record.source)
	return repository.path if found else ""
}

// Check configured source directories before cached GitHub repositories.
repository_find :: proc(state: ^State, name, tag, source: string) -> (repository: Repository, ok: bool) {
	origin := source_identity(source)
	for directory in state.config.source_directories {
		candidate, found := repository_candidate(state, path_join(directory, name), tag, origin)
		if found {
			return candidate, true
		}
	}

	if github, valid := github_repository_from_origin(origin); valid {
		candidate, found := repository_candidate(state, github_cache_path(state.env, github), tag, origin, true)
		if found {
			return candidate, true
		}
	} else if origin == "" {
		cache := github_store(state.env)
		owners, err := os.read_all_directory_by_path(cache, context.temp_allocator)
		if err == nil {
			for owner in owners {
				if owner.type != .Directory {
					continue
				}
				locator := github_repository(path_join(owner.name, name)) or_continue
				candidate := repository_candidate(state, github_cache_path(state.env, locator), tag, github_origin(locator), true) or_continue
				if ok {
					report_once(state, "more than one cached GitHub repository matches %s; select one in %s", name, "config.json libs")
					return {}, false
				}
				repository, ok = candidate, true
			}
		}
		if ok {
			return
		}
	}

	// Older caches were stored directly under the package name.
	return repository_candidate(state, path_join(repository_store(state.env), name), tag, origin, true)
}

// A dependency's recorded source does not choose the repository; report
// when the repository that was chosen comes from elsewhere.
repository_check_pin :: proc(state: ^State, name, wanted: string, candidate: Repository) {
	if wanted == "" || candidate.source == wanted {
		return
	}

	report_once(state, "a dependency pins %s from %s; using %s, which comes from %s", name, wanted, candidate.path, candidate.source)
}

repository_resolve :: proc(state: ^State, name, tag, source, commit: string, source_trusted: bool) -> (repository: Repository, ok: bool) {
	origin := source_identity(source) if source_trusted else ""
	wanted := "" if source_trusted else source_identity(source)
	library, configured := state.config.libs[name]
	github: GitHub_Repository
	if state.fetch_configured && configured {
		if library.source != "github" {
			return {}, fail(state.env, "libs.%s must use source github", name)
		}

		valid: bool
		github, valid = github_repository(library.target)
		if !valid {
			return {}, fail(state.env, "libs.%s.target must be a GitHub owner/repo", name)
		}

		if origin == "" {
			origin = github_origin(github)
		}
	}

	candidate, found := repository_find(state, name, tag, origin)
	if found {
		repository_check_pin(state, name, wanted, candidate)
		return candidate, true
	}

	if state.fetch_configured && configured && (!state.options.frozen || (tag != "" && commit != "")) {
		if origin != github_origin(github) {
			return {}, fail(state.env, "the GitHub repository in libs.%s does not match the recorded origin %q", name, origin)
		}

		// Fetch once per command, even if the fetch fails; a later pass
		// reads the cache as this fetch left it.
		assert(origin == github_origin(github))
		if succeeded, attempted := state.fetched[origin]; attempted {
			if !succeeded {
				return {}, fail(
					state.env,
					"cannot fetch %s for %s; this command's fetch failed, run %s when online",
					github_locator(github),
					name,
					fmt.tprintf("krs fetch %s", github_locator(github)),
				)
			}
			return {}, fail(state.env, "the GitHub repository for %s did not provide tag %s", name, tag)
		}

		state.counts.fetches += 1
		fetched := cache_github_repository(state.env, github)
		state.fetched[origin] = fetched
		// Even a failed fetch may have written to the cache.
		repository_forget(state, github_cache_path(state.env, github))
		if !fetched {
			return {}, false
		}

		if refreshed, available := repository_candidate(state, github_cache_path(state.env, github), tag, origin, true); available {
			repository_check_pin(state, name, wanted, refreshed)
			return refreshed, true
		}
		return {}, fail(state.env, "the GitHub repository for %s did not provide tag %s", name, tag)
	}

	if pinned, valid := github_repository_from_origin(origin); valid {
		note(state.env, "use %s to cache the recorded origin", fmt.tprintf("krs fetch %s", github_locator(pinned)))
	} else if _, wanted_github := github_repository_from_origin(wanted); wanted_github {
		note(state.env, "a dependency pins %s from %s; add a libs entry for %s in config.json to use it", name, wanted, name)
	}

	if tag == "" {
		return {}, fail(state.env, "no repository for \"%s\" in the source directories or repository store", name)
	}
	return {}, fail(state.env, "no repository for \"%s\" with tag %s in the source directories or repository store", name, tag)
}

// Resolves a tag once per command; the recorded commit is checked every time.
state_tag_commit :: proc(state: ^State, path, name, tag, expected: string) -> (commit: string, ok: bool) {
	hit: bool
	commit, hit = state.tag_commits[{path, tag}]
	if !hit {
		commit = repository_tag_commit(state.env, path, name, tag, "") or_return
		state.tag_commits[{path, tag}] = commit
		state.counts.tag_resolves += 1
	}

	assert(is_commit_id(commit))
	if expected != "" && expected != commit {
		return "", fail(
			state.env,
			"%s %s was recorded at commit %s but the tag now resolves to %s; a published tag must not move",
			name,
			tag,
			expected,
			commit,
		)
	}
	return commit, true
}

repository_tag_commit :: proc(env: ^Env, path, name, tag, expected_commit: string) -> (commit: string, ok: bool) {
	resolved, resolved_ok := git_tag_commit(path, tag)
	if !resolved_ok {
		return "", fail(env, "cannot resolve tag %s of %s", tag, path)
	}

	if expected_commit != "" && expected_commit != resolved {
		return "", fail(
			env,
			"%s %s was recorded at commit %s but the tag now resolves to %s; a published tag must not move",
			name,
			tag,
			expected_commit,
			resolved,
		)
	}

	return resolved, true
}

package krs

import "core:os"
import "core:strings"

GITHUB_ORIGIN :: "https://github.com/"

GitHub_Repository :: struct {
	owner: string,
	name:  string,
}

github_repository :: proc(target: string) -> (repository: GitHub_Repository, ok: bool) {
	slash := strings.index_byte(target, '/')
	if slash < 0 {
		return {}, false
	}

	owner, name := target[:slash], target[slash + 1:]
	if !is_package_name(owner) || strings.has_suffix(owner, "-") ||
	   !is_package_name(name) || strings.has_suffix(strings.to_lower(name), ".git") {
		return {}, false
	}

	for byte in transmute([]u8)owner {
		if byte == '.' || byte == '_' {
			return {}, false
		}
	}

	return {strings.to_lower(owner), strings.to_lower(name)}, true
}

github_locator :: proc(repository: GitHub_Repository) -> string {
	return path_join(repository.owner, repository.name)
}

github_origin :: proc(repository: GitHub_Repository) -> string {
	return strings.concatenate({GITHUB_ORIGIN, github_locator(repository), ".git"})
}

github_repository_from_origin :: proc(origin: string) -> (GitHub_Repository, bool) {
	if !strings.has_prefix(origin, GITHUB_ORIGIN) {
		return {}, false
	}
	return github_repository(strings.trim_suffix(origin[len(GITHUB_ORIGIN):], ".git"))
}

// Accepts `git@github.com:o/r`, `ssh://git@github.com/o/r` and the same with
// a numeric port. Call it before `strip_credentials`, without `?` or `#`.
github_repository_from_ssh :: proc(address: string) -> (GitHub_Repository, bool) {
	SCP_PREFIX :: "git@github.com:"
	URL_PREFIX :: "ssh://git@github.com"

	rest: string
	if len(address) >= len(SCP_PREFIX) && strings.equal_fold(address[:len(SCP_PREFIX)], SCP_PREFIX) {
		rest = address[len(SCP_PREFIX):]
	} else if len(address) >= len(URL_PREFIX) && strings.equal_fold(address[:len(URL_PREFIX)], URL_PREFIX) {
		rest = address[len(URL_PREFIX):]
		if strings.has_prefix(rest, ":") {
			digits := 0
			for byte in transmute([]u8)rest[1:] {
				if byte < '0' || byte > '9' {
					break
				}
				digits += 1
			}

			if digits == 0 || len(rest) <= 1 + digits || rest[1 + digits] != '/' {
				return {}, false
			}
			rest = rest[1 + digits:]
		}

		if !strings.has_prefix(rest, "/") {
			return {}, false
		}
		rest = rest[1:]
	} else {
		return {}, false
	}

	return github_repository(strings.trim_suffix(rest, ".git"))
}

repository_store :: proc(env: ^Env) -> string {
	return path_join(env.home, KRS_DATA_PATH + "/repos")
}

github_store :: proc(env: ^Env) -> string {
	return path_join(repository_store(env), "github")
}

github_cache_path :: proc(env: ^Env, repository: GitHub_Repository) -> string {
	return path_join(github_store(env), github_locator(repository))
}

// Read the selected origin directly so Git's URL rewrites cannot change it.
cached_origin :: proc(repo: ^Git_Repository) -> (address: string, ok: bool) {
	config: ^Git_Config
	if git_repository_config_snapshot(&config, repo) != 0 {
		return "", false
	}
	defer git_config_free(config)

	url: cstring
	if git_config_get_string(&url, config, "remote.origin.url") != 0 || string(url) == "" {
		return "", false
	}
	return strings.clone(string(url)), true
}

cache_refresh :: proc(env: ^Env, target, origin: string) -> bool {
	repo, ok := git_open(target)
	if !ok {
		return fail(env, "cannot open the cached repository at %s", target)
	}
	defer git_close(repo)

	address, found := cached_origin(repo)
	if !found || git_repository_workdir(repo) != nil || source_identity(address) != origin {
		return fail(env, "%s is not a bare cache for %s", target, origin)
	}

	fetch_github_tags(env, repo, target, origin) or_return
	success(env, "fetched tags for %s", origin)
	return true
}

cache_github_repository :: proc(env: ^Env, repository: GitHub_Repository) -> bool {
	if env.home == "" {
		return fail(env, "cannot locate the home directory for the repository store")
	}

	target := github_cache_path(env, repository)
	directory := path_directory(target)
	if err := os.make_directory_all(directory, {.Read_User, .Write_User, .Execute_User});
	   err != nil && !os.is_directory(directory) {
		return fail(env, "cannot create repository store %s: %v", directory, err)
	}

	lock := directory_lock(env, directory) or_return
	defer directory_unlock(lock)
	origin := github_origin(repository)
	info, stat_err := os.lstat(target, context.temp_allocator)
	switch stat_err {
	case nil:
		if info.type != .Directory {
			return fail(env, "repository store entry %s is not a directory", target)
		}
		return cache_refresh(env, target, origin)
	case .Not_Exist:
		cache_create(env, directory, target, origin) or_return
	case:
		return fail(env, "cannot inspect repository store entry %s: %v", target, stat_err)
	}

	success(env, "cached %s in %s", github_locator(repository), target)
	return true
}

cache_create :: proc(env: ^Env, directory, target, origin: string) -> bool {
	staging, err := os.make_directory_temp(directory, ".krs-fetch-*", context.allocator)
	if err != nil {
		return fail(env, "cannot stage a repository in %s: %v", directory, err)
	}
	defer os.remove_all(staging)

	if git_libgit2_init() < 0 {
		return fail(env, "cannot initialize libgit2")
	}
	defer git_libgit2_shutdown()

	repo: ^Git_Repository
	if git_repository_init(&repo, strings.clone_to_cstring(staging, context.temp_allocator), 1) != 0 {
		return fail(env, "cannot initialize the bare repository for %s", origin)
	}
	defer git_repository_free(repo)
	remote: ^Git_Remote
	if git_remote_create(&remote, repo, "origin", strings.clone_to_cstring(origin, context.temp_allocator)) != 0 {
		return fail(env, "cannot configure the origin for %s", origin)
	}
	defer git_remote_free(remote)

	fetch_github_tags(env, repo, staging, origin) or_return
	if len(git_semver_tags(repo)) == 0 {
		return fail(env, "%s has no semantic-version tag", origin)
	}

	if rename_err := os.rename(staging, target); rename_err != nil {
		return fail(env, "cannot publish the cached repository for %s: %v", origin, rename_err)
	}
	return true
}

package krs

import "core:os"
import "core:path/slashpath"
import "core:slice"
import "core:strings"

DEEP_MAX_PROJECTS :: 256
DEEP_MAX_DIRECTORIES :: 10_000

// The projects under `start`, as absolute paths in sorted order: every
// directory with a .krs/packages.json, plus `start` itself when it has Odin
// files that import shared: packages. Hidden directories, vendor/ and symbolic
// links are not searched.
deep_projects :: proc(env: ^Env, start: string) -> (projects: [dynamic]string, ok: bool) {
	pending: [dynamic]string
	defer delete(pending)
	append(&pending, start)
	visited := 0

	for head := 0; head < len(pending); head += 1 {
		directory := pending[head]
		visited += 1
		if visited > DEEP_MAX_DIRECTORIES {
			return projects, fail(env, "more than %d directories under %s; use --package-file from a smaller directory", DEEP_MAX_DIRECTORIES, start)
		}

		is_project := os.exists(path_join(directory, PACKAGES_PATH))
		if !is_project && directory == start {
			imports, scanned := scan_directory_imports(directory, path_base(directory), true)
			is_project = scanned && len(imports) > 0
		}

		if is_project {
			if len(projects) >= DEEP_MAX_PROJECTS {
				return projects, fail(env, "more than %d projects under %s", DEEP_MAX_PROJECTS, start)
			}
			append(&projects, directory)
		}

		entries, err := os.read_all_directory_by_path(directory, context.allocator)
		if err != nil {
			return projects, fail(env, "cannot read %s", directory)
		}

		for entry in entries {
			if entry.type != .Directory || strings.has_prefix(entry.name, ".") || entry.name == VENDOR_DIR {
				continue
			}
			append(&pending, path_join(directory, entry.name))
		}
	}
	slice.sort(projects[:])

	return projects, true
}

// Whether a project-relative lockfile path matches a --package-file pattern.
// `*` matches within one path segment and `**` matches any number of segments.
// A pattern that names a directory matches that directory's lockfile.
package_file_matches :: proc(pattern, lockfile: string) -> bool {
	pattern := pattern
	if strings.has_prefix(pattern, "./") {
		pattern = pattern[2:]
	}

	pattern = path_trim_trailing_slash(pattern)
	if pattern == "." || pattern == "" {
		pattern = PACKAGES_PATH
	} else if pattern != PACKAGES_PATH && !strings.has_suffix(pattern, "/" + PACKAGES_PATH) {
		pattern = strings.concatenate({pattern, "/", PACKAGES_PATH}, context.temp_allocator)
	}

	wanted := strings.split(pattern, "/", context.temp_allocator)
	actual := strings.split(lockfile, "/", context.temp_allocator)
	at_pattern, at_path := 0, 0
	star_pattern, star_path := -1, 0

	// Each step either consumes a segment or moves the retry point forward, so
	// the loop ends after at most len(wanted) * len(actual) steps.
	for at_path < len(actual) {
		if at_pattern < len(wanted) && wanted[at_pattern] == "**" {
			star_pattern, star_path = at_pattern, at_path
			at_pattern += 1
			continue
		}

		if at_pattern < len(wanted) {
			matched, err := slashpath.match(wanted[at_pattern], actual[at_path])
			if err == .None && matched {
				at_pattern += 1
				at_path += 1
				continue
			}
		}

		if star_pattern < 0 {
			return false
		}

		star_path += 1
		at_path = star_path
		at_pattern = star_pattern + 1
	}

	for at_pattern < len(wanted) && wanted[at_pattern] == "**" {
		at_pattern += 1
	}

	return at_pattern == len(wanted)
}

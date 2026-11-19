package main

import "core:fmt"
import "core:os"
import "core:strings"

import krs "../../src"

main :: proc() {
	env := krs.Env{err = os.to_writer(os.stderr)}
	os.exit(krs.EXIT_OK if run(&env, os.args[1:]) else krs.EXIT_FAILED)
}

run :: proc(env: ^krs.Env, args: []string) -> bool {
	if len(args) != 2 && len(args) != 3 {
		return krs.fail(env, "usage: version <major|minor|patch> <file> or version check <file> <existing-tags>")
	}

	action, path := args[0], args[1]
	if action == "check" && len(args) == 3 {
		tag, version := read_version(env, path) or_return
		latest, found := krs.highest_tag(strings.split_lines(args[2]))
		if found {
			prior, _ := krs.parse_tag(latest)
			if krs.version_compare(version, prior) != .Higher {
				return krs.fail(env, "%s must be higher than the existing release %s", tag, latest)
			}
		}
		fmt.println(tag)
		return true
	}

	if len(args) != 2 {
		return krs.fail(env, "expected a version component and a version file")
	}

	part: krs.Version_Bump
	switch action {
	case "major":
		part = .Major
	case "minor":
		part = .Minor
	case "patch":
		part = .Patch
	case:
		return krs.fail(env, "expected major, minor, or patch")
	}
	return bump_file(env, path, part)
}

read_version :: proc(env: ^krs.Env, path: string) -> (tag: string, version: krs.Version, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return "", {}, krs.fail(env, "cannot read %s: %v", path, err)
	}

	tag = strings.trim_space(string(data))
	version, ok = krs.parse_tag(tag)
	if !ok {
		return "", {}, krs.fail(env, "%s must contain a vMAJOR.MINOR.PATCH tag", path)
	}
	return
}

bump_file :: proc(env: ^krs.Env, path: string, part: krs.Version_Bump) -> bool {
	parent := krs.path_directory(path)
	directory := parent if parent != "" else "."
	lock := krs.directory_lock(env, directory) or_return
	defer krs.directory_unlock(lock)

	_, version := read_version(env, path) or_return
	next, ok := krs.version_bump(version, part)
	if !ok {
		return krs.fail(env, "cannot increment that version component")
	}

	staging, err := os.make_directory_temp(directory, ".krs-version-*", context.allocator)
	if err != nil {
		return krs.fail(env, "cannot stage the version update: %v", err)
	}
	defer os.remove_all(staging)

	tag := fmt.aprintf("v%d.%d.%d", next.major, next.minor, next.patch)
	temporary := krs.path_join(staging, "VERSION")
	if write_err := os.write_entire_file(temporary, fmt.aprintf("%s\n", tag)); write_err != nil {
		return krs.fail(env, "cannot stage the version update: %v", write_err)
	}

	if rename_err := os.rename(temporary, path); rename_err != nil {
		return krs.fail(env, "cannot update %s: %v", path, rename_err)
	}

	fmt.println(tag)
	return true
}

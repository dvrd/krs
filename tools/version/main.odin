package main

import "core:fmt"
import "core:os"
import "core:strings"

import krs "../../src"

main :: proc() {
	context.allocator = context.temp_allocator
	env := krs.Env{err = os.to_writer(os.stderr)}
	os.exit(krs.EXIT_OK if run(&env, os.args[1:]) else krs.EXIT_FAILED)
}

run :: proc(env: ^krs.Env, args: []string) -> bool {
	if len(args) == 2 && args[0] == "latest" {
		tags := read_input(env, args[1]) or_return
		if latest, ok := krs.highest_tag(strings.split_lines(tags)); ok {
			fmt.println(latest)
		}
		return true
	}

	if len(args) == 4 && args[0] == "notes" {
		for tag in args[1:3] {
			if _, valid := krs.parse_tag(tag); !valid {
				return krs.fail(env, "%s must be a vMAJOR.MINOR.PATCH tag", tag)
			}
		}

		log := read_input(env, args[3]) or_return
		repository := os.get_env("GITHUB_REPOSITORY", context.allocator)
		if repository == "" {
			repository = "dvrd/krs"
		}
		fmt.print(release_notes(log, args[1], args[2], repository))
		return true
	}

	if len(args) != 3 || args[0] != "next" {
		return krs.fail(
			env,
			"usage: version latest <tag-list>, version next <base-tag> <git-log> or " +
			"version notes <base-tag> <next-tag> <git-log>",
		)
	}

	base, valid := krs.parse_tag(args[1])
	if !valid {
		return krs.fail(env, "%s must be a vMAJOR.MINOR.PATCH tag", args[1])
	}

	messages := read_input(env, args[2]) or_return
	impact := release_impact(messages)
	if impact == .None {
		return true
	}

	next, ok := krs.version_bump(base, release_bump(base, impact))
	if !ok {
		return krs.fail(env, "cannot increment %s", args[1])
	}

	fmt.printf("v%d.%d.%d\n", next.major, next.minor, next.patch)
	return true
}

read_input :: proc(env: ^krs.Env, path: string) -> (content: string, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return "", krs.fail(env, "cannot read %s: %v", path, err)
	}
	return string(data), true
}

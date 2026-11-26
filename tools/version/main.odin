package main

import "core:os"

import krs "../../src"

// Releases KRS from Conventional Commits.
//
//   krs-version next
//       Prints the next release tag, or nothing when no commit since the
//       latest tag calls for a release.
//   krs-version prepare [--dry-run] <dir>
//       Builds, tests and packages the next release from HEAD into <dir>.
//
// The release workflow publishes what `prepare` writes.
main :: proc() {
	context.allocator = context.temp_allocator
	env := krs.Env{err = os.to_writer(os.stderr)}
	os.exit(krs.EXIT_OK if run(&env, os.args[1:]) else krs.EXIT_FAILED)
}

run :: proc(env: ^krs.Env, args: []string) -> bool {
	if len(args) == 1 && args[0] == "next" {
		return release_next(env)
	}

	if len(args) == 2 && args[0] == "prepare" && args[1] != "" && args[1] != "--dry-run" {
		return release_prepare(env, args[1], dry_run = false)
	}

	if len(args) == 3 && args[0] == "prepare" && args[1] == "--dry-run" && args[2] != "" {
		return release_prepare(env, args[2], dry_run = true)
	}
	return krs.fail(env, "usage: krs-version next | prepare [--dry-run] <dir>")
}

package main

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"

import krs "../../src"

Release :: struct {
	base:        string, // the latest release tag
	base_commit: string,
	next:        string, // empty when no commit since base calls for a release
}

// Prints the next release tag, or nothing when no commit since the latest tag
// calls for a release.
release_next :: proc(env: ^krs.Env) -> bool {
	head := git_head(env) or_return
	release := next_release(env, head) or_return
	if release.next == "" {
		fmt.eprintfln("krs: no release-worthy commits since %s", release.base)
		return true
	}

	fmt.println(release.next)
	return true
}

// Builds, tests and packages the next release from HEAD into `dist_path`,
// without network access. `dist/tag` is written last, only when everything
// worked. A dry run allows a dirty tree and prints the result.
release_prepare :: proc(env: ^krs.Env, dist_path: string, dry_run: bool) -> bool {
	assert(dist_path != "")

	head := git_head(env) or_return
	if !dry_run {
		guard_checkout(env, head, "commit your changes before releasing") or_return
	}

	dist := reset_dist(env, dist_path) or_return
	release := next_release(env, head) or_return
	if release.next == "" {
		fmt.printfln("krs: no release-worthy commits since %s", release.base)
		return true
	}

	range := strings.concatenate({release.base_commit, "..", head})
	log := git_output(env, "log", "-z", "--no-merges", "--format=%h%n%B", range) or_return
	notes := release_notes(log, release.base, release.next, repository_name())
	write_file(env, path_join(dist, "notes.md"), notes) or_return

	scratch, scratch_err := os.make_directory_temp("", "krs-release.*", context.allocator)
	if scratch_err != nil {
		return krs.fail(env, "cannot create a scratch directory: %v", scratch_err)
	}
	defer os.remove_all(scratch)

	// Archive the copy that is version-checked, not the shared build path.
	package_dir := path_join(scratch, "package")
	build_release(env, release.next, package_dir) or_return
	if !dry_run {
		guard_checkout(env, head, "the checkout changed while building the release") or_return
	}

	asset := package_release(env, dist, package_dir, release.next) or_return
	write_file(env, path_join(dist, "target"), strings.concatenate({head, "\n"})) or_return
	write_file(env, path_join(dist, "tag"), strings.concatenate({release.next, "\n"})) or_return
	if dry_run {
		fmt.printf("\nkrs: release %s of %s (dry run, nothing published)\n\n", release.next, head)
		fmt.print(notes)
		archive := path_join(dist, asset)
		fmt.printf("\nkrs: assets\n%s\n%s.sha256\n", archive, archive)
	}
	return true
}

// Reads the release tags and the commits between the latest one and `head`.
next_release :: proc(env: ^krs.Env, head: string) -> (release: Release, ok: bool) {
	assert(head != "")

	tags := git_output(env, "tag", "--list", "v*") or_return
	base, found := krs.highest_tag(strings.split_lines(tags))
	if !found {
		return {}, krs.fail(env, "fetch the release tags before calculating the next version")
	}

	tag_ref := strings.concatenate({"refs/tags/", base, "^{commit}"})
	base_commit := git_line(env, "rev-parse", "--verify", tag_ref) or_return
	contained := git_is_ancestor(env, base_commit, head) or_return
	if !contained {
		return {}, krs.fail(env, "this branch must contain the latest release %s", base)
	}

	range := strings.concatenate({base_commit, "..", head})
	messages := git_output(env, "log", "-z", "--format=%B", range) or_return
	next := next_tag(env, base, messages) or_return
	return Release{base = base, base_commit = base_commit, next = next}, true
}

// The tag after `base` that the commit `messages` call for, or "" for none.
next_tag :: proc(env: ^krs.Env, base_tag, messages: string) -> (next: string, ok: bool) {
	base, valid := krs.parse_tag(base_tag)
	assert(valid)

	impact := release_impact(messages)
	if impact == .None {
		return "", true
	}

	version, bumped := krs.version_bump(base, release_bump(base, impact))
	if !bumped {
		return "", krs.fail(env, "cannot increment %s", base_tag)
	}

	next = fmt.tprintf("v%d.%d.%d", version.major, version.minor, version.patch)
	assert(next != base_tag)
	return next, true
}

// Creates `path`, refuses it when it holds the checkout, and empties it.
reset_dist :: proc(env: ^krs.Env, path: string) -> (dist: string, ok: bool) {
	assert(path != "")

	if err := os.make_directory_all(path); err != nil {
		if err != .Exist || !os.is_dir(path) {
			return "", krs.fail(env, "cannot create %s: %v", path, err)
		}
	}

	dist = physical_path(env, path) or_return
	top_level := git_line(env, "rev-parse", "--show-toplevel") or_return
	top := physical_path(env, top_level) or_return

	safe, reason := dist_is_safe(dist, top)
	if !safe {
		return "", krs.fail(env, "%s", reason)
	}

	if err := os.remove_all(dist); err != nil {
		return "", krs.fail(env, "cannot remove %s: %v", dist, err)
	}

	if err := os.make_directory_all(dist); err != nil {
		return "", krs.fail(env, "cannot create %s: %v", dist, err)
	}
	return dist, true
}

// `path` with every symbolic link resolved, as `pwd -P` prints it.
physical_path :: proc(env: ^krs.Env, path: string) -> (physical: string, ok: bool) {
	assert(path != "")

	resolved := posix.realpath(strings.clone_to_cstring(path))
	if resolved == nil {
		return "", krs.fail(env, "cannot resolve %s: %s", path, posix.strerror())
	}
	defer posix.free(rawptr(resolved))

	physical = strings.clone_from_cstring(resolved)
	assert(strings.has_prefix(physical, "/"))
	return physical, true
}

// Whether the release directory `dist` may be emptied: it must not be `/` or
// contain the checkout `top`. Both are real absolute paths.
dist_is_safe :: proc(dist, top: string) -> (ok: bool, reason: string) {
	assert(dist != "")
	assert(top != "")

	if strings.has_prefix(strings.concatenate({top, "/"}), strings.concatenate({dist, "/"})) {
		return false, fmt.tprintf("refusing to use %s: it contains the checkout", dist)
	}

	if dist == "/" {
		return false, "refusing to use /"
	}
	return true, ""
}

// Runs `task check` and `task build` at version `next` and copies the binary
// into `package_dir`, checking that it reports `next`.
build_release :: proc(env: ^krs.Env, next, package_dir: string) -> bool {
	assert(next != "")
	assert(package_dir != "")

	environment := environment_with(env, "KRS_VERSION", next) or_return
	run_inherited(env, {"task", "check"}, environment) or_return
	run_inherited(env, {"task", "build"}, environment) or_return

	if err := os.make_directory_all(package_dir); err != nil {
		return krs.fail(env, "cannot create %s: %v", package_dir, err)
	}

	binary := path_join(package_dir, "krs")
	built := path_join(check_dir(), "krs")
	if err := os.copy_file(binary, built); err != nil {
		return krs.fail(env, "cannot copy %s: %v", built, err)
	}

	output := command_output(env, {binary, "--version"}) or_return
	reported := strings.trim_right(output, "\n")
	if reported != strings.concatenate({"krs ", next}) {
		return krs.fail(env, "the release binary reports '%s', not 'krs %s'", reported, next)
	}
	return true
}

// Archives the binary in `package_dir` into `dist` with its checksum file and
// returns the archive's name.
package_release :: proc(env: ^krs.Env, dist, package_dir, next: string) -> (asset: string, ok: bool) {
	assert(dist != "")
	assert(next != "")

	os_name := command_output(env, {"uname", "-s"}) or_return
	arch := command_output(env, {"uname", "-m"}) or_return
	asset = asset_name(next, strings.trim_space(os_name), strings.trim_space(arch))
	archive := path_join(dist, asset)
	command_output(env, {"tar", "-czf", archive, "-C", package_dir, "krs"}) or_return

	data, read_err := os.read_entire_file(archive, context.allocator)
	if read_err != nil {
		return "", krs.fail(env, "cannot read %s: %v", archive, read_err)
	}

	checksum := strings.concatenate({archive, ".sha256"})
	write_file(env, checksum, sha256_line(data, asset)) or_return
	return asset, true
}

// `krs-<tag>-<os>-<arch>.tar.gz` from what `uname -s` and `uname -m` print.
asset_name :: proc(tag, os_name, arch: string) -> string {
	assert(tag != "")
	assert(os_name != "")
	assert(arch != "")

	machine := "amd64" if arch == "x86_64" else arch
	return fmt.tprintf("krs-%s-%s-%s.tar.gz", tag, strings.to_lower(os_name), machine)
}

// A line in the format `shasum -a 256 <name>` prints.
sha256_line :: proc(data: []byte, name: string) -> string {
	assert(name != "")

	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&ctx, digest[:])

	line := fmt.tprintf("%s  %s\n", string(hex.encode(digest[:])), name)
	assert(len(line) == 2 * sha2.DIGEST_SIZE_256 + len("  \n") + len(name))
	return line
}

// Runs a command with this process's stdin, stdout and stderr.
run_inherited :: proc(env: ^krs.Env, command: []string, environment: []string) -> bool {
	assert(len(command) > 0)
	assert(environment != nil)

	description := os.Process_Desc {
		command = command,
		env     = environment,
		stdin   = os.stdin,
		stdout  = os.stdout,
		stderr  = os.stderr,
	}
	process, start_err := os.process_start(description)
	if start_err != nil {
		return krs.fail(env, "cannot run %s: %v", command[0], start_err)
	}

	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		return krs.fail(env, "cannot wait for %s: %v", command[0], wait_err)
	}

	if !state.success || state.exit_code != 0 {
		return krs.fail(env, "%s exited with %d", strings.join(command, " "), state.exit_code)
	}
	return true
}

// This process's environment with `key` set to `value`.
environment_with :: proc(env: ^krs.Env, key, value: string) -> (environment: []string, ok: bool) {
	assert(key != "")

	current, err := os.environ(context.allocator)
	if err != nil {
		return nil, krs.fail(env, "cannot read the environment: %v", err)
	}

	prefix := strings.concatenate({key, "="})
	result := make([dynamic]string, 0, len(current) + 1)
	for entry in current {
		if !strings.has_prefix(entry, prefix) {
			append(&result, entry)
		}
	}
	append(&result, strings.concatenate({prefix, value}))
	assert(len(result) <= len(current) + 1)
	return result[:], true
}

// Where Task builds: `${KRS_CHECK_DIR:-${TMPDIR:-/tmp}/krs-check}`.
check_dir :: proc() -> string {
	if dir := os.get_env("KRS_CHECK_DIR", context.allocator); dir != "" {
		return dir
	}

	temp := os.get_env("TMPDIR", context.allocator)
	if temp == "" {
		temp = "/tmp"
	}
	return strings.concatenate({temp, "/krs-check"})
}

repository_name :: proc() -> string {
	repository := os.get_env("GITHUB_REPOSITORY", context.allocator)
	if repository == "" {
		repository = "dvrd/krs"
	}
	return repository
}

path_join :: proc(directory, name: string) -> string {
	assert(directory != "")
	assert(name != "")
	return strings.concatenate({directory, "/", name})
}

write_file :: proc(env: ^krs.Env, path, content: string) -> bool {
	if err := os.write_entire_file(path, content); err != nil {
		return krs.fail(env, "cannot write %s: %v", path, err)
	}
	return true
}

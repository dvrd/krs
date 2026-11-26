package fixtures

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:testing"

import krs "../../src"

// Emulate GitHub with local Git objects after checking the requested HTTPS
// URL. The CLI always uses libgit2's network transport for this URL.
github_fixture_download :: proc(env: ^krs.Env, repo: ^krs.Git_Repository, directory, origin: string) -> bool {
	repository, valid := krs.github_repository_from_origin(origin)
	if !valid || origin != krs.github_origin(repository) {
		return krs.fail(env, "unexpected transport URL %q", origin)
	}
	remote := krs.path_join(krs.path_directory(env.home), "github")
	return krs.git_download_tags(env, repo, directory, krs.path_join(remote, krs.github_locator(repository)))
}

github_fixture_release :: proc(fixture: ^Fixture, owner, name, tag: string) -> string {
	previous := fixture.sources
	defer fixture.sources = previous
	fixture.sources = krs.path_join(fixture.base, krs.path_join("github", owner))
	return library_release(fixture, name, tag)
}

// A library with everything a real repository carries around its source.
alpha_release :: proc(fixture: ^Fixture) -> string {
	path := repository_make(fixture, "alpha")
	write_file(fixture.t, krs.path_join(path, "src/alpha.odin"), "package alpha\n\nRELEASE :: \"v0.1.0\"\nRUNTIME :: #load(\"assets/runtime.js\", string)\n")
	write_file(fixture.t, krs.path_join(path, "src/assets/runtime.js"), "export const released = true\n")
	write_file(fixture.t, krs.path_join(path, "src/assets/unused.js"), "export const unused = true\n")
	write_file(fixture.t, krs.path_join(path, "src/notes/design.md"), "# stray notes\n")
	write_file(fixture.t, krs.path_join(path, "src/tests/alpha_test.odin"), "package alpha_tests\n")
	write_file(fixture.t, krs.path_join(path, "tests/run.sh"), "#!/bin/sh\n")
	write_file(fixture.t, krs.path_join(path, "README.md"), "# alpha\n")
	write_file(fixture.t, krs.path_join(path, "LICENSE"), "licence text\n")

	return repository_release(fixture, "alpha", "v0.1.0")
}

// The project's record for `name`, read from .krs/packages.json.
record_of :: proc(fixture: ^Fixture, name: string, loc := #caller_location) -> krs.Package_Record {
	file: krs.Packages_File
	err := json.unmarshal(transmute([]byte)packages_text(fixture), &file)
	testing.expectf(fixture.t, err == nil, "cannot read %s: %v", krs.PACKAGES_PATH, err, loc = loc)
	for record in file.packages {
		if record.name == name {
			return record
		}
	}

	testing.expectf(fixture.t, false, "%s is not recorded", name, loc = loc)
	return {}
}

// beta v0.1.0 installed by a project that imports it; v0.2.0 released.
release_beta_upgrade :: proc(fixture: ^Fixture) {
	library_release(fixture, "beta", "v0.1.0")
	project_imports(fixture, "beta")
	expect_ok(fixture, run(fixture, "", "install", "--yes"))
	library_release(fixture, "beta", "v0.2.0")
}

// Project A pins beta v0.1.0 and imports an unpinned gamma v0.1.0. Project B,
// on the same Odin root, then moves the root's beta to v0.2.0. Returns B.
pinned_divergence :: proc(a: ^Fixture) -> Fixture {
	library_release(a, "beta", "v0.1.0")
	library_release(a, "gamma", "v0.1.0")
	project_imports(a, "beta", "gamma")
	expect_ok(a, run(a, "", "install", "--yes"))
	expect_ok(a, run(a, "", "pin", "beta"))

	b := fixture_make(a.t)
	b.root = a.root
	b.shared = a.shared
	b.home = a.home
	b.sources = a.sources
	project_imports(&b, "beta")
	expect_ok(&b, run(&b, "", "install", "--yes"))
	library_release(a, "beta", "v0.2.0")
	expect_ok(&b, run(&b, "", "update", "-u", "--yes"))
	expect_release(a, "beta", "v0.2.0")
	return b
}

// `alpha` is released recording `beta` at `beta_tag`.
alpha_recording_beta :: proc(fixture: ^Fixture, alpha_tag, beta_tag: string) {
	commit := git(fixture.t, krs.path_join(fixture.sources, "beta"), "rev-parse", fmt.aprintf("%s^{{commit}}", beta_tag))
	pins := fmt.aprintf(
		"{{\"format\": 1, \"packages\": [{{\"name\": \"beta\", \"source\": \"local\", \"tag\": \"%s\", \"commit\": \"%s\", \"hash\": \"\"}}]}}\n",
		beta_tag,
		commit,
	)

	if !os.is_directory(krs.path_join(fixture.sources, "alpha")) {
		repository_make(fixture, "alpha")
	}
	write_file(fixture.t, krs.path_join(fixture.sources, "alpha/.krs/packages.json"), pins)
	library_release(fixture, "alpha", alpha_tag, "beta")
}

// `name` is released recording `dependency` at `dependency_tag`.
library_recording :: proc(fixture: ^Fixture, name, tag, dependency, dependency_tag: string) {
	commit := git(fixture.t, krs.path_join(fixture.sources, dependency), "rev-parse", fmt.aprintf("%s^{{commit}}", dependency_tag))
	pins := fmt.aprintf(
		"{{\"format\": 1, \"packages\": [{{\"name\": \"%s\", \"source\": \"local\", \"tag\": \"%s\", \"commit\": \"%s\", \"hash\": \"\"}}]}}\n",
		dependency,
		dependency_tag,
		commit,
	)

	if !os.is_directory(krs.path_join(fixture.sources, name)) {
		repository_make(fixture, name)
	}
	write_file(fixture.t, krs.path_join(fixture.sources, fmt.aprintf("%s/.krs/packages.json", name)), pins)
	library_release(fixture, name, tag, dependency)
}

// Links `name` from a fresh source repository.
link_fresh :: proc(fixture: ^Fixture, name: string) {
	write_file(fixture.t, krs.path_join(fixture.sources, fmt.aprintf("%s/src/%s.odin", name, name)), fmt.aprintf("package %s\n", name))
	expect_ok(fixture, run(fixture, "", "link", name))
}

// Three libraries' worth of upgrades: beta v0.4.0 -> v0.5.0 (major zero) and
// gamma v0.1.0 -> v0.1.1 (patch), listed in name order.
interactive_fixture :: proc(fixture: ^Fixture) {
	library_release(fixture, "beta", "v0.4.0")
	library_release(fixture, "gamma", "v0.1.0")
	project_imports(fixture, "beta", "gamma")
	expect_ok(fixture, run(fixture, "", "install", "--yes"))
	library_release(fixture, "beta", "v0.4.1")
	library_release(fixture, "beta", "v0.5.0")
	library_release(fixture, "gamma", "v0.1.1")
}

// beta v0.4.0 and gamma v0.1.0 are installed for a project importing both;
// then beta v0.5.0 and gamma v0.1.1 are released.
upgrades_fixture :: proc(fixture: ^Fixture) {
	library_release(fixture, "beta", "v0.4.0")
	library_release(fixture, "gamma", "v0.1.0")
	project_imports(fixture, "beta", "gamma")
	expect_ok(fixture, run(fixture, "", "install", "--yes"))
	library_release(fixture, "beta", "v0.5.0")
	library_release(fixture, "gamma", "v0.1.1")
}

// A test command that fails while beta v0.5.0 is installed in `shared`.
beta_breaks_on :: proc(shared: string) -> string {
	return fmt.aprintf(`! grep -q 'RELEASE :: "v0.5.0"' %s/beta/beta.odin`, shared)
}

package krs

import "core:os"

// Gives this project its own collection: real copies of every dependency at
// the versions .krs/packages.json records, in <project>/vendor/, built with
// -collection:shared=vendor. The Odin root is left as it is.
vendor_enter :: proc(state: ^State) -> (ok: bool) {
	assert(!state.vendored)
	vendor := path_join(state.scope.project, VENDOR_DIR)
	if _, err := os.lstat(vendor, context.temp_allocator); err != .Not_Exist {
		return fail(state.env, "%s already exists; move it away before %s", vendor, "krs vendor")
	}

	if len(state.packages.packages) == 0 {
		return fail(state.env, "%s records no packages; nothing to copy into %s", PACKAGES_PATH, vendor)
	}

	for record in state.packages.packages {
		if record.tag == "" {
			return fail(state.env, "%s has no recorded release; vendor/ needs one for every package", record.name)
		}
	}

	for record in state.manifest.packages {
		if record.linked != "" && packages_find(&state.packages, record.name) != nil {
			warn(state.env, "%s is linked in %s; vendor/ gets its recorded release, not the live checkout", record.name, state.shared)
		}
	}

	previous_shared, previous_manifest := state.shared, state.manifest
	defer if !ok {
		state.shared = previous_shared
		state.manifest = previous_manifest
		state.vendored = false
	}

	plan_reset(state)
	state.shared = vendor
	state.vendored = true
	state.manifest = Manifest_File{format = FORMAT}
	plan_discover(state) or_return
	plan_drain(state) or_return
	plan_apply(state) or_return
	if !os.exists(path_join(state.shared, MANIFEST_PATH)) {
		return fail(state.env, "nothing was copied into %s", state.shared)
	}

	// Staging directories are transient; keep them out of commits.
	ignore := path_join(state.shared, ".gitignore")
	if !os.exists(ignore) {
		if err := os.write_entire_file(ignore, ".krs-stage-*\n"); err != nil {
			warn(state.env, "cannot write %s: %v", ignore, err)
		}
	}

	note(state.env, "this project now uses %s; build it with %s", state.shared, "-collection:shared=vendor")
	return true
}

// `krs vendor`: switches this project to its own vendor/ collection.
command_vendor :: proc(env: ^Env, options: Options) -> bool {
	if options.frozen {
		return fail(env, "--frozen does not apply to vendor")
	}

	state := state_open(env, options) or_return
	defer state_close(state)
	state.fetch_configured = true
	if state.vendored {
		info(env, "this project already uses %s", state.shared)
		return true
	}

	return vendor_enter(state)
}

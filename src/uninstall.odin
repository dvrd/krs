package krs

import "core:os"
import "core:slice"
import "core:strings"

// `krs uninstall <package>...`: removes exactly the named packages from this
// project's lockfile and from state.shared (the Odin root's shared/, or
// vendor/), in one transaction. Their dependencies stay. A package the code
// still imports is removed anyway, with a warning naming the importers.
command_uninstall :: proc(env: ^Env, options: Options, names: []string) -> bool {
	assert(len(names) > 0) // the caller chooses the names; none is a usage error

	if options.frozen {
		return fail(env, "--frozen does not apply to uninstall")
	}

	unique := make([dynamic]string, context.temp_allocator)
	for name in names {
		if !is_package_name(name) {
			return fail(env, "\"%s\" is not a usable package name", name)
		}

		append_unique(&unique, name)
	}
	assert(len(unique) > 0)
	assert(len(unique) <= len(names))

	state := state_open(env, options) or_return
	defer state_close(state)

	// Every check runs before anything is written, so the uninstall is
	// all-or-nothing.
	for name in unique {
		uninstall_check(state, name) or_return
	}

	uninstall_describe(state, unique[:])
	if !options.yes {
		if !env.interactive {
			return fail(env, "confirmation is needed: run in a terminal, or pass --yes")
		}

		if !ask_yes(env, "Proceed?") {
			return fail(env, "nothing was changed")
		}
	}

	transaction := Transaction{env = env, scope = state.scope}
	defer transaction_close(&transaction)
	manifest_changed := false
	for name in unique {
		changed := uninstall_stage(state, &transaction, name) or_return
		if changed {
			manifest_changed = true
		}
	}

	if manifest_changed {
		stage_manifest(&transaction, state.shared, &state.manifest) or_return
	}

	stage_packages(&transaction, path_join(state.scope.project, PACKAGES_PATH), state.packages) or_return
	transaction_commit(&transaction) or_return

	success(env, "removed %s from %s", strings.join(unique[:], ", ", context.temp_allocator), state.shared)
	for name in unique {
		uninstall_report_importers(state, name)
	}
	return true
}

// A package can be uninstalled when this project records it and it is not a
// development link, which `krs unlink` owns.
uninstall_check :: proc(state: ^State, name: string) -> bool {
	assert(is_package_name(name))

	if packages_find(&state.packages, name) == nil {
		return fail(state.env, "%s is not recorded in %s", name, PACKAGES_PATH)
	}

	record := manifest_find(&state.manifest, name)
	if record != nil && record.linked != "" {
		return fail(state.env, "%s is linked in %s; run krs unlink %s first", name, state.shared, name)
	}

	return true
}

// Only a directory krs recorded in the manifest is removed; anything else at
// shared/<name> is not krs's to delete.
uninstall_installed :: proc(state: ^State, name: string) -> bool {
	if manifest_find(&state.manifest, name) == nil {
		return false
	}

	return os.is_directory(path_join(state.shared, name))
}

uninstall_describe :: proc(state: ^State, names: []string) {
	assert(len(names) > 0)

	say(state.env, "krs will remove from %s:", state.shared)
	for name in names {
		record := packages_find(&state.packages, name)
		assert(record != nil)

		suffix := ""
		if !uninstall_installed(state, name) {
			suffix = " (not installed; only the record)"
		} else if record.pinned {
			suffix = " (pinned)"
		}

		say(state.env, "  %s %s%s", name, record.tag, suffix)
	}

	// Every project on the root shares its shared/, and krs keeps no list of
	// those projects: this warning is the only guard.
	if !state.vendored {
		warn(state.env, "other projects using the Odin root %s may still need these packages", path_directory(state.shared))
	}
}

// Stages the removal of one package and drops its records. Returns whether
// the manifest changed.
uninstall_stage :: proc(state: ^State, transaction: ^Transaction, name: string) -> (manifest_changed: bool, ok: bool) {
	target := path_join(state.shared, name)
	recorded := manifest_find(&state.manifest, name) != nil
	if recorded {
		if os.is_directory(target) {
			// No replacement: publishing moves the directory to the backup.
			change := transaction_stage(transaction, target, .Package) or_return
			change.staged = ""
		}

		manifest_remove(&state.manifest, name)
		assert(manifest_find(&state.manifest, name) == nil)
	} else {
		if path_present(target) {
			warn(state.env, "left %s in place; krs did not install it", target)
		}
	}

	packages_remove(&state.packages, name)
	assert(packages_find(&state.packages, name) == nil)
	return recorded, true
}

packages_remove :: proc(file: ^Packages_File, name: string) {
	for record, index in file.packages {
		if record.name == name {
			ordered_remove(&file.packages, index)
			return
		}
	}
}

// Warns when the project's code or one of its remaining packages still
// imports `name`, because the next `krs install` would bring it back.
uninstall_report_importers :: proc(state: ^State, name: string) {
	importers, ok := uninstall_importers(state.scope.project, name)
	if !ok {
		warn(state.env, "cannot read the Odin files under %s to check for imports of %s", state.scope.project, name)
	}

	for record in state.packages.packages {
		assert(record.name != name)

		directory := path_join(state.shared, record.name)
		if !path_present(directory) {
			continue
		}

		imports, scanned := scan_directory_imports(directory, record.name, false)
		if scanned && slice.contains(imports[:], name) {
			append(&importers, record.name)
		}
	}

	if len(importers) == 0 {
		return
	}

	warn(state.env, "%s is still imported by: %s", name, strings.join(importers[:], ", ", context.temp_allocator))
	note(state.env, "%s will install it again; remove those imports to keep it out", "krs install")
}

// The project-relative `.odin` files under `project` that import
// `shared:<name>`. Walks like scan_directory_imports: a krs vendor/ and nested
// projects are not this project's code.
uninstall_importers :: proc(project, name: string) -> (importers: [dynamic]string, ok: bool) {
	assert(project != "")
	assert(is_package_name(name))

	files: [dynamic]string
	list_files(project, "", .Project, &files, true) or_return
	skip_vendor := os.exists(path_join(path_join(project, VENDOR_DIR), MANIFEST_PATH))
	for file in files {
		if skip_vendor && strings.has_prefix(file, VENDOR_DIR + "/") {
			continue
		}

		if path_extension(file) != ".odin" {
			continue
		}

		data, err := os.read_entire_file(path_join(project, file), context.allocator)
		if err != nil {
			return importers, false
		}

		scan := scan_source(string(data))
		if slice.contains(scan.shared_imports[:], name) {
			append(&importers, file)
		}
	}
	slice.sort(importers[:])

	return importers, true
}

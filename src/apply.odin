package krs

import "core:fmt"
import "core:os"
import "core:slice"

// Reads the bytes of every file an install will write and hashes them.
decision_prepare :: proc(state: ^State, decision: ^Decision) -> bool {
	release, ok := git_release_open(decision.repository, decision.tag, decision.commit)
	if !ok {
		return fail(state.env, "cannot read %s %s from %s", decision.name, decision.tag, decision.repository)
	}
	defer git_release_close(release)
	decision_selection(state, decision, release) or_return
	if !decision.selection.has_odin_files {
		return fail(state.env, "%s %s has no Odin files to install", decision.name, decision.tag)
	}

	source := Source{release = release}
	hasher: Hasher
	hasher_init(&hasher)
	clear(&decision.contents)

	for file in decision.selection.files {
		data, read_ok := source_read(source, file.repository_path)
		if !read_ok {
			return fail(state.env, "cannot read %s from %s %s", file.repository_path, decision.name, decision.tag)
		}
		append(&decision.contents, data)
		hasher_add(&hasher, file.install_path, data)
	}
	decision.hash = hasher_finish(&hasher)

	pin := packages_find(&state.packages, decision.name)
	if pin != nil && pin.tag == decision.tag && pin.hash != "" && pin.hash != decision.hash {
		return fail(state.env, "%s %s does not match the content hash this project recorded", decision.name, decision.tag)
	}
	for warning in decision.selection.warnings {
		warn(state.env, "%s %s: %v", decision.name, decision.tag, warning)
	}

	return true
}

// The project's records after this run: every managed package it reaches.
// A record for a linked or unmanaged name is kept as it was.
plan_packages :: proc(state: ^State) -> Packages_File {
	file := Packages_File{format = FORMAT}

	for name in state.order {
		decision := state.decisions[name]
		if !decision.recorded {
			continue
		}

		switch decision.action {
		case .Keep, .Install:
			existing := packages_find(&state.packages, name)
			append(
				&file.packages,
				Package_Record {
					name = name,
					source = source_identity(decision.source),
					tag = decision.tag,
					commit = decision.commit,
					hash = decision.hash,
					pinned = (existing != nil && existing.pinned) || state.pin_names[name],
				},
			)
		case .Linked, .Unmanaged:
			existing := packages_find(&state.packages, name)
			if existing != nil {
				append(&file.packages, existing^)
			}
		}
	}
	slice.sort_by(file.packages[:], proc(a, b: Package_Record) -> bool {
		return a.name < b.name
	})

	return file
}

packages_equal :: proc(a, b: ^Packages_File) -> bool {
	if len(a.packages) != len(b.packages) {
		return false
	}

	for record in a.packages {
		other := packages_find(b, record.name)
		if other == nil {
			return false
		}

		current := record
		current.source = source_identity(current.source)
		expected := other^
		expected.source = source_identity(expected.source)
		if expected != current {
			return false
		}
	}

	return true
}

// Stage the selected files and set the corresponding manifest record.
decision_stage :: proc(state: ^State, transaction: ^Transaction, decision: ^Decision) -> bool {
	target := path_join(state.shared, decision.name)
	record := manifest_find(&state.manifest, decision.name)
	change := stage_package_path(transaction, target, record) or_return
	for file, index in decision.selection.files {
		path := path_join(change.staged, file.install_path)
		parent := path_directory(path)
		if err := os.make_directory_all(parent); err != nil && !os.is_directory(parent) {
			return fail(state.env, "cannot stage %s: %v", file.install_path, err)
		}

		if err := os.write_entire_file(path, decision.contents[index]); err != nil {
			return fail(state.env, "cannot stage %s: %v", file.install_path, err)
		}
	}

	manifest_put(
		&state.manifest,
		Manifest_Record {
			name = decision.name,
			source = decision.source,
			tag = decision.tag,
			commit = decision.commit,
			hash = decision.hash,
			path = "" if state.vendored else decision.repository,
		},
	)

	return true
}

// Lists the local changes a repair discards.
plan_describe_repair :: proc(state: ^State, decision: ^Decision) {
	directory := path_join(state.shared, decision.name)
	changed, added, missing, ok := installed_differences(directory, decision.selection, decision.contents[:])
	if !ok {
		warn(state.env, "cannot list the files of %s; all of it is replaced", directory)
		return
	}

	for file in changed {
		say(state.env, "    %v shared/%s/%s", paint(state.env, ANSI_YELLOW, "changed"), decision.name, file)
	}
	for file in added {
		say(state.env, "    %v shared/%s/%s", paint(state.env, ANSI_GREEN, "added"), decision.name, file)
	}
	for file in missing {
		say(state.env, "    %v shared/%s/%s", paint(state.env, ANSI_RED, "missing"), decision.name, file)
	}
	warn(state.env, "%s: these local changes are discarded when the release is reinstalled", decision.name)
}

plan_describe :: proc(state: ^State, decision: ^Decision) {
	from := paint(state.env, ANSI_DIM, fmt.tprintf("(from %s)", decision.repository))
	if decision.repair {
		say(state.env, "  %v %s %s %v", paint(state.env, ANSI_YELLOW, "repair"), decision.name, decision.tag, from)
		plan_describe_repair(state, decision)
		return
	}

	if decision.installed_tag == "" {
		say(state.env, "  %v %s %s %v", paint(state.env, ANSI_GREEN, "install"), decision.name, decision.tag, from)
		return
	}

	say(state.env, "  %v %s %s with %s %v", paint(state.env, ANSI_YELLOW, "replace"), decision.name, decision.installed_tag, decision.tag, from)
}

plan_frozen_check :: proc(state: ^State, packages: ^Packages_File) -> bool {
	for name in state.order {
		decision := state.decisions[name]
		#partial switch decision.action {
		case .Linked:
			record := manifest_find(&state.manifest, name)
			return fail(state.env, "--frozen: %s is linked to %s", name, record.linked)
		case .Unmanaged:
			if packages_find(&state.packages, name) != nil {
				return fail(state.env, "--frozen: cannot verify the recorded version of unmanaged package %s", name)
			}
		}
	}

	if len(state.altered) > 0 {
		return fail(state.env, "--frozen: %s does not match its recorded hash", state.altered[0])
	}

	if !packages_equal(packages, &state.packages) {
		return fail(state.env, "--frozen: %s would change", PACKAGES_PATH)
	}

	return true
}

Project_Pins :: enum {
	Record,
	Preserve,
}

// Records the decided versions in .krs/packages.json without installing
// them; `krs install` installs them later.
plan_record_only :: proc(state: ^State) -> bool {
	for name in state.order {
		decision := state.decisions[name]
		if decision.action == .Install {
			decision_prepare(state, decision) or_return
		}
	}

	packages := plan_packages(state)
	if packages_equal(&packages, &state.packages) {
		success(state.env, "%s is already up to date", PACKAGES_PATH)
		return true
	}

	transaction := Transaction{env = state.env, scope = state.scope}
	defer transaction_close(&transaction)
	stage_packages(&transaction, path_join(state.scope.project, PACKAGES_PATH), packages) or_return
	transaction_commit(&transaction) or_return
	success(state.env, "%s records the new versions; run %s to install them", PACKAGES_PATH, "krs install")
	return true
}

// Carries out the decisions: confirm, write `shared/`, then the records.
plan_apply :: proc(state: ^State, project_pins := Project_Pins.Record) -> bool {
	installs: [dynamic]^Decision
	for name in state.order {
		decision := state.decisions[name]
		if decision.action == .Install {
			decision_prepare(state, decision) or_return
			append(&installs, decision)
		}
	}

	for record in state.manifest.packages {
		decision := state.decisions[record.name]
		if record.linked != "" && (decision == nil || decision.action == .Linked) {
			say(state.env, "%v %s %v %s", paint(state.env, ANSI_CYAN, "linked:"), record.name, paint(state.env, ANSI_DIM, "->"), record.linked)
		}
	}

	packages := plan_packages(state)
	if state.options.frozen {
		plan_frozen_check(state, &packages) or_return
	}

	if len(installs) > 0 {
		say(state.env, "krs will change %s:", state.shared)
		for decision in installs {
			plan_describe(state, decision)
		}

		if !state.options.frozen && !state.options.yes {
			if !state.env.interactive {
				return fail(state.env, "confirmation is needed: run in a terminal, or pass --yes")
			}

			if !ask_yes(state.env, "Proceed?") {
				return fail(state.env, "nothing was changed")
			}
		}
	}

	transaction := Transaction{env = state.env, scope = state.scope}
	defer transaction_close(&transaction)

	for decision in installs {
		decision_stage(state, &transaction, decision) or_return
	}

	if len(installs) > 0 {
		stage_manifest(&transaction, state.shared, &state.manifest) or_return
	}

	if project_pins == .Record && !packages_equal(&packages, &state.packages) {
		stage_packages(&transaction, path_join(state.scope.project, PACKAGES_PATH), packages) or_return
	}

	transaction_commit(&transaction) or_return

	success(state.env, "%d installed, %d already in place", len(installs), len(state.order) - len(installs))
	return true
}

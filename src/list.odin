package krs

import "core:fmt"
import "core:slice"
import "core:strings"

// One package of `krs ls`: what this project records, why it has it, and
// what the Odin root holds for it.
List_Row :: struct {
	name:      string,
	tag:       string, // as .krs/packages.json records it; "" when not recorded
	origin:    string, // "imported", "via surf, aws", "not used", or "unknown"
	installed: string, // "installed", "linked -> …", "root has v1.2.0", "missing"
	color:     string,
	pinned:    bool,
	attention: bool,
}

// `krs ls`: the packages of this project and their versions.
command_list :: proc(env: ^Env, options: Options) -> bool {
	if options.frozen || options.yes {
		return fail(env, "ls takes only --root")
	}

	state := state_open(env, options) or_return
	defer state_close(state)

	imports, scanned := scan_directory_imports(env.project, path_base(env.project), true)
	if !scanned {
		return fail(env, "cannot read the Odin files under %s", env.project)
	}

	rows := list_rows(state, imports[:])
	if len(rows) == 0 {
		info(env, "this project imports no shared: packages and records none")
		return true
	}

	name_width, tag_width, origin_width := 0, 0, 0
	attention := 0
	for row in rows {
		name_width = max(name_width, len(row.name))
		tag_width = max(tag_width, len(row.tag))
		origin_width = max(origin_width, len(row.origin))
		if row.attention {
			attention += 1
		}
	}

	info(env, "%d package(s) in %s", len(rows), PACKAGES_PATH)
	for row in rows {
		pin := paint(env, ANSI_CYAN, "  pinned") if row.pinned else ""
		say(
			env,
			"  %-*s  %-*s  %v  %v%v",
			name_width,
			row.name,
			tag_width,
			row.tag,
			paint(env, ANSI_DIM, fmt.tprintf("%-*s", origin_width, row.origin)),
			paint(env, row.color, row.installed),
			pin,
		)
	}

	if attention > 0 {
		note(env, "run %s to install what is missing or out of date", "krs install")
	}
	return true
}

// The recorded packages, then the imports not recorded yet, sorted by name.
list_rows :: proc(state: ^State, imports: []string) -> [dynamic]List_Row {
	importers, complete := list_importers(state)
	rows: [dynamic]List_Row
	for record in state.packages.packages {
		row := List_Row{name = record.name, tag = record.tag, pinned = record.pinned}
		row.origin = list_origin(record.name, imports, importers[record.name][:], complete)
		row.installed, row.color, row.attention = list_installed(state, record)
		append(&rows, row)
	}

	for name in imports {
		if packages_find(&state.packages, name) == nil {
			append(&rows, List_Row{name = name, origin = "imported", installed = list_unrecorded(state, name), color = ANSI_YELLOW, attention = true})
		}
	}

	slice.sort_by(rows[:], proc(a, b: List_Row) -> bool {return a.name < b.name})
	return rows
}

// What the root holds for an import .krs/packages.json does not record yet;
// `krs install` records it either way.
list_unrecorded :: proc(state: ^State, name: string) -> string {
	held := manifest_find(&state.manifest, name)
	if held == nil || !path_present(path_join(state.shared, name)) {
		return "not installed"
	}

	if held.linked != "" {
		return fmt.tprintf("not recorded; linked -> %s", held.linked)
	}
	return fmt.tprintf("not recorded; %s has %s", "vendor/" if state.vendored else "root", held.tag)
}

// Why the project has `name`: its own import, the recorded packages that
// import it, or neither. `complete` is false when a package could not be
// scanned, so "not used" cannot be told.
list_origin :: proc(name: string, imports, importers: []string, complete := true) -> string {
	if slice.contains(imports, name) {
		return "imported"
	}

	if len(importers) > 0 {
		return fmt.tprintf("via %s", strings.join(importers, ", ", context.temp_allocator))
	}
	return "not used" if complete else "unknown"
}

// For each recorded package, the other recorded packages whose installed
// files import it. Not `complete` when a package could not be scanned.
list_importers :: proc(state: ^State) -> (importers: map[string][dynamic]string, complete: bool) {
	importers = make(map[string][dynamic]string, context.temp_allocator)
	complete = true
	for record in state.packages.packages {
		directory := path_join(state.shared, record.name)
		if installed := manifest_find(&state.manifest, record.name); installed != nil && installed.linked != "" {
			directory = installed.linked
		}

		imported, scanned := scan_directory_imports(directory, record.name, false)
		if !scanned {
			complete = false
			continue
		}

		for name in imported {
			if packages_find(&state.packages, name) == nil {
				continue
			}

			list := importers[name]
			append(&list, record.name)
			importers[name] = list
		}
	}

	for _, &list in importers {
		slice.sort(list[:])
	}
	return importers, complete
}

// What the Odin root (or vendor/) holds for a recorded package.
list_installed :: proc(state: ^State, record: Package_Record) -> (text, color: string, attention: bool) {
	installed := manifest_find(&state.manifest, record.name)
	if installed == nil || !path_present(path_join(state.shared, record.name)) {
		return "missing", ANSI_YELLOW, true
	}

	if installed.linked != "" {
		link, _ := link_state(state.shared, installed^)
		if link != .Working {
			return fmt.tprintf("link broken -> %s", installed.linked), ANSI_YELLOW, true
		}
		return fmt.tprintf("linked -> %s", installed.linked), ANSI_CYAN, false
	}

	if installed.tag != record.tag {
		holder := "vendor/" if state.vendored else "root"
		return fmt.tprintf("%s has %s", holder, installed.tag), ANSI_YELLOW, true
	}
	return "installed", ANSI_GREEN, false
}

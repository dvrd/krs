package krs

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"

USAGE_FORMAT :: `%[0]susage:%[1]s
  krs %[0]sinstall%[1]s [--root=<path>] [--frozen] [--yes]
  krs %[0]supdate%[1]s [<package>[@<tag>]] [--root=<path>] [--yes]
  krs %[0]sfetch%[1]s <owner>/<repo>
  krs %[0]slink%[1]s <package> [--root=<path>]
  krs %[0]slink ls%[1]s [--root=<path>]
  krs %[0]sunlink%[1]s <package> [--root=<path>] [--restore] [--yes]
  krs %[0]s--version%[1]s
  krs %[0]s--help%[1]s

  %[0]s--root=<path>%[1]s  work on the shared/ of the Odin root at <path>
  %[0]s--frozen%[1]s       install exactly what .krs/packages.json says, or fail
  %[0]s--restore%[1]s      after unlink, install the recorded release in its place
  %[0]s--yes%[1]s          do not ask before writing
`

EXIT_OK :: 0
EXIT_FAILED :: 1
EXIT_USAGE :: 2

RELEASE_TAG :: #load("VERSION", string)

print_usage :: proc(output: io.Writer, colored: bool) {
	if colored {
		fmt.wprintf(output, USAGE_FORMAT, ANSI_VALUE, ANSI_RESET)
	} else {
		fmt.wprintf(output, USAGE_FORMAT, "", "")
	}
}

// Runs one krs command. `arguments` excludes the program name.
run :: proc(env: ^Env, arguments: []string) -> int {
	if len(arguments) == 1 && arguments[0] == "--version" {
		tag := strings.trim_space(RELEASE_TAG)
		if _, valid := parse_tag(tag); !valid {
			fail(env, "VERSION must contain a vMAJOR.MINOR.PATCH tag")
			return EXIT_FAILED
		}

		say(env, "krs %s", tag)
		return EXIT_OK
	}

	if len(arguments) == 1 && arguments[0] == "--help" {
		print_usage(env.out, env.style.stdout && env.style.color)
		return EXIT_OK
	}

	options: Options
	words: [dynamic]string

	for argument in arguments {
		switch {
		case argument == "--frozen":
			options.frozen = true
		case argument == "--yes":
			options.yes = true
		case argument == "--restore":
			options.restore = true
		case strings.has_prefix(argument, "--root="):
			options.root = argument[len("--root="):]
		case strings.has_prefix(argument, "-"):
			fail(env, "unknown option %s", argument)
			return EXIT_USAGE
		case:
			append(&words, argument)
		}
	}

	if options.restore && (len(words) == 0 || words[0] != "unlink") {
		fail(env, "--restore only applies to unlink")
		return EXIT_USAGE
	}

	if len(words) == 0 {
		print_usage(env.err, env.style.stderr && env.style.color)
		return EXIT_USAGE
	}

	ok := false
	switch {
	case words[0] == "install" && len(words) == 1:
		ok = command_install(env, options)
	case words[0] == "update" && len(words) == 1:
		ok = command_outdated(env, options)
	case words[0] == "update" && len(words) == 2:
		ok = command_update(env, options, words[1])
	case words[0] == "fetch" && len(words) == 2 && options.root == "" && !options.frozen && !options.yes:
		ok = command_fetch(env, words[1])
	case words[0] == "link" && len(words) == 2 && words[1] == "ls":
		ok = command_link_list(env, options)
	case words[0] == "link" && len(words) == 2:
		ok = command_link(env, options, words[1])
	case words[0] == "unlink" && len(words) == 2:
		ok = command_unlink(env, options, words[1])
	case:
		print_usage(env.err, env.style.stderr && env.style.color)
		return EXIT_USAGE
	}

	return EXIT_OK if ok else EXIT_FAILED
}

command_install :: proc(env: ^Env, options: Options) -> bool {
	state := state_open(env, options) or_return
	defer state_close(state)
	state.fetch_configured = true
	plan_discover(state) or_return
	plan_drain(state) or_return

	return plan_apply(state)
}

// `krs update` with no argument: lists newer tags and changes nothing.
command_outdated :: proc(env: ^Env, options: Options) -> bool {
	state := state_open(env, options) or_return
	defer state_close(state)
	found := 0
	unavailable := 0

	for record in state.manifest.packages {
		if record.linked != "" || packages_find(&state.packages, record.name) == nil {
			continue
		}

		repository, ok := repository_find(state, record.name, "", record.source)
		if !ok {
			warn(env, "cannot check %s: no usable repository", record.name)
			unavailable += 1
			continue
		}

		highest, _ := highest_tag(repository.tags[:])
		current_version, current_ok := parse_tag(record.tag)
		highest_version, _ := parse_tag(highest)
		if !current_ok {
			warn(env, "cannot check %s: invalid installed tag %s", record.name, record.tag)
			unavailable += 1
			continue
		}

		if version_compare(highest_version, current_version) != .Higher {
			continue
		}

		compatibility := version_compatibility(current_version, highest_version)
		say_version_change(env, record.name, record.tag, highest, compatibility)
		found += 1
	}

	if unavailable > 0 {
		return fail(env, "could not check %d package(s) for updates", unavailable)
	}

	if found == 0 {
		success(env, "every package of this project is at its highest tag")
	}

	return true
}

// Lists the installed packages whose own records name another version.
update_report_dependants :: proc(state: ^State, name, tag: string) {
	for record in state.manifest.packages {
		if record.name == name || record.linked != "" {
			continue
		}

		release, ok := git_release_open(record.path, record.tag, record.commit)
		if !ok {
			continue
		}
		defer git_release_close(release)
		pins, problem := release_pins(release)
		if problem != "" {
			warn(state.env, "%s %s: %s %v", record.name, record.tag, PACKAGES_PATH, problem)
			continue
		}

		pin := packages_find(&pins, name)
		if pin != nil && pin.tag != tag {
			say(state.env, "  %s %s recorded %s %s", record.name, record.tag, name, pin.tag)
		}
	}
}

command_update :: proc(env: ^Env, options: Options, target: string) -> bool {
	name := target
	tag := ""
	at := strings.index_byte(target, '@')
	if at >= 0 {
		name = target[:at]
		tag = target[at + 1:]
		if _, valid := parse_tag(tag); !valid {
			return fail(env, "%s is not a vMAJOR.MINOR.PATCH tag", tag)
		}
	}

	if options.frozen {
		return fail(env, "--frozen does not apply to update")
	}

	state := state_open(env, options) or_return
	defer state_close(state)
	record := manifest_find(&state.manifest, name)
	if record == nil {
		return fail(env, "%s was not installed by krs in %s", name, state.shared)
	}

	if record.linked != "" {
		return fail(env, "%s is linked; run krs unlink %s first", name, name)
	}

	repository, found := repository_find(state, name, tag, record.source)
	if !found {
		return fail(env, "no usable repository for \"%s\" in the source directories or repository store", name)
	}

	if tag == "" {
		tag, _ = highest_tag(repository.tags[:])
	}

	if tag == record.tag {
		repository_tag_commit(env, repository.path, name, tag, record.commit) or_return
		success(env, "%s is already at %s", name, tag)
		return true
	}

	old_version, old_ok := parse_tag(record.tag)
	new_version, _ := parse_tag(tag)
	compatibility := Version_Compatibility.Breaking
	if old_ok {
		compatibility = version_compatibility(old_version, new_version)
	}

	say_version_change(env, name, record.tag, tag, compatibility)
	update_report_dependants(state, name, tag)

	append(&state.queue, Request{name = name, tag = tag, source = record.source, by = "krs update", kind = .Update, recorded = true})
	plan_discover(state) or_return
	plan_drain(state) or_return

	return plan_apply(state)
}

// Prints `name from -> to (compatibility)` for an available or chosen update.
say_version_change :: proc(env: ^Env, name, from, to: string, compatibility: Version_Compatibility) {
	color := ANSI_GREEN if compatibility == .Compatible else ANSI_YELLOW
	label := paint(env, color, version_compatibility_label(compatibility))
	say(env, "%s %s %v %s (%v)", name, from, paint(env, ANSI_DIM, "->"), to, label)
}

// Finds the directory to link: the first `<source directory>/<name>` that has
// a `src/`.
link_find :: proc(state: ^State, name: string) -> (repository: string, ok: bool) {
	for directory in state.config.source_directories {
		candidate := path_join(directory, name)
		if !os.is_directory(candidate) {
			continue
		}

		if os.is_directory(path_join(candidate, "src")) {
			return candidate, true
		}

		report_once(state, "skipped %s: it has no src/", candidate)
	}

	return "", false
}

command_link :: proc(env: ^Env, options: Options, name: string) -> bool {
	if !is_package_name(name) {
		return fail(env, "\"%s\" is not a usable package name", name)
	}

	if options.frozen {
		return fail(env, "--frozen does not apply to link")
	}

	state := state_open(env, options) or_return
	defer state_close(state)
	repository, found := link_find(state, name)
	if !found {
		return fail(env, "no repository with a src/ for \"%s\" in the source directories", name)
	}

	target := path_join(state.shared, name)
	source := path_join(repository, "src")
	record := manifest_find(&state.manifest, name)
	if record == nil && path_present(target) {
		return fail(env, "%s is not managed by krs; remove it by hand before linking", target)
	}

	if record != nil && record.linked == source {
		current, read_err := os.read_link(target, context.temp_allocator)
		if read_err == nil && current == source {
			info(env, "%s is already linked to %s; nothing to do", name, source)
			return true
		}
	}

	transaction := Transaction{env = env, scope = state.scope}
	defer transaction_close(&transaction)
	change := stage_package_path(&transaction, target, record) or_return
	if err := os.symlink(source, change.staged); err != nil {
		return fail(env, "cannot stage link to %s: %v", source, err)
	}

	updated := Manifest_Record{name = name}
	if record != nil {
		updated = record^
	}
	updated.path = repository
	updated.linked = source
	if updated.source == "" {
		updated.source = SOURCE_LOCAL
		if repo, ok := git_open(repository); ok {
			defer git_close(repo)
			updated.source = git_source(repo)
		}
	}
	manifest_put(&state.manifest, updated)
	stage_manifest(&transaction, state.shared, &state.manifest) or_return
	transaction_commit(&transaction) or_return

	success(env, "%s is linked to %s; every project on this Odin root now builds against it", name, source)
	return true
}

// Lists the linked packages of the Odin root and what is wrong with each link.
command_link_list :: proc(env: ^Env, options: Options) -> bool {
	if options.frozen || options.yes {
		return fail(env, "link ls takes only --root")
	}

	state := state_open(env, options) or_return
	defer state_close(state)

	width := 0
	count := 0
	for record in state.manifest.packages {
		if record.linked != "" {
			width = max(width, len(record.name))
			count += 1
		}
	}

	if count == 0 {
		info(env, "no packages are linked in %s", state.shared)
		return true
	}

	info(env, "%d linked in %s", count, state.shared)
	broken := 0
	for record in state.manifest.packages {
		if record.linked == "" {
			continue
		}

		padding := strings.repeat(" ", width - len(record.name), context.temp_allocator)
		problem := link_problem(state.shared, record)
		if problem == "" {
			say(env, "  %s%v %v %s", record.name, padding, paint(env, ANSI_DIM, "->"), record.linked)
		} else {
			broken += 1
			say(env, "  %s%v %v %s %v", record.name, padding, paint(env, ANSI_DIM, "->"), record.linked,
				paint(env, ANSI_YELLOW, fmt.tprintf("(%s)", problem)))
		}
	}

	if broken > 0 {
		warn(env, "%d link(s) need attention; run %s to relink one", broken, "krs link <package>")
	}
	return true
}

// Describes what keeps a recorded link from working, or "" when it works.
link_problem :: proc(shared: string, record: Manifest_Record) -> string {
	target := path_join(shared, record.name)
	if !path_present(target) {
		return "missing from shared/"
	}

	current, err := os.read_link(target, context.temp_allocator)
	if err != nil {
		return "replaced by a directory"
	}

	if current != record.linked {
		return fmt.tprintf("points to %s instead", current)
	}

	if !os.is_directory(record.linked) {
		return "the source no longer exists"
	}

	return ""
}

// A linked `src/` is not filtered, so a file the code opens without naming it
// works while linked and is missing once released.
unlink_report_unnamed :: proc(state: ^State, name, repository: string) {
	selection, ok := select_files(Source{repository = repository}, name)
	if !ok || selection.prefix == "" {
		return
	}

	installed: map[string]bool
	for file in selection.files {
		installed[file.repository_path] = true
	}

	files: [dynamic]string
	list_files(repository, "src", .Source, &files)
	for file in files {
		if !installed[file] {
			warn(state.env, "%s is not named by any Odin file and will not be installed from a release", file)
		}
	}
	for warning in selection.warnings {
		warn(state.env, "%v", warning)
	}
}

command_unlink :: proc(env: ^Env, options: Options, name: string) -> bool {
	if options.frozen {
		return fail(env, "--frozen does not apply to unlink")
	}

	state := state_open(env, options) or_return
	defer state_close(state)
	record := manifest_find(&state.manifest, name)
	if record == nil || record.linked == "" {
		return fail(env, "%s is not linked in %s", name, state.shared)
	}

	tag, source, commit := record.tag, record.source, record.commit
	pin := packages_find(&state.packages, name)
	if pin != nil {
		tag, source, commit = pin.tag, pin.source, pin.commit
	}

	if options.restore && tag != "" {
		unlink_report_unnamed(state, name, record.path)
		info(env, "restoring %s %s", name, tag)
		append(&state.queue, Request{name = name, tag = tag, source = source, commit = commit, by = "krs unlink", kind = .Restore})
		plan_drain(state) or_return
		return plan_apply(state, .Preserve)
	}

	// Remove the development link and its record; `shared/` no longer has it.
	target := path_join(state.shared, name)
	transaction := Transaction{env = env, scope = state.scope}
	defer transaction_close(&transaction)
	change := transaction_stage(&transaction, target, .Link, record.linked) or_return
	change.staged = ""
	manifest_remove(&state.manifest, name)
	stage_manifest(&transaction, state.shared, &state.manifest) or_return
	transaction_commit(&transaction) or_return

	if tag == "" {
		success(env, "%s is unlinked; no version of it was recorded, so nothing was installed", name)
	} else {
		success(env, "%s is unlinked and removed from %s", name, state.shared)
		note(env, "run %s in a project that imports it to install a release again", "krs install")
	}
	return true
}

package krs

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

EXIT_OK :: 0
EXIT_FAILED :: 1
EXIT_USAGE :: 2

// Set by the build: the release tag, or `git describe` output between
// releases. "dev" when built without Task.
KRS_VERSION :: #config(KRS_VERSION, "dev")

// Runs one krs command. `arguments` excludes the program name.
run :: proc(env: ^Env, arguments: []string) -> int {
	if len(arguments) == 1 && arguments[0] == "--version" {
		say(env, "krs %s", KRS_VERSION)
		return EXIT_OK
	}

	// --color applies to every command, help included, wherever it is given.
	uncolored := make([dynamic]string, 0, len(arguments), context.temp_allocator)
	for argument in arguments {
		if argument == "--color" {
			env.style.stdout = true
			env.style.color = true
			continue
		}
		append(&uncolored, argument)
	}

	if topic, asked := help_request(uncolored[:]); asked {
		return help_run(env, topic)
	}

	options: Options
	// Options is zero-initialised; these are the defaults of `krs update`.
	options.update.format = {.Group}
	options.update.error_level = 1
	words: [dynamic]string
	update_flag := "" // the first update-only flag given, for the guard below
	log_level: Maybe(Log_Level)
	interactive_select_given := false
	doctor_flag := "" // the first of --doctor-test, --doctor-install and --doctor-timeout given

	for index := 0; index < len(arguments); index += 1 {
		argument := arguments[index]
		flag, value, inline := argument, "", false
		if strings.has_prefix(argument, "--") {
			if equals := strings.index_byte(argument, '='); equals >= 0 {
				flag, value, inline = argument[:equals], argument[equals + 1:], true
			}
		}

		if update_flag_takes_value(flag) {
			if !inline {
				if index + 1 >= len(arguments) {
					fail(env, "%s needs a value", flag)
					return EXIT_USAGE
				}
				index += 1
				value = arguments[index]
			}
		} else if inline && flag != "--root" {
			fail(env, "unknown option %s", argument)
			return EXIT_USAGE
		}

		// -g also applies to status; it is checked on its own below.
		if update_flag == "" && update_flag_only(flag) && flag != "-g" && flag != "--global" {
			update_flag = flag
		}

		switch {
		case argument == "--frozen":
			options.frozen = true
		case argument == "--yes":
			options.yes = true
		case argument == "--restore":
			options.restore = true
		case argument == "--repair":
			options.repair = true
		case argument == "--fetch":
			options.fetch = true
		case argument == "--all":
			fail(env, "--all was removed; use krs update -u -t semver")
			return EXIT_USAGE
		case flag == "--root":
			options.root = value
		case flag == "-u" || flag == "--upgrade":
			options.update.upgrade = true
		case flag == "-t" || flag == "--target":
			target, valid := update_target_parse(value)
			if !valid {
				fail(env, "%s is not a target; use latest, newest, greatest, minor, patch or semver", value)
				return EXIT_USAGE
			}
			options.update.target = target
		case flag == "-f" || flag == "--filter":
			append(&options.update.filter, value)
		case flag == "-x" || flag == "--reject":
			append(&options.update.reject, value)
		case flag == "--filter-version":
			append(&options.update.filter_version, value)
		case flag == "--reject-version":
			append(&options.update.reject_version, value)
		case flag == "--format":
			for item in strings.split(value, ",", context.temp_allocator) {
				format, enabled, valid := update_format_parse(item)
				if !valid {
					fail(env, "%s is not a format; use group, lines, time, repo, diff, installed-version or cooldown", item)
					return EXIT_USAGE
				}

				if enabled {
					options.update.format += {format}
				} else {
					options.update.format -= {format}
				}
			}
		case flag == "-j" || flag == "--json-all":
			options.update.json = .All
		case flag == "--json-upgraded":
			options.update.json = .Upgraded
		case flag == "--json-deps":
			options.update.json = .Deps
		case flag == "-e" || flag == "--error-level":
			switch value {
			case "1":
				options.update.error_level = 1
			case "2":
				options.update.error_level = 2
			case:
				fail(env, "%s is not an error level; use 1 or 2", value)
				return EXIT_USAGE
			}
		case flag == "-g" || flag == "--global":
			options.update.global = true
		case flag == "--install":
			switch value {
			case "always":
				options.update.install = .Always
			case "never":
				options.update.install = .Never
			case "prompt":
				options.update.install = .Prompt
			case:
				fail(env, "--install takes always, never or prompt")
				return EXIT_USAGE
			}
			options.update.install_given = true
		case flag == "-c" || flag == "--cooldown":
			seconds, valid := cooldown_seconds(value)
			if !valid {
				fail(env, "%s is not a cooldown period; use a number of days, or 7d, 12h or 30m", value)
				return EXIT_USAGE
			}
			options.update.cooldown = seconds
		case flag == "--pin":
			options.update.pin = true
		case flag == "-i" || flag == "--interactive":
			options.update.interactive = true
			options.update.upgrade = true
		case flag == "--interactive-select":
			switch value {
			case "auto":
				options.update.interactive_select = .Auto
			case "none":
				options.update.interactive_select = .None
			case "patch":
				options.update.interactive_select = .Patch
			case "minor":
				options.update.interactive_select = .Minor
			case "all":
				options.update.interactive_select = .All
			case:
				fail(env, "%s is not a valid --interactive-select value; use auto, none, patch, minor or all", value)
				return EXIT_USAGE
			}
			interactive_select_given = true
		case flag == "-d" || flag == "--doctor":
			options.update.doctor = true
		case flag == "--doctor-test":
			options.update.doctor_test = value
			if doctor_flag == "" {
				doctor_flag = flag
			}
		case flag == "--doctor-install":
			options.update.doctor_install = value
			if doctor_flag == "" {
				doctor_flag = flag
			}
		case flag == "--doctor-timeout":
			seconds, valid := doctor_timeout_seconds(value)
			if !valid {
				fail(env, "%s is not a timeout; use 30s, 10m or 2h", value)
				return EXIT_USAGE
			}

			options.update.doctor_timeout = seconds
			if doctor_flag == "" {
				doctor_flag = flag
			}
		case flag == "--deep":
			options.update.deep = true
		case flag == "--package-file":
			append(&options.update.package_files, value)
		case flag == "--color":
			env.style.stdout = true
			env.style.color = true
		case flag == "-s" || flag == "--silent":
			log_level = .Silent
		case flag == "-l" || flag == "--loglevel":
			level, valid := log_level_parse(value)
			if !valid {
				fail(env, "%s is not a log level; use silent, error, minimal, warn, info or verbose", value)
				return EXIT_USAGE
			}
			log_level = level
		case strings.has_prefix(argument, "-"):
			fail(env, "unknown option %s", argument)
			return EXIT_USAGE
		case:
			append(&words, argument)
		}
	}
	if level, given := log_level.?; given {
		env.level = level
	}

	if options.restore && (len(words) == 0 || words[0] != "unlink") {
		fail(env, "--restore only applies to unlink")
		return EXIT_USAGE
	}

	if options.repair && (len(words) == 0 || words[0] != "install") {
		fail(env, "--repair only applies to install")
		return EXIT_USAGE
	}

	if options.fetch && (len(words) == 0 || words[0] != "update") {
		fail(env, "--fetch only applies to update")
		return EXIT_USAGE
	}

	if update_flag != "" && (len(words) == 0 || words[0] != "update") {
		fail(env, "%s only applies to update", update_flag)
		return EXIT_USAGE
	}

	if options.update.global && (len(words) == 0 || (words[0] != "update" && words[0] != "status")) {
		fail(env, "-g only applies to update and status")
		return EXIT_USAGE
	}

	if options.update.doctor && !options.update.upgrade {
		fail(env, "--doctor needs -u")
		return EXIT_USAGE
	}

	if doctor_flag != "" && !options.update.doctor {
		fail(env, "%s needs --doctor", doctor_flag)
		return EXIT_USAGE
	}

	// Nothing would be installed, so every upgrade would pass the tests.
	if options.update.doctor && options.update.install == .Never {
		fail(env, "--doctor and --install=never cannot be combined")
		return EXIT_USAGE
	}

	// A reverted package would stay pinned at its old tag.
	if options.update.doctor && options.update.pin {
		fail(env, "--doctor and --pin cannot be combined")
		return EXIT_USAGE
	}

	// Global candidates may have no project record to restore.
	if options.update.doctor && options.update.global {
		fail(env, "--doctor and --global cannot be combined")
		return EXIT_USAGE
	}

	if options.update.doctor && options.update.json != .None {
		fail(env, "--doctor and JSON output cannot be combined")
		return EXIT_USAGE
	}

	if options.update.doctor && options.update.interactive {
		fail(env, "--doctor and -i cannot be combined")
		return EXIT_USAGE
	}

	if options.update.upgrade && options.frozen {
		fail(env, "--upgrade and --frozen cannot be combined")
		return EXIT_USAGE
	}

	// Global candidates are root-only records; this project's lockfile must
	// not receive them.
	if options.update.upgrade && options.update.global {
		fail(env, "-u and --global cannot be combined")
		return EXIT_USAGE
	}

	if interactive_select_given && !options.update.interactive {
		fail(env, "--interactive-select needs -i")
		return EXIT_USAGE
	}

	if options.update.interactive {
		for word in words[1:] {
			if strings.contains_rune(word, '@') {
				fail(env, "-i cannot be combined with name@tag")
				return EXIT_USAGE
			}
		}
	}

	deep_run := options.update.deep || len(options.update.package_files) > 0
	if deep_run && options.update.json != .None {
		fail(env, "--deep and --package-file cannot be combined with JSON output")
		return EXIT_USAGE
	}

	if deep_run && options.update.global {
		fail(env, "--deep and --global cannot be combined")
		return EXIT_USAGE
	}

	if options.update.pin && !options.update.upgrade {
		fail(env, "--pin only applies to update -u")
		return EXIT_USAGE
	}

	if options.update.install_given && !options.update.upgrade {
		fail(env, "--install only applies to update -u")
		return EXIT_USAGE
	}

	// -u writes; it does not report. `--format` is accepted and ignored.
	if options.update.upgrade && options.update.json != .None {
		json_flags := [Update_Json]string {
			.None     = "",
			.All      = "--json-all",
			.Upgraded = "--json-upgraded",
			.Deps     = "--json-deps",
		}
		fail(env, "%s cannot be combined with -u", json_flags[options.update.json])
		return EXIT_USAGE
	}

	if options.update.upgrade && options.update.error_level != 1 {
		fail(env, "--error-level cannot be combined with -u")
		return EXIT_USAGE
	}

	// JSON and `--format lines` are read by programs: only errors may be
	// printed besides them, from the start (recovery reports included).
	if options.update.json != .None || .Lines in options.update.format {
		env.level = min(env.level, Log_Level.Error)
	}

	// The chooser asks about a list it prints with `say`.
	if options.update.interactive && env.level < .Minimal {
		fail(env, "-i shows the upgrade list; it cannot be combined with --silent, --loglevel error|silent or --format lines")
		return EXIT_USAGE
	}

	if options.repair && options.frozen {
		fail(env, "--repair and --frozen cannot be combined")
		return EXIT_USAGE
	}

	if len(words) > 0 && words[0] == "fetch" {
		flag := ""
		switch {
		case options.root != "":
			flag = "--root"
		case options.frozen:
			flag = "--frozen"
		case options.yes:
			flag = "--yes"
		}

		if flag != "" {
			fail(env, "%s does not apply to fetch", flag)
			return EXIT_USAGE
		}
	}

	if len(words) > 0 && words[0] == "recover" && options.root != "" {
		fail(env, "--root does not apply to recover")
		return EXIT_USAGE
	}

	if len(words) > 0 && words[0] == "recover" && options.frozen {
		fail(env, "--frozen does not apply to recover")
		return EXIT_USAGE
	}

	if len(words) == 0 {
		print_misuse(env, "")
		return EXIT_USAGE
	}

	if (words[0] == "pin" || words[0] == "unpin") && (options.frozen || options.yes) {
		fail(env, "%s does not apply to %s", "--frozen" if options.frozen else "--yes", words[0])
		return EXIT_USAGE
	}

	ok := false
	switch {
	case words[0] == "install" && len(words) == 1:
		ok = command_install(env, options)
	case words[0] == "status" && len(words) == 1:
		ok = command_status(env, options)
	case words[0] == "ls" && len(words) == 1:
		ok = command_list(env, options)
	case words[0] == "update" && deep_run:
		ok = command_update_deep(env, options, words[:])
	case words[0] == "update":
		ok = update_dispatch(env, options, words[:])
	case words[0] == "fetch" && len(words) == 1:
		ok = command_fetch_all(env)
	case words[0] == "fetch" && len(words) == 2:
		ok = command_fetch(env, words[1])
	case words[0] == "link" && len(words) == 2 && words[1] == "ls":
		// `ls` stays reserved, so it is never linked as a package.
		fail(env, "link ls was removed; %s lists the links and flags broken ones", "krs status -g")
		return EXIT_USAGE
	case words[0] == "link" && len(words) == 2:
		ok = command_link(env, options, words[1])
	case words[0] == "unlink" && len(words) == 2:
		ok = command_unlink(env, options, words[1])
	case words[0] == "uninstall" && len(words) >= 2:
		ok = command_uninstall(env, options, words[1:])
	case words[0] == "uninstall" && len(words) == 1:
		ok = command_uninstall_pick(env, options)
	case words[0] == "pin" && len(words) == 2:
		ok = command_pin(env, options, words[1], true)
	case words[0] == "unpin" && len(words) == 2:
		ok = command_pin(env, options, words[1], false)
	case words[0] == "vendor" && len(words) == 1:
		ok = command_vendor(env, options)
	case words[0] == "recover" && len(words) == 1:
		if options.yes {
			fail(env, "--yes only applies to recover abandon")
			return EXIT_USAGE
		}
		ok = command_recover_list(env)
	case words[0] == "recover" && len(words) == 3 && words[1] == "abandon":
		id, parsed := strconv.parse_i64(words[2])
		if !parsed || id <= 0 {
			fail(env, "%s is not a transaction id", words[2])
			return EXIT_USAGE
		}
		ok = command_recover_abandon(env, options, id)
	case:
		print_misuse(env, words[0])
		return EXIT_USAGE
	}

	return EXIT_OK if ok else EXIT_FAILED
}

// One `krs update` for the project at env.project: -u (with --doctor and -i
// inside it) writes; without -u it only lists.
update_dispatch :: proc(env: ^Env, options: Options, words: []string) -> bool {
	if options.update.upgrade {
		return command_update_upgrade(env, options, words[1:])
	}

	return command_check(env, options, words[1:])
}

// `krs update --deep` and `--package-file`: one update_dispatch per project,
// each with its own locks and lockfile. A failing project does not stop the
// others.
command_update_deep :: proc(env: ^Env, options: Options, words: []string) -> bool {
	start := env.project
	projects := deep_projects(env, start) or_return
	selected := make([dynamic]string, context.temp_allocator)
	for project in projects {
		relative := "." if project == start else project[len(start) + 1:]
		lockfile := path_join(relative, PACKAGES_PATH) if relative != "." else PACKAGES_PATH
		if len(options.update.package_files) > 0 {
			chosen := false
			for pattern in options.update.package_files {
				if package_file_matches(pattern, lockfile) {
					chosen = true
					break
				}
			}

			if !chosen {
				continue
			}
		}
		append(&selected, project)
	}

	if len(selected) == 0 {
		return fail(env, "no project matches")
	}

	// state_open joins a relative root onto the project; every project here
	// must get the root relative to where the command started.
	deep_options := options
	if deep_options.root != "" {
		deep_options.root = path_expand_home(deep_options.root, env.home)
		if !strings.has_prefix(deep_options.root, "/") {
			deep_options.root = path_join(start, deep_options.root)
		}
	}

	deep_default_root := env.default_root
	if deep_default_root != "" {
		deep_default_root = path_expand_home(deep_default_root, env.home)
		if !strings.has_prefix(deep_default_root, "/") {
			deep_default_root = path_join(start, deep_default_root)
		}
	}

	all_ok := true
	for project in selected {
		relative := "." if project == start else project[len(start) + 1:]
		say(env, "%v %s", paint(env, ANSI_CYAN, "project"), relative)
		project_env := env^
		project_env.project = project
		project_env.default_root = deep_default_root
		project_words := words
		if len(words) > 1 {
			used, usable := deep_used_words(&project_env, words)
			if !usable {
				all_ok = false
				continue
			}

			project_words = used
			if len(project_words) == 1 {
				info(env, "%s: none of the named packages are used here", relative)
				continue
			}
		}

		if !update_dispatch(&project_env, deep_options, project_words) {
			all_ok = false
		}
	}

	if all_ok {
		success(env, "%d project(s) checked", len(selected))
	}

	return all_ok
}

command_install :: proc(env: ^Env, options: Options) -> bool {
	state := state_open(env, options) or_return
	defer state_close(state)
	state.fetch_configured = true
	plan_discover(state) or_return
	plan_drain(state) or_return

	return plan_apply(state)
}

// `krs pin` and `krs unpin`: set or clear the hold on one recorded package.
// Writes only the project lockfile.
command_pin :: proc(env: ^Env, options: Options, name: string, pinned: bool) -> bool {
	if !is_package_name(name) {
		return fail(env, "\"%s\" is not a usable package name", name)
	}

	state := state_open(env, options) or_return
	defer state_close(state)
	record := packages_find(&state.packages, name)
	if record == nil {
		return fail(env, "%s is not recorded in %s; run krs install first", name, PACKAGES_PATH)
	}

	if record.tag == "" {
		return fail(env, "%s has no recorded release to pin", name)
	}

	if record.pinned == pinned {
		if pinned {
			info(env, "%s is already pinned at %s", name, record.tag)
		} else {
			info(env, "%s is not pinned", name)
		}
		return true
	}

	record.pinned = pinned
	transaction := Transaction{env = env, scope = state.scope}
	defer transaction_close(&transaction)
	stage_packages(&transaction, path_join(state.scope.project, PACKAGES_PATH), state.packages) or_return
	transaction_commit(&transaction) or_return

	if pinned {
		success(env, "%s is pinned at %s", name, record.tag)
	} else {
		success(env, "%s is no longer pinned", name)
	}
	return true
}

// `krs update` without -u: lists newer tags and changes nothing. Positional
// names (each optionally `name@tag`) choose which packages are checked.
command_check :: proc(env: ^Env, options: Options, names: []string) -> bool {
	if options.frozen {
		return fail(env, "--frozen does not apply to update")
	}

	if options.update.global && options.update.json == .All {
		return fail(env, "--json-all applies to a project, not --global")
	}

	if options.update.global && options.update.json == .Deps {
		return fail(env, "--json-deps applies to a project, not --global")
	}

	query := update_query_make(env, options, names) or_return
	defer update_query_destroy(query)

	state := state_open(env, options) or_return
	defer state_close(state)
	candidates := update_candidates(state, query) or_return
	if options.update.json != .None {
		update_print_json(state, candidates[:], options.update.json) or_return
	} else {
		update_print(env, candidates[:], options.update)
	}

	// `-e 2` lets CI fail when an upgrade is available; it is not an error.
	if options.update.error_level == 2 {
		for candidate in candidates {
			if !candidate.pinned && candidate_upgrades(candidate) {
				return false
			}
		}
	}
	return true
}

// Lists the installed packages whose own records name another version.
update_report_dependants :: proc(state: ^State, name, tag: string) {
	for record in state.manifest.packages {
		if record.name == name || record.linked != "" {
			continue
		}

		release, ok := git_release_open(manifest_repository(state, record), record.tag, record.commit)
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

// Prints `name from -> to (compatibility)` for an available or chosen update.
say_version_change :: proc(env: ^Env, name, from, to: string, compatibility: Version_Compatibility) {
	color := ANSI_GREEN if compatibility == .Compatible else ANSI_YELLOW
	label := paint(env, color, version_compatibility_label(compatibility))
	say(env, "%s %s %v %s (%v)", name, from, paint(env, ANSI_DIM, "->"), to, label)
}

// Finds the directory to link: the first `<source directory>/<name>` that has
// a `src/`.
LINK_SCAN_LIMIT :: 4096

// The GitHub repository `libs` names for a package, when it is valid.
link_libs_repository :: proc(state: ^State, name: string) -> (repository: GitHub_Repository, ok: bool) {
	library, configured := state.config.libs[name]
	if !configured || library.source != "github" {
		return {}, false
	}

	return github_repository(library.target)
}

// A checkout named like the package wins. Otherwise the package's `libs`
// entry picks the one checkout whose origin is that GitHub repository.
// `reported` is set when the lookup already failed with a message.
link_find :: proc(state: ^State, name: string) -> (repository: string, ok: bool, reported: bool) {
	for directory in state.config.source_directories {
		candidate := path_join(directory, name)
		if !os.is_directory(candidate) {
			continue
		}

		if os.is_directory(path_join(candidate, "src")) {
			return candidate, true, false
		}

		report_once(state, "skipped %s: it has no src/", candidate)
	}

	wanted, configured := link_libs_repository(state, name)
	if !configured {
		return "", false, false
	}

	identity := source_identity(github_origin(wanted))
	matches: [dynamic]string
	for directory in state.config.source_directories {
		link_scan(state, directory, identity, &matches)
	}

	if len(matches) == 0 {
		return "", false, false
	}

	if len(matches) > 1 {
		fail(state.env, "more than one checkout of %s: %s; keep one in the source directories", github_locator(wanted), strings.join(matches[:], ", "))
		return "", false, true
	}

	info(state.env, "using %s for %s (libs: %s)", matches[0], name, github_locator(wanted))
	return matches[0], true, false
}

// Appends the checkouts directly under `directory` that have a src/ and whose
// origin is `identity`, in name order.
link_scan :: proc(state: ^State, directory, identity: string, matches: ^[dynamic]string) {
	entries, err := os.read_all_directory_by_path(directory, context.temp_allocator)
	if err != nil {
		return
	}

	slice.sort_by(entries, proc(a, b: os.File_Info) -> bool {
		return a.name < b.name
	})
	if len(entries) > LINK_SCAN_LIMIT {
		warn(state.env, "%s has more than %d entries; the search for a checkout stopped there", directory, LINK_SCAN_LIMIT)
		entries = entries[:LINK_SCAN_LIMIT]
	}

	for entry in entries {
		candidate := path_join(directory, entry.name)
		if !os.is_directory(path_join(candidate, "src")) {
			continue
		}

		repo, opened := git_open(candidate)
		if !opened {
			continue
		}

		origin := git_source(repo)
		git_close(repo)
		if origin == identity {
			append(matches, candidate)
		}
	}
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
	if state.vendored {
		return fail(env, "%s uses vendor/; links are not available in vendor mode", state.scope.project)
	}

	repository, found, reported := link_find(state, name)
	if reported {
		return false
	}

	if !found {
		if wanted, configured := link_libs_repository(state, name); configured {
			return fail(env, "no repository with a src/ for \"%s\" in the source directories, and no checkout of %s there", name, github_locator(wanted))
		}
		return fail(env, "no repository with a src/ for \"%s\" in the source directories", name)
	}

	target := path_join(state.shared, name)
	source := path_join(repository, "src")
	record := manifest_find(&state.manifest, name)
	if record == nil && path_present(target) {
		return fail(env, "%s is not managed by krs; remove it by hand before linking", target)
	}

	if record != nil && record.linked != "" {
		link, _ := link_state(state.shared, record^)
		if link == .Directory || link == .File || link == .Elsewhere {
			return fail(env, "%s is not the link krs made; run %s, remove it by hand, then link again", target, fmt.tprintf("krs unlink %s", name))
		}
	}

	if record != nil && record.linked == source {
		current, read_err := os.read_link(target, context.temp_allocator)
		if read_err == nil && current == source {
			info(env, "%s is already linked to %s; nothing to do", name, source)
			return true
		}
	}

	if record != nil && record.linked == "" && path_present(target) {
		hash, hashed := hash_directory(target)
		if !hashed || hash != record.hash {
			warn(env, "%s has changes that do not match %s %s; linking deletes them", target, name, record.tag)
			if !options.yes {
				if !env.interactive {
					return fail(env, "confirmation is needed: run in a terminal, or pass --yes")
				}

				if !ask_yes(env, "Replace the changed files?") {
					return fail(env, "nothing was changed")
				}
			}
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

Status_Row :: struct {
	name:      string,
	label:     string, // e.g. "installed v1.2.0"
	color:     string, // ANSI_GREEN, ANSI_YELLOW, ANSI_CYAN or ANSI_DIM
	notes:     [dynamic]Painted, // already painted, printed with %v
	hint:      Painted, // how to fix the row, printed as a note; or ""
	attention: bool,
	used:      bool, // this project imports or records it
}

// One row per package the Odin root holds or this project imports or pins.
// Reads the root and the project; writes nothing.
status_rows :: proc(state: ^State, imports: []string) -> [dynamic]Status_Row {
	rows: [dynamic]Status_Row
	env := state.env

	for record in state.manifest.packages {
		row := Status_Row{name = record.name}
		pinned := packages_find(&state.packages, record.name)
		row.used = pinned != nil || slice.contains(imports, record.name)

		if record.linked != "" {
			link, current := link_state(state.shared, record)
			if link == .Working {
				row.label = fmt.tprintf("linked -> %s", record.linked)
				row.color = ANSI_GREEN
			} else {
				row.label = fmt.tprintf("link broken (%s)", link_state_text(link, current))
				row.color = ANSI_YELLOW
				row.attention = true
				row.hint = link_hint(env, state.shared, record, link)
			}
		} else {
			directory := path_join(state.shared, record.name)
			if !path_present(directory) {
				row.label = fmt.tprintf("missing %s", record.tag)
				row.color = ANSI_YELLOW
				row.attention = true
			} else if hash, ok := hash_directory(directory); !ok || hash != record.hash {
				row.label = fmt.tprintf("altered %s", record.tag)
				row.color = ANSI_YELLOW
				row.attention = true
			} else {
				row.label = fmt.tprintf("installed %s", record.tag)
				row.color = ANSI_GREEN
			}

			if pinned != nil && pinned.tag != record.tag {
				append(&row.notes, paint(env, ANSI_YELLOW, fmt.tprintf("pin %s", pinned.tag)))
				row.attention = true
			}
		}

		if !row.used {
			append(&row.notes, paint(env, ANSI_DIM, "not imported here"))
		}
		append(&rows, row)
	}

	entries, _ := os.read_all_directory_by_path(state.shared, context.temp_allocator)
	for entry in entries {
		if entry.type != .Directory && entry.type != .Symlink {
			continue
		}

		if strings.has_prefix(entry.name, ".") || manifest_find(&state.manifest, entry.name) != nil {
			continue
		}

		row := Status_Row{name = entry.name, label = "unmanaged", color = ANSI_DIM}
		row.used = packages_find(&state.packages, entry.name) != nil || slice.contains(imports, entry.name)
		if row.used {
			append(&row.notes, paint(env, ANSI_YELLOW, "pinned but not managed"))
			row.attention = true
		}
		append(&rows, row)
	}

	missing := make([dynamic]string, context.temp_allocator)
	for name in imports {
		append(&missing, name)
	}
	for pinned in state.packages.packages {
		append(&missing, pinned.name)
	}
	for name in missing {
		known := false
		for row in rows {
			if row.name == name {
				known = true
				break
			}
		}

		if known {
			continue
		}

		append(&rows, Status_Row{name = name, label = "not installed", color = ANSI_YELLOW, attention = true, used = true})
	}

	slice.sort_by(rows[:], proc(a, b: Status_Row) -> bool {
		return a.name < b.name
	})
	return rows
}

// `krs status`: whether this project's packages are in place, listing only
// those that are not; with -g, everything the Odin root holds. Writes nothing.
command_status :: proc(env: ^Env, options: Options) -> bool {
	if options.frozen || options.yes {
		return fail(env, "status takes only --root and -g")
	}

	state := state_open(env, options) or_return
	defer state_close(state)
	if state.vendored {
		info(env, "vendor mode: packages come from %s (build with %s)", state.shared, "-collection:shared=vendor")
	}

	imports, scanned := scan_directory_imports(env.project, path_base(env.project), true)
	if !scanned {
		return fail(env, "cannot read the Odin files under %s", env.project)
	}

	global := options.update.global
	all := status_rows(state, imports[:])
	rows := make([dynamic]Status_Row, context.temp_allocator)
	used, attention := 0, 0
	for row in all {
		if row.used {
			used += 1
		}

		if row.attention && (global || row.used) {
			attention += 1
		}

		if global || (row.used && row.attention) {
			append(&rows, row)
		}
	}

	switch {
	case global && len(rows) == 0:
		info(env, "nothing is installed in %s and this project imports nothing", state.shared)
	case global:
		info(env, "%d package(s) in %s", len(rows), state.shared)
	case used == 0:
		info(env, "this project imports no shared: packages and records none")
	case:
		info(env, "checked %d package(s) of this project in %s", used, state.shared)
	}
	status_print(env, rows[:])

	if attention > 0 {
		return fail(env, "%d package(s) need attention", attention)
	}

	success(env, "everything is in place")
	return true
}

status_print :: proc(env: ^Env, rows: []Status_Row) {
	width := 0
	for row in rows {
		width = max(width, len(row.name))
	}

	for row in rows {
		padding := strings.repeat(" ", width - len(row.name), context.temp_allocator)
		b := strings.builder_make(context.temp_allocator)
		for n in row.notes {
			fmt.sbprintf(&b, "  %v", n)
		}
		say(env, "  %s%v %v%v", row.name, padding, paint(env, row.color, row.label), Painted(strings.to_string(b)))
		if row.hint != "" {
			note(env, "%v", row.hint)
		}
	}
}

// How to fix a broken link.
link_hint :: proc(env: ^Env, shared: string, record: Manifest_Record, link: Link_State) -> Painted {
	link_command := fmt.tprintf("krs link %s", record.name)
	unlink_command := fmt.tprintf("krs unlink %s", record.name)
	switch link {
	case .Working:
		return ""
	case .Missing:
		return styled(env, "run %s to recreate it, or %s to forget it", link_command, unlink_command)
	case .Directory, .File, .Elsewhere:
		target := path_join(shared, record.name)
		return styled(env, "krs did not make %s; run %s to forget the link, remove it by hand, then %s", target, unlink_command, link_command)
	case .Source_Missing:
		return styled(env, "restore the checkout at %s, or run %s to remove the link", record.linked, unlink_command)
	}
	return ""
}

// What `shared/<name>` holds compared with the link krs recorded.
Link_State :: enum {
	Working,
	Missing,        // nothing at shared/<name>
	Directory,      // a real directory krs did not make
	File,           // a regular file (or other non-link) krs did not make
	Elsewhere,      // a symbolic link to a different path
	Source_Missing, // krs's link, but the linked src/ is gone
}

link_state :: proc(shared: string, record: Manifest_Record) -> (state: Link_State, current: string) {
	target := path_join(shared, record.name)
	info, err := os.lstat(target, context.temp_allocator)
	if err != nil {
		return .Missing, ""
	}

	if info.type == .Directory {
		return .Directory, ""
	}

	if info.type != .Symlink {
		return .File, ""
	}

	current, _ = os.read_link(target, context.temp_allocator)
	if current != record.linked {
		return .Elsewhere, current
	}

	if !os.is_directory(record.linked) {
		return .Source_Missing, current
	}

	return .Working, current
}

// The short text shown in parentheses for a state; "" when the link works.
link_state_text :: proc(state: Link_State, current: string) -> string {
	switch state {
	case .Working:
		return ""
	case .Missing:
		return "missing from shared/"
	case .Directory:
		return "replaced by a directory"
	case .File:
		return "replaced by a file"
	case .Elsewhere:
		return fmt.tprintf("points to %s instead", current)
	case .Source_Missing:
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
	if state.vendored {
		return fail(env, "%s uses vendor/; links are not available in vendor mode", state.scope.project)
	}

	record := manifest_find(&state.manifest, name)
	if record == nil || record.linked == "" {
		return fail(env, "%s is not linked in %s", name, state.shared)
	}

	tag, source, commit := record.tag, record.source, record.commit
	pin := packages_find(&state.packages, name)
	if pin != nil {
		tag, source, commit = pin.tag, pin.source, pin.commit
	}

	target := path_join(state.shared, name)
	link, _ := link_state(state.shared, record^)
	unlink_command := fmt.tprintf("krs unlink %s", name)
	if options.restore && tag == "" {
		return fail(env, "%s has no recorded release to restore; run %s to remove the link", name, unlink_command)
	}

	if options.restore && (link == .Directory || link == .File || link == .Elsewhere) {
		return fail(env, "%s is not the link krs made; run %s first and remove it by hand", target, unlink_command)
	}

	if options.restore {
		unlink_report_unnamed(state, name, record.path)
		info(env, "restoring %s %s", name, tag)
		append(&state.queue, Request{name = name, tag = tag, source = source, commit = commit, by = "krs unlink", kind = .Restore, source_trusted = true})
		plan_drain(state) or_return
		return plan_apply(state, .Preserve)
	}

	// Remove the development link and its record; `shared/` no longer has it.
	transaction := Transaction{env = env, scope = state.scope}
	defer transaction_close(&transaction)
	if link == .Working || link == .Source_Missing {
		change := transaction_stage(&transaction, target, .Link, record.linked) or_return
		change.staged = ""
	}

	manifest_remove(&state.manifest, name)
	stage_manifest(&transaction, state.shared, &state.manifest) or_return
	transaction_commit(&transaction) or_return

	if link == .Missing {
		success(env, "%s is no longer recorded as linked", name)
		return true
	}

	if link != .Working && link != .Source_Missing {
		warn(env, "left %s in place; krs did not make it", target)
		success(env, "%s is no longer recorded as linked", name)
		return true
	}

	if tag == "" {
		success(env, "%s is unlinked; no version of it was recorded, so nothing was installed", name)
	} else {
		success(env, "%s is unlinked and removed from %s", name, state.shared)
		note(env, "run %s in a project that imports it to install a release again", "krs install")
	}
	return true
}

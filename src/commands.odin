package krs

import "core:fmt"
import "core:io"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

USAGE_FORMAT :: `%[0]susage:%[1]s
  krs %[0]sinstall%[1]s [--root=<path>] [--frozen] [--repair] [--yes]
      install the releases this project imports
  krs %[0]sstatus%[1]s [--root=<path>]
      list what the Odin root holds for this project
  krs %[0]supdate%[1]s [<package>[@<tag>]...] [--cooldown=<period>] [options]
      list newer releases; filter with names, -f, -x
  krs %[0]supdate -u%[1]s [<package>[@<tag>]...] [--cooldown=<period>] [options]
      write the chosen versions to .krs/packages.json and install them
  krs %[0]supdate -u --doctor%[1]s [--doctor-test=<cmd>] [--doctor-install=<cmd>] [options]
      upgrade, run the tests and keep only the upgrades that pass
  krs %[0]supdate -i%[1]s [<package>...] [--interactive-select=<which>] [--root=<path>]
      choose which upgrades to take, then apply them
  krs %[0]sfetch%[1]s
      refresh the GitHub releases of the configured libraries
  krs %[0]sfetch%[1]s <owner>/<repo>
      select or refresh the releases of one GitHub repository
  krs %[0]slink%[1]s <package> [--root=<path>] [--yes]
      use a checkout's live src/ in place of a release
  krs %[0]slink ls%[1]s [--root=<path>]
      list the links and flag broken ones
  krs %[0]spin%[1]s <package> [--root=<path>]
      hold a package at the release this project records
  krs %[0]sunpin%[1]s <package> [--root=<path>]
      let a pinned package be upgraded again
  krs %[0]svendor%[1]s [--root=<path>] [--yes]
      copy this project's dependencies into vendor/ and use them
  krs %[0]sunlink%[1]s <package> [--root=<path>] [--restore] [--yes]
      remove a link; with --restore, install the recorded release
  krs %[0]srecover%[1]s
      list interrupted file publications
  krs %[0]srecover abandon%[1]s <id> [--yes]
      give up on one interrupted publication
  krs %[0]s--version%[1]s
      print the version
  krs %[0]s--help%[1]s
      print this text

  %[0]s--root=<path>%[1]s  work on the shared/ of the Odin root at <path>
  %[0]s--frozen%[1]s       install exactly what .krs/packages.json says, or fail
  %[0]s--repair%[1]s       reinstall packages whose installed files were changed
  %[0]s--restore%[1]s      after unlink, install the recorded release in its place
  %[0]s--fetch%[1]s        before checking, refresh the GitHub releases of the packages
  %[0]s--yes%[1]s          do not ask before writing

  update options:
  %[0]s-u, --upgrade%[1]s           write .krs/packages.json and install
  %[0]s--install%[1]s <m>           always, never (lockfile only) or prompt
  %[0]s--pin%[1]s                   with -u: pin every chosen version
  %[0]s-i, --interactive%[1]s       choose upgrades before applying them
  %[0]s--interactive-select%[1]s    auto, none, patch, minor or all: what starts selected
  %[0]s-c, --cooldown%[1]s <p>      ignore releases younger than this (7, 7d, 12h, 30m)
  %[0]s-d, --doctor%[1]s            after upgrading, run the tests; keep only upgrades that pass
  %[0]s--doctor-test%[1]s <cmd>     test command for --doctor (default: odin test .)
  %[0]s--doctor-install%[1]s <cmd>  command run after each install for --doctor (default: none)
  %[0]s-t, --target%[1]s <t>        latest, greatest, newest, minor, patch or semver
  %[0]s-f, --filter%[1]s <p>        only names matching p (name, a,b, glob*, /regex/, !name)
  %[0]s-x, --reject%[1]s <p>        skip names matching p
  %[0]s--filter-version%[1]s <p>    only current versions matching p
  %[0]s--reject-version%[1]s <p>    skip current versions matching p
  %[0]s--format%[1]s <v,...>        group, lines, time, repo, diff, installed-version, cooldown; no-<v> removes
  %[0]s-j, --json-all%[1]s          print the new .krs/packages.json as JSON
  %[0]s--json-upgraded%[1]s         print the upgrades as JSON
  %[0]s--json-deps%[1]s             print the new package list as JSON
  %[0]s-e, --error-level%[1]s <n>   2: exit 1 when upgrades are available
  %[0]s-g, --global%[1]s            check every package of the Odin root
  %[0]s--color%[1]s                 force colors
  %[0]s-s, --silent%[1]s            print nothing; use the exit code
  %[0]s-l, --loglevel%[1]s <l>      silent, error, minimal, warn, info or verbose
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
	// Options is zero-initialised; these are the defaults of `krs update`.
	options.update.format = {.Group}
	options.update.error_level = 1
	words: [dynamic]string
	update_flag := "" // the first update-only flag given, for the guard below
	log_level: Maybe(Log_Level)
	interactive_select_given := false
	doctor_flag := "" // the first of --doctor-test and --doctor-install given

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

		if update_flag == "" && update_flag_only(flag) {
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
		print_usage(env.err, env.style.stderr && env.style.color)
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
	case words[0] == "update" && options.update.upgrade:
		ok = command_update_upgrade(env, options, words[1:])
	case words[0] == "update":
		ok = command_check(env, options, words[1:])
	case words[0] == "fetch" && len(words) == 1:
		ok = command_fetch_all(env)
	case words[0] == "fetch" && len(words) == 2:
		ok = command_fetch(env, words[1])
	case words[0] == "link" && len(words) == 2 && words[1] == "ls":
		ok = command_link_list(env, options)
	case words[0] == "link" && len(words) == 2:
		ok = command_link(env, options, words[1])
	case words[0] == "unlink" && len(words) == 2:
		ok = command_unlink(env, options, words[1])
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
	if state.vendored {
		return fail(env, "%s uses vendor/; links are not available in vendor mode", state.scope.project)
	}

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
	attention: bool,
}

// One row per package the Odin root holds or this project imports or pins.
// Reads the root and the project; writes nothing.
status_rows :: proc(state: ^State, imports: []string) -> [dynamic]Status_Row {
	rows: [dynamic]Status_Row
	env := state.env

	for record in state.manifest.packages {
		row := Status_Row{name = record.name}
		pinned := packages_find(&state.packages, record.name)
		used := pinned != nil || slice.contains(imports, record.name)

		if record.linked != "" {
			link, current := link_state(state.shared, record)
			if link == .Working {
				row.label = fmt.tprintf("linked -> %s", record.linked)
				row.color = ANSI_GREEN
			} else {
				row.label = fmt.tprintf("link broken (%s)", link_state_text(link, current))
				row.color = ANSI_YELLOW
				row.attention = true
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

		if !used {
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
		if packages_find(&state.packages, entry.name) != nil || slice.contains(imports, entry.name) {
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

		append(&rows, Status_Row{name = name, label = "not installed", color = ANSI_YELLOW, attention = true})
	}

	slice.sort_by(rows[:], proc(a, b: Status_Row) -> bool {
		return a.name < b.name
	})
	return rows
}

// `krs status`: what the Odin root holds and what needs attention. Writes nothing.
command_status :: proc(env: ^Env, options: Options) -> bool {
	if options.frozen || options.yes {
		return fail(env, "status takes only --root")
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

	rows := status_rows(state, imports[:])
	if len(rows) == 0 {
		info(env, "nothing is installed in %s and this project imports nothing", state.shared)
		success(env, "everything is in place")
		return true
	}

	width := 0
	attention := 0
	for row in rows {
		width = max(width, len(row.name))
		if row.attention {
			attention += 1
		}
	}

	info(env, "%d package(s) in %s", len(rows), state.shared)
	for row in rows {
		padding := strings.repeat(" ", width - len(row.name), context.temp_allocator)
		b := strings.builder_make(context.temp_allocator)
		for n in row.notes {
			fmt.sbprintf(&b, "  %v", n)
		}
		say(env, "  %s%v %v%v", row.name, padding, paint(env, row.color, row.label), Painted(strings.to_string(b)))
	}

	if attention > 0 {
		return fail(env, "%d package(s) need attention", attention)
	}

	success(env, "everything is in place")
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
		link, current := link_state(state.shared, record)
		if link == .Working {
			say(env, "  %s%v %v %s", record.name, padding, paint(env, ANSI_DIM, "->"), record.linked)
			continue
		}

		broken += 1
		say(env, "  %s%v %v %s %v", record.name, padding, paint(env, ANSI_DIM, "->"), record.linked,
			paint(env, ANSI_YELLOW, fmt.tprintf("(%s)", link_state_text(link, current))))
		target := path_join(state.shared, record.name)
		switch link {
		case .Working:
		case .Missing:
			note(env, "run %s to recreate it, or %s to forget it", fmt.tprintf("krs link %s", record.name), fmt.tprintf("krs unlink %s", record.name))
		case .Directory, .File, .Elsewhere:
			note(env, "krs did not make %s; run %s to forget the link, remove it by hand, then %s", target, fmt.tprintf("krs unlink %s", record.name), fmt.tprintf("krs link %s", record.name))
		case .Source_Missing:
			note(env, "restore the checkout at %s, or run %s to remove the link", record.linked, fmt.tprintf("krs unlink %s", record.name))
		}
	}

	if broken > 0 {
		warn(env, "%d link(s) need attention", broken)
	}
	return true
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

package krs

import "core:encoding/json"
import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:text/regex"
import "core:time"

// The tag `krs update` picks for each package. `Latest` and `Greatest` are
// both the highest tag: KRS has no registry dist-tags, only vMAJOR.MINOR.PATCH.
Update_Target :: enum {
	Latest,
	Newest,
	Greatest,
	Minor,
	Patch,
	Semver,
}

Update_Format :: enum {
	Group,
	Lines,
	Time,
	Repo,
	Diff,
	Installed_Version,
	Cooldown,
}

Update_Json :: enum {
	None,
	All,
	Upgraded,
	Deps,
}

// Zero value is .Info, so every Env literal prints everything by default.
Log_Level :: enum i8 {
	Silent  = -4,
	Error   = -3,
	Minimal = -2,
	Warn    = -1,
	Info    = 0,
	Verbose = 1,
}

// Flags of `krs update`, as parsed by `run`.
Update_Options :: struct {
	upgrade:        bool, // -u
	target:         Update_Target, // -t, default .Latest
	filter:         [dynamic]string, // -f, raw patterns
	reject:         [dynamic]string, // -x
	filter_version: [dynamic]string,
	reject_version: [dynamic]string,
	format:         bit_set[Update_Format], // default {.Group}
	json:           Update_Json,
	error_level:    int, // 1 (default) or 2
	global:         bool, // -g
	install:        Install_Mode, // `update -u --install`: when to install
	install_given:  bool, // --install was passed (a zero value is not enough)
	pin:            bool, // `update -u --pin`: pin every chosen version
	cooldown:       i64, // seconds; 0 = off
	interactive:        bool, // `update -i`: choose upgrades before applying them
	interactive_select: Interactive_Select, // which upgrades start selected
	doctor:         bool, // `update -u --doctor`: test upgrades and keep the passing ones
	doctor_test:    string, // shell command for the tests; "" means the default
	doctor_install: string, // shell command run after each install; "" means none
}

// Which upgrades `update -i` selects before the person changes anything.
Interactive_Select :: enum {
	Auto, // patch and minor upgrades
	None,
	Patch,
	Minor, // patch and minor upgrades
	All,
}

// When `krs update -u` installs what it chose.
Install_Mode :: enum {
	Prompt, // zero value = ncu's default: ask, or --yes
	Always,
	Never, // only .krs/packages.json is written
}

UPDATE_TARGET_NAMES :: [Update_Target]string {
	.Latest   = "latest",
	.Newest   = "newest",
	.Greatest = "greatest",
	.Minor    = "minor",
	.Patch    = "patch",
	.Semver   = "semver",
}

UPDATE_FORMAT_NAMES :: [Update_Format]string {
	.Group             = "group",
	.Lines             = "lines",
	.Time              = "time",
	.Repo              = "repo",
	.Diff              = "diff",
	.Installed_Version = "installed-version",
	.Cooldown          = "cooldown",
}

LOG_LEVEL_NAMES :: [Log_Level]string {
	.Silent  = "silent",
	.Error   = "error",
	.Minimal = "minimal",
	.Warn    = "warn",
	.Info    = "info",
	.Verbose = "verbose",
}

// Flags followed by a value: `--name=value`, `--name value` or `-n value`.
update_flag_takes_value :: proc(flag: string) -> bool {
	switch flag {
	case "-t", "--target", "-f", "--filter", "-x", "--reject", "--filter-version", "--reject-version",
	     "--format", "-e", "--error-level", "-l", "--loglevel", "--install", "--interactive-select",
	     "-c", "--cooldown", "--doctor-test", "--doctor-install":
		return true
	}
	return false
}

// Flags that only `krs update` takes. `--color` applies to every command.
update_flag_only :: proc(flag: string) -> bool {
	if update_flag_takes_value(flag) {
		return true
	}

	switch flag {
	case "-u", "--upgrade", "-j", "--json-all", "--json-upgraded", "--json-deps", "-g", "--global",
	     "-s", "--silent", "--pin", "-i", "--interactive", "-d", "--doctor":
		return true
	}
	return false
}

update_target_parse :: proc(text: string) -> (target: Update_Target, ok: bool) {
	for name, candidate in UPDATE_TARGET_NAMES {
		if name == text {
			return candidate, true
		}
	}
	return .Latest, false
}

// One `--format` value: `name` adds the format, `no-name` removes it.
update_format_parse :: proc(text: string) -> (format: Update_Format, enabled: bool, ok: bool) {
	name := text
	enabled = true
	if len(name) > len("no-") && name[:len("no-")] == "no-" {
		name = name[len("no-"):]
		enabled = false
	}

	for candidate_name, candidate in UPDATE_FORMAT_NAMES {
		if candidate_name == name {
			return candidate, enabled, true
		}
	}
	return .Group, false, false
}

log_level_parse :: proc(text: string) -> (level: Log_Level, ok: bool) {
	for name, candidate in LOG_LEVEL_NAMES {
		if name == text {
			return candidate, true
		}
	}
	return .Info, false
}

// How far a candidate moves from the current tag.
Update_Group :: enum {
	Patch,
	Minor,
	Major,
	Major_Zero, // the minor changes at 0.x, which is a breaking change there
}

Update_Candidate :: struct {
	name, source, current, chosen, installed: string,
	group:       Update_Group,
	pinned:      bool,
	chosen_time: i64, // Unix seconds; 0 when not loaded
	held_by_cooldown: string, // the tag the target would pick without --cooldown, when it was too new; "" otherwise
	held_time:   i64, // Unix seconds of held_by_cooldown; 0 when unknown
}

// A candidate that would actually move the package.
candidate_upgrades :: proc(candidate: Update_Candidate) -> bool {
	return candidate.chosen != candidate.current
}

// The candidates that would move a package.
candidates_upgrading :: proc(candidates: []Update_Candidate) -> [dynamic]Update_Candidate {
	upgrading := make([dynamic]Update_Candidate, context.temp_allocator)
	for candidate in candidates {
		if candidate_upgrades(candidate) {
			append(&upgrading, candidate)
		}
	}
	return upgrading
}

COOLDOWN_LIMIT :: 3650 * 86400

// Seconds in a --cooldown period: a plain number of days, or a number with
// d, h or m. Rejects zero, negatives and anything else.
cooldown_seconds :: proc(text: string) -> (seconds: i64, ok: bool) {
	digits := text
	unit := i64(86400)
	if len(text) > 0 {
		switch text[len(text) - 1] {
		case 'd':
			digits = text[:len(text) - 1]
		case 'h':
			digits = text[:len(text) - 1]
			unit = 3600
		case 'm':
			digits = text[:len(text) - 1]
			unit = 60
		}
	}

	// At most nine digits, so the multiplication below cannot overflow.
	if len(digits) == 0 || len(digits) > 9 {
		return 0, false
	}

	// Checked here because parse_i64 would accept a sign, 0x and underscores.
	for character in transmute([]byte)digits {
		if character < '0' || character > '9' {
			return 0, false
		}
	}

	number, parsed := strconv.parse_i64(digits, 10)
	if !parsed || number == 0 {
		return 0, false
	}

	seconds = number * unit
	if seconds > COOLDOWN_LIMIT {
		return 0, false
	}
	return seconds, true
}

Update_Query :: struct {
	names:          []string, // positional names, "" target when no @tag
	name_tags:      map[string]string, // name -> tag from `name@tag`
	target:         Update_Target,
	filter, reject, filter_version, reject_version: []Update_Pattern,
	global:         bool,
	cooldown:       i64, // seconds; 0 = off (plan 027 sets it)
	need_times:     bool, // .Newest, --format time, or cooldown
	report_held:    bool, // --format cooldown: also emit packages the cooldown holds in place
}

Update_Pattern :: struct {
	kind:       enum {
		Exact,
		Glob,
		Regex,
	},
	text:       string,
	expression: regex.Regular_Expression,
}

// Splits raw pattern values on commas and spaces, never inside `/…/`.
update_pattern_texts :: proc(raw: []string) -> (texts: [dynamic]string) {
	for value in raw {
		start := 0
		for start < len(value) {
			if value[start] == ',' || value[start] == ' ' {
				start += 1
				continue
			}

			end := start
			slash := start + 1 if value[start] == '!' else start
			if slash < len(value) && value[slash] == '/' {
				end = slash + 1
				for end < len(value) && (value[end] != '/' || value[end - 1] == '\\') {
					end += 1
				}
				end = min(end + 1, len(value))
			}

			for end < len(value) && value[end] != ',' && value[end] != ' ' {
				end += 1
			}

			assert(end > start)
			append(&texts, value[start:end])
			start = end
		}
	}
	return
}

// Compiles name or version patterns: `/regex/`, `glob*`, or an exact text.
update_patterns :: proc(env: ^Env, raw: []string) -> (patterns: [dynamic]Update_Pattern, ok: bool) {
	for text in update_pattern_texts(raw) {
		pattern := Update_Pattern{text = text}
		switch {
		case strings.has_prefix(text, "/"):
			if len(text) < 2 || !strings.has_suffix(text, "/") {
				return patterns, fail(env, "%s is not a valid pattern", text)
			}

			expression, err := regex.create(text[1:len(text) - 1])
			if err != nil {
				return patterns, fail(env, "%s is not a valid pattern", text)
			}
			pattern.kind = .Regex
			pattern.expression = expression
		case strings.contains_rune(text, '*'):
			pattern.kind = .Glob
		case:
			pattern.kind = .Exact
		}
		append(&patterns, pattern)
	}
	return patterns, true
}

update_patterns_destroy :: proc(patterns: []Update_Pattern) {
	for pattern in patterns {
		if pattern.kind == .Regex {
			regex.destroy(pattern.expression)
		}
	}
}

// `*` matches any run of characters; every other character matches itself.
glob_match :: proc(glob, text: string) -> bool {
	g, t := 0, 0
	star, resume := -1, 0
	for t < len(text) {
		if g < len(glob) && glob[g] == '*' {
			star = g
			resume = t
			g += 1
		} else if g < len(glob) && glob[g] == text[t] {
			g += 1
			t += 1
		} else if star >= 0 {
			resume += 1
			t = resume
			g = star + 1
		} else {
			return false
		}
	}

	for g < len(glob) && glob[g] == '*' {
		g += 1
	}
	return g == len(glob)
}

update_pattern_match :: proc(pattern: Update_Pattern, text: string) -> bool {
	switch pattern.kind {
	case .Exact:
		return pattern.text == text
	case .Glob:
		return glob_match(pattern.text, text)
	case .Regex:
		capture, matched := regex.match(pattern.expression, text)
		regex.destroy(capture)
		return matched
	}
	unreachable()
}

update_patterns_match :: proc(patterns: []Update_Pattern, text: string) -> bool {
	for pattern in patterns {
		if update_pattern_match(pattern, text) {
			return true
		}
	}
	return false
}

// Builds the query `krs update` checks from the parsed options and the
// positional names. Fails (and prints why) on a bad tag or pattern.
// Release it with update_query_destroy.
update_query_make :: proc(env: ^Env, options: Options, names: []string) -> (query: Update_Query, ok: bool) {
	query = Update_Query {
		target     = options.update.target,
		global     = options.update.global,
		need_times = options.update.target == .Newest || .Time in options.update.format || options.update.cooldown > 0,
		cooldown   = options.update.cooldown,
		report_held = options.update.cooldown > 0 && .Cooldown in options.update.format,
	}
	defer if !ok {
		update_query_destroy(query)
	}

	plain_names := make([dynamic]string, context.temp_allocator)
	for word in names {
		name, tag := word, ""
		if at := strings.index_byte(word, '@'); at >= 0 {
			name, tag = word[:at], word[at + 1:]
			if _, valid := parse_tag(tag); !valid {
				return query, fail(env, "%s is not a vMAJOR.MINOR.PATCH tag", tag)
			}
		}
		append(&plain_names, name)
		query.name_tags[name] = tag
	}
	query.names = plain_names[:]

	// A filter starting with `!` is a reject pattern.
	filters := make([dynamic]string, context.temp_allocator)
	rejects := make([dynamic]string, context.temp_allocator)
	filter_versions := make([dynamic]string, context.temp_allocator)
	reject_versions := make([dynamic]string, context.temp_allocator)
	append(&rejects, ..options.update.reject[:])
	append(&reject_versions, ..options.update.reject_version[:])
	for text in update_pattern_texts(options.update.filter[:]) {
		if strings.has_prefix(text, "!") {
			append(&rejects, text[1:])
		} else {
			append(&filters, text)
		}
	}

	for text in update_pattern_texts(options.update.filter_version[:]) {
		if strings.has_prefix(text, "!") {
			append(&reject_versions, text[1:])
		} else {
			append(&filter_versions, text)
		}
	}

	filter := update_patterns(env, filters[:]) or_return
	query.filter = filter[:]
	reject := update_patterns(env, rejects[:]) or_return
	query.reject = reject[:]
	filter_version := update_patterns(env, filter_versions[:]) or_return
	query.filter_version = filter_version[:]
	reject_version := update_patterns(env, reject_versions[:]) or_return
	query.reject_version = reject_version[:]
	return query, true
}

// Frees the compiled patterns of a query made by update_query_make.
update_query_destroy :: proc(query: Update_Query) {
	update_patterns_destroy(query.filter)
	update_patterns_destroy(query.reject)
	update_patterns_destroy(query.filter_version)
	update_patterns_destroy(query.reject_version)
}

// Positional names and name patterns, applied before any repository lookup.
update_name_selected :: proc(query: Update_Query, name: string) -> bool {
	if len(query.names) > 0 && !slice.contains(query.names, name) {
		return false
	}

	if len(query.filter) > 0 && !update_patterns_match(query.filter, name) {
		return false
	}

	return !update_patterns_match(query.reject, name)
}

update_version_selected :: proc(query: Update_Query, tag: string) -> bool {
	if len(query.filter_version) > 0 && !update_patterns_match(query.filter_version, tag) {
		return false
	}

	return !update_patterns_match(query.reject_version, tag)
}

update_group :: proc(current, chosen: Version) -> Update_Group {
	if current.major != chosen.major {
		return .Major
	}

	if current.major == 0 && current.minor != chosen.minor {
		return .Major_Zero
	}

	if current.minor != chosen.minor {
		return .Minor
	}

	return .Patch
}

// The tag the target picks among the repository's tags, or "" when none
// qualifies. `.Newest` and a non-zero `threshold` need the tag times loaded.
// With a threshold, only tags whose commit time is known and not later than
// it (Unix seconds) qualify.
update_choose :: proc(repository: ^Repository, current: Version, target: Update_Target, threshold: i64 = 0) -> string {
	chosen := ""
	chosen_version: Version
	chosen_time: i64
	for tag in repository.tags {
		version := parse_tag(tag) or_continue
		switch target {
		case .Latest, .Greatest, .Newest:
		case .Minor:
			if version.major != current.major {
				continue
			}
		case .Patch:
			if version.major != current.major || version.minor != current.minor {
				continue
			}
		case .Semver:
			if version_compatibility(current, version) != .Compatible {
				continue
			}
		}

		if threshold > 0 {
			tag_time, found := repository.tag_times[tag]
			if !found || tag_time == 0 || tag_time > threshold {
				continue
			}
		}

		better := chosen == "" || version_compare(version, chosen_version) == .Higher
		time: i64
		if target == .Newest {
			found: bool
			time, found = repository.tag_times[tag]
			if !found {
				continue
			}
			better = chosen == "" || time > chosen_time || (time == chosen_time && version_compare(version, chosen_version) == .Higher)
		}

		if better {
			chosen = tag
			chosen_version = version
			chosen_time = time
		}
	}
	return chosen
}

// The upgrades a query finds, sorted by name. Reads repositories; writes
// nothing. Fails when any selected package cannot be checked.
update_candidates :: proc(state: ^State, query: Update_Query) -> (candidates: [dynamic]Update_Candidate, ok: bool) {
	Entry :: struct {
		name, source, tag: string,
		pinned:            bool,
	}

	entries := make([dynamic]Entry, context.temp_allocator)
	if query.global {
		for record in state.manifest.packages {
			append(&entries, Entry{record.name, record.source, record.tag, false})
		}
	} else {
		// The project's own pin is the current version, not the root's tag.
		for record in state.packages.packages {
			append(&entries, Entry{record.name, record.source, record.tag, record.pinned})
		}
	}

	unavailable := 0
	for entry in entries {
		installed := ""
		if record := manifest_find(&state.manifest, entry.name); record != nil {
			if record.linked != "" {
				continue
			}
			installed = record.tag
		}

		if !update_name_selected(query, entry.name) || !update_version_selected(query, entry.tag) {
			continue
		}

		if state.options.fetch {
			refresh_package_cache(state, entry.name, entry.source)
		}

		repository, found := repository_find(state, entry.name, "", entry.source)
		if !found {
			warn(state.env, "cannot check %s: no usable repository", entry.name)
			unavailable += 1
			continue
		}

		current, current_ok := parse_tag(entry.tag)
		if !current_ok {
			warn(state.env, "cannot check %s: invalid installed tag %s", entry.name, entry.tag)
			unavailable += 1
			continue
		}

		if query.need_times || query.target == .Newest || query.cooldown > 0 {
			if !repository_load_times(state, &repository) {
				unavailable += 1
				continue
			}
		}

		chosen := ""
		held := ""
		held_time: i64
		named := query.name_tags[entry.name]
		if named != "" {
			// Only an explicit tag may choose a lower one.
			if !repository_has_tag(&repository, named) {
				warn(state.env, "%s has no tag %s", entry.name, named)
				unavailable += 1
				continue
			}

			if named == entry.tag {
				continue
			}
			chosen = named
		} else {
			chosen = update_choose(&repository, current, query.target)
			if query.cooldown > 0 {
				wanted := chosen
				chosen = ""
				threshold := time.time_to_unix(time.now()) - query.cooldown
				eligible := update_choose(&repository, current, query.target, threshold)
				if eligible != "" {
					eligible_version, _ := parse_tag(eligible)
					if version_compare(eligible_version, current) == .Higher {
						chosen = eligible
					}
				}

				if wanted != "" && wanted != chosen {
					wanted_version, _ := parse_tag(wanted)
					if version_compare(wanted_version, current) == .Higher {
						held = wanted
						held_time = repository.tag_times[wanted]
						if held_time == 0 {
							note(state.env, "%s %s has no commit date; --cooldown skips it", entry.name, wanted)
						}
					}
				}
			} else if chosen != "" {
				chosen_version, _ := parse_tag(chosen)
				if version_compare(chosen_version, current) != .Higher {
					chosen = ""
				}
			}

			if chosen == "" {
				// Nothing moves; a held package is still reported for --format cooldown.
				if held == "" || !query.report_held {
					continue
				}
				chosen = entry.tag
			}
		}

		chosen_version, chosen_ok := parse_tag(chosen)
		assert(chosen_ok)
		candidate := Update_Candidate {
			name      = entry.name,
			source    = entry.source,
			current   = entry.tag,
			chosen    = chosen,
			installed = installed,
			group     = update_group(current, chosen_version),
			pinned    = entry.pinned,
			held_by_cooldown = held,
			held_time = held_time,
		}
		if query.need_times {
			candidate.chosen_time = repository.tag_times[chosen]
		}
		append(&candidates, candidate)
	}

	if unavailable > 0 {
		return candidates, fail(state.env, "could not check %d package(s) for updates", unavailable)
	}

	slice.sort_by(candidates[:], proc(a, b: Update_Candidate) -> bool {
		return a.name < b.name
	})
	return candidates, true
}

UPDATE_GROUP_HEADERS :: [Update_Group]string {
	.Patch      = "Patch",
	.Minor      = "Minor",
	.Major      = "Major",
	.Major_Zero = "Major version zero",
}

UPDATE_GROUP_COLORS :: [Update_Group]string {
	.Patch      = ANSI_GREEN,
	.Minor      = ANSI_CYAN,
	.Major      = ANSI_RED,
	.Major_Zero = ANSI_RED,
}

// Headers are printed in this order, then the pinned packages.
UPDATE_GROUP_ORDER :: [?]Update_Group{.Patch, .Minor, .Major_Zero, .Major}

// Prints the candidates of `krs update`, grouped by the kind of change
// unless `--format no-group` is given.
update_print :: proc(env: ^Env, all: []Update_Candidate, options: Update_Options) {
	candidates := candidates_upgrading(all)[:]
	if .Lines in options.format {
		// Only `name@tag` lines, for piping; nothing else reaches stdout.
		for candidate in candidates {
			if !candidate.pinned {
				fmt.wprintfln(env.out, "%s@%s", printable(candidate.name), printable(candidate.chosen))
			}
		}
		update_print_held(env, all, options.format)
		return
	}

	headers, colors, targets := UPDATE_GROUP_HEADERS, UPDATE_GROUP_COLORS, UPDATE_TARGET_NAMES
	name_width, current_width := 0, 0
	upgrades := 0
	for candidate in candidates {
		name_width = max(name_width, len(candidate.name))
		current_width = max(current_width, len(candidate.current))
		if !candidate.pinned {
			upgrades += 1
		}
	}

	if .Group in options.format {
		for group in UPDATE_GROUP_ORDER {
			header := false
			for candidate in candidates {
				if candidate.pinned || candidate.group != group {
					continue
				}

				if !header {
					say(env, "%v", paint(env, colors[group], headers[group]))
					header = true
				}
				update_print_row(env, candidate, options.format, name_width, current_width)
			}
		}

		header := false
		for candidate in candidates {
			if !candidate.pinned {
				continue
			}

			if !header {
				say(env, "%v", paint(env, ANSI_DIM, "Pinned"))
				header = true
			}
			update_print_row(env, candidate, options.format, name_width, current_width)
		}
	} else {
		// Candidates are sorted by name.
		for candidate in candidates {
			update_print_row(env, candidate, options.format, name_width, current_width)
		}
	}

	if upgrades > 0 {
		info(env, "run %s to upgrade %s", "krs update -u", PACKAGES_PATH)
	}

	update_print_held(env, all, options.format)

	if len(candidates) == 0 {
		if options.target == .Latest || options.target == .Greatest {
			success(env, "every package of this project is at its highest tag")
		} else {
			success(env, "no upgrades for --target %s", targets[options.target])
		}
	}
}

// With --format cooldown, one line per package the cooldown holds back.
update_print_held :: proc(env: ^Env, candidates: []Update_Candidate, format: bit_set[Update_Format]) {
	if .Cooldown not_in format {
		return
	}

	now := time.time_to_unix(time.now())
	for candidate in candidates {
		if candidate.held_by_cooldown == "" {
			continue
		}

		age := "age unknown"
		if candidate.held_time != 0 {
			days := max(now - candidate.held_time, 0) / 86400
			switch days {
			case 0:
				age = "released today"
			case 1:
				age = "released 1 day ago"
			case:
				age = fmt.tprintf("released %d days ago", days)
			}
		}
		say(env, "  %v %s %s %v %s, %v", paint(env, ANSI_YELLOW, "cooldown"), candidate.name, candidate.current,
			paint(env, ANSI_DIM, "skips"), candidate.held_by_cooldown, paint(env, ANSI_DIM, age))
	}
}

// `  name current -> chosen`, padded to the widest name and tag, then what
// `--format` asks for.
update_print_row :: proc(env: ^Env, candidate: Update_Candidate, format: bit_set[Update_Format], name_width, current_width: int) {
	extra := strings.builder_make(context.temp_allocator)
	if .Time in format && candidate.chosen_time != 0 {
		year, month, day := time.date(time.unix(candidate.chosen_time, 0))
		fmt.sbprintf(&extra, " %04d-%02d-%02d", year, int(month), day)
	}

	if .Repo in format && candidate.source != "" && candidate.source != SOURCE_LOCAL {
		fmt.sbprintf(&extra, " %s", printable(candidate.source))
	}

	if .Diff in format {
		if github, valid := github_repository_from_origin(candidate.source); valid {
			fmt.sbprintf(&extra, " https://github.com/%s/%s/compare/%s...%s", printable(github.owner), printable(github.name),
				printable(candidate.current), printable(candidate.chosen))
		}
	}

	if .Installed_Version in format && candidate.installed != "" && candidate.installed != candidate.current {
		fmt.sbprintf(&extra, " (installed %s)", printable(candidate.installed))
	}

	name_padding := strings.repeat(" ", name_width - len(candidate.name), context.temp_allocator)
	current_padding := strings.repeat(" ", current_width - len(candidate.current), context.temp_allocator)
	if candidate.pinned {
		available := paint(env, ANSI_DIM, strings.concatenate({"(pinned; ", candidate.chosen, " available)"}, context.temp_allocator))
		say(env, "  %s%v %v%v %v%v", candidate.name, name_padding, candidate.current, current_padding, available,
			Painted(strings.to_string(extra)))
		return
	}

	colors := UPDATE_GROUP_COLORS
	say(env, "  %s%v %v%v %v %v%v", candidate.name, name_padding, candidate.current, current_padding,
		paint(env, ANSI_DIM, "->"), paint(env, colors[candidate.group], candidate.chosen), Painted(strings.to_string(extra)))
}

// Prints one JSON document: the upgrades as {name: tag}, or the
// .krs/packages.json that `krs update -u` would write (or only its list).
update_print_json :: proc(state: ^State, all: []Update_Candidate, mode: Update_Json) -> bool {
	assert(mode != .None)
	candidates := candidates_upgrading(all)[:]
	env := state.env
	value: any
	upgraded: map[string]string
	file := Packages_File_Json{format = FORMAT}
	if mode == .Upgraded {
		for candidate in candidates {
			if !candidate.pinned {
				upgraded[candidate.name] = candidate.chosen
			}
		}
		value = upgraded
	} else {
		// A copy: state.packages stays as the file on disk is.
		copied := Packages_File{format = FORMAT}
		append(&copied.packages, ..state.packages.packages[:])
		for candidate in candidates {
			if candidate.pinned {
				continue
			}

			record := packages_find(&copied, candidate.name)
			assert(record != nil)
			repository, found := repository_find(state, candidate.name, candidate.chosen, candidate.source)
			if !found {
				return fail(env, "no usable repository for %s %s", candidate.name, candidate.chosen)
			}

			resolved := state_tag_commit(state, repository.path, candidate.name, candidate.chosen, "") or_return
			record.tag = candidate.chosen
			record.commit = resolved
			record.hash = "" // computed at install
		}

		// The lockfile's own shape: `pinned` appears only on pinned records.
		for record in copied.packages {
			row := Package_Record_Json{name = record.name, source = record.source, tag = record.tag, commit = record.commit, hash = record.hash}
			if record.pinned {
				row.pinned = true
			}
			append(&file.packages, row)
		}
		if mode == .All {
			value = file
		} else {
			value = file.packages
		}
	}

	data, err := json.marshal(value, {pretty = true, use_spaces = true, spaces = 2, sort_maps_by_key = true})
	if err != nil {
		return fail(env, "cannot encode the upgrades as JSON: %v", err)
	}

	fmt.wprintln(env.out, string(data))
	return true
}

// `krs update -u`: chooses upgrades like `krs update`, then writes them to
// .krs/packages.json and installs them. Pinned packages never move.
command_update_upgrade :: proc(env: ^Env, options: Options, names: []string) -> bool {
	if options.update.doctor {
		return command_update_doctor(env, options, names)
	}

	state := state_open(env, options) or_return
	defer state_close(state)
	query := update_query_make(env, options, names) or_return
	defer update_query_destroy(query)

	for name in query.names {
		record := manifest_find(&state.manifest, name)
		if record == nil {
			return fail(env, "%s was not installed by krs in %s", name, state.shared)
		}

		if record.linked != "" {
			return fail(env, "%s is linked; run krs unlink %s first", name, name)
		}

		pin := packages_find(&state.packages, name)
		if pin == nil {
			imports, scanned := scan_directory_imports(state.env.project, path_base(state.env.project))
			if !scanned {
				return fail(env, "cannot read the Odin files under %s", state.env.project)
			}

			if !slice.contains(imports[:], name) {
				return fail(env, "%s is not used by this project; run krs update in a project that imports it", name)
			}

			// The old single-package update started from the root's tag when the project had no record of its own.
			append(
				&state.packages.packages,
				Package_Record{name = name, source = record.source, tag = record.tag, commit = record.commit, hash = record.hash},
			)
			pin = packages_find(&state.packages, name)
		}

		if pin != nil && pin.pinned && !options.update.pin {
			return fail(env, "%s is pinned at %s; add --pin to move and re-pin it, or run %s", name, pin.tag, fmt.tprintf("krs unpin %s", name))
		}

		tag := query.name_tags[name]
		if tag == "" || tag != record.tag || (pin != nil && pin.tag != tag) {
			continue
		}

		// A missing repository is reported by update_candidates.
		repository, found := repository_find(state, name, tag, record.source)
		if !found {
			continue
		}

		repository_tag_commit(env, repository.path, name, tag, record.commit) or_return
		success(env, "%s is already at %s", name, tag)
		if len(query.names) == 1 {
			return true
		}
	}

	// The root's shared/ belongs to every project on it. When it holds another
	// version of a package this project pins, this project moves to vendor/
	// instead of changing the root under the other projects.
	if !state.vendored {
		divergent: ^Package_Record
		for &record in state.packages.packages {
			installed := manifest_find(&state.manifest, record.name)
			if record.pinned && installed != nil && installed.linked == "" && installed.tag != record.tag {
				divergent = &record
				break
			}
		}

		// `krs install` would move the root's copy under the other projects.
		if divergent != nil && options.update.install == .Never {
			note(env, "%s is pinned at %s but %s holds another version; run %s before installing", divergent.name, divergent.tag, state.shared, "krs vendor")
		}

		if divergent != nil && options.update.install != .Never {
			vendor := path_join(state.scope.project, VENDOR_DIR)
			note(env, "%s is pinned at %s but %s holds another version; this project moves to %s", divergent.name, divergent.tag, state.shared, vendor)
			vendor_enter(state) or_return
			plan_reset(state)
		}
	}

	found_candidates := update_candidates(state, query) or_return
	// A package the cooldown holds in place has nothing to apply.
	candidates := candidates_upgrading(found_candidates[:])
	if options.update.pin {
		// A named pinned package moves and is pinned again at the new version.
		for &candidate in candidates {
			if candidate.pinned && slice.contains(query.names, candidate.name) {
				candidate.pinned = false
				state.pin_names[candidate.name] = true
			}
		}
	}

	if options.update.interactive {
		if !env.interactive {
			return fail(env, "choosing upgrades needs a terminal; run without -i or in a terminal")
		}

		chosen := update_choose_interactive(env, candidates[:], options.update.interactive_select) or_return
		if len(chosen) == 0 {
			success(env, "no upgrades were chosen; nothing was changed")
			return true
		}

		candidates = chosen

		// The person already confirmed by pressing Enter on the list; do not
		// ask Proceed? again.
		state.options.yes = true
	}

	return update_apply(state, candidates[:], options)
}

// Whether an upgrade starts selected for `update -i`.
interactive_preselected :: proc(which: Interactive_Select, group: Update_Group) -> bool {
	switch which {
	case .None:
		return false
	case .All:
		return true
	case .Patch:
		return group == .Patch
	case .Auto, .Minor:
		return group == .Patch || group == .Minor
	}
	return false
}

// Whether `text` is one or more ASCII digits.
interactive_digits :: proc(text: string) -> bool {
	if len(text) == 0 {
		return false
	}

	for character in transmute([]byte)text {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

// Lets a person toggle upgrades on standard input. Returns the chosen ones;
// `ok` is false when the person declined everything or input ended early.
update_choose_interactive :: proc(env: ^Env, candidates: []Update_Candidate, which: Interactive_Select) -> (chosen: [dynamic]Update_Candidate, ok: bool) {
	offered := make([dynamic]Update_Candidate, context.temp_allocator)
	for candidate in candidates {
		if !candidate.pinned && candidate_upgrades(candidate) {
			append(&offered, candidate)
		}
	}

	if len(offered) == 0 {
		return chosen, true
	}

	selected := make([]bool, len(offered), context.temp_allocator)
	for candidate, index in offered {
		selected[index] = interactive_preselected(which, candidate.group)
	}

	for _ in 0 ..< len(offered) * 4 + 16 {
		for candidate, index in offered {
			mark := paint(env, ANSI_GREEN, "[x]") if selected[index] else paint(env, ANSI_DIM, "[ ]")
			say(env, "  %v %2d  %s %s %v %s", mark, index + 1, candidate.name, candidate.current, paint(env, ANSI_DIM, "->"), candidate.chosen)
		}

		prompt(env, "%v ", paint(env, ANSI_DIM, "toggle numbers, a for all, Enter to apply, q to quit:"))
		answer := strings.to_lower(ask_line(env), context.temp_allocator)

		switch answer {
		case "":
			for candidate, index in offered {
				if selected[index] {
					append(&chosen, candidate)
				}
			}
			return chosen, true
		case "q":
			return chosen, fail(env, "no upgrades were applied")
		case "a":
			all := true
			for value in selected {
				all &&= value
			}
			for &value in selected {
				value = !all
			}
			continue
		}

		toggles := make([dynamic]int, context.temp_allocator)
		valid := true
		parts := strings.split_multi(answer, {" ", ","}, context.temp_allocator)
		for part in parts {
			if part == "" {
				continue
			}

			number, parsed := strconv.parse_int(part, 10)
			if !interactive_digits(part) || !parsed || number < 1 || number > len(offered) {
				warn(env, "%s is not a number from the list", part)
				valid = false
				break
			}
			append(&toggles, number - 1)
		}

		if valid {
			for index in toggles {
				selected[index] = !selected[index]
			}
		}
	}

	return chosen, fail(env, "too many answers; nothing was changed")
}

// Moves every unpinned candidate to its chosen release in one plan. Pinned
// candidates are listed as held and never moved. Confirmation reads
// state.options.yes; callers must open the state with the same options.
update_apply :: proc(state: ^State, candidates: []Update_Candidate, options: Options) -> bool {
	if options.yes {
		state.options.yes = true
	}

	queued := 0
	for candidate in candidates {
		if candidate.pinned {
			info(state.env, "%s is pinned at %s; %s is available", candidate.name, candidate.current, candidate.chosen)
			continue
		}

		compatibility := Version_Compatibility.Breaking
		if current, current_ok := parse_tag(candidate.current); current_ok {
			chosen, _ := parse_tag(candidate.chosen)
			compatibility = version_compatibility(current, chosen)
		}

		say_version_change(state.env, candidate.name, candidate.current, candidate.chosen, compatibility)
		update_report_dependants(state, candidate.name, candidate.chosen)
		append(
			&state.queue,
			Request {
				name = candidate.name,
				tag = candidate.chosen,
				source = candidate.source,
				by = "krs update",
				kind = .Update,
				recorded = true,
				source_trusted = true,
			},
		)
		if options.update.pin {
			state.pin_names[candidate.name] = true
		}
		queued += 1
	}

	if queued == 0 {
		success(state.env, "every package of this project is at its target version")
		return true
	}

	plan_discover(state) or_return
	plan_drain(state) or_return
	if options.update.install == .Never {
		return plan_record_only(state)
	}

	// --install=always is the confirmation. This runs after the vendor/ switch,
	// which still asks on its own.
	if options.update.install == .Always {
		state.options.yes = true
	}

	return plan_apply(state)
}

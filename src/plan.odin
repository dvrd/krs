package krs

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

Options :: struct {
	root:   string,
	frozen:  bool,
	yes:     bool,
	restore: bool, // `unlink` installs the recorded release in place of the link
	repair:  bool, // `install` reinstalls packages whose files no longer match
	fetch:   bool, // `update` refreshes GitHub caches before checking
	all:     bool, // `update` moves every package to its highest compatible tag
}

Action :: enum {
	Keep, // installed by krs at the wanted tag
	Install, // to be written into `shared/`
	Unmanaged, // a directory krs did not install; left alone
	Linked, // a symbolic link to a working `src/`; left alone
}

// What krs has decided for one package name in this run.
Decision :: struct {
	name:                   string,
	action:                 Action,
	tag:                    string,
	commit:                 string,
	source:                 string,
	repository:             string,
	installed_tag:          string, // the tag in `shared/` before this run, if krs installed one
	forced:                 bool, // named explicitly by `update` or `unlink`
	repair:                 bool, // reinstall at the recorded release; installed files were changed
	recorded:               bool, // belongs in the project's `.krs/packages.json`
	selection:              Selection,
	has_selection:          bool,
	contents:               [dynamic][]byte, // the bytes of `selection.files`, once prepared
	hash:                   string,
	default_source:         string, // source of the first request that took any version
	default_source_trusted: bool, // whether default_source came from the user's own records
	failed:                 bool, // a request for this name failed in this pass; choose no default
}

Request_Kind :: enum {
	Dependency,
	Update,
	Restore,
}

// A version requested by a dependency, an update, or an unlink.
Request :: struct {
	name:           string,
	tag:            string, // empty: any version will do
	commit:         string,
	source:         string,
	by:             string,
	kind:           Request_Kind,
	recorded:       bool,
	source_trusted: bool, // source came from the user's own records, not a dependency
}

Version_Conflict :: struct {
	name:     string,
	current:  string,
	incoming: string,
	by:       string,
	higher:   string,
	lower:    string,
}

Repository :: struct {
	path:   string,
	source: string,
	tags:   [dynamic]string,
}

State :: struct {
	env:       ^Env,
	options:   Options,
	shared:    string,
	config:    Config,
	packages:  Packages_File,
	manifest:  Manifest_File,
	decisions: map[string]^Decision,
	order:     [dynamic]string,
	queue:     [dynamic]Request,
	reported:  [dynamic]Painted,
	altered:   [dynamic]string,
	locks:     [2]^os.File,
	scope:     Journal_Scope,
	fetch_configured: bool,
	version_answers:  map[Version_Conflict]string,
	version_question: Version_Conflict,
}

// The Odin root to work on: `--root`, else `ODIN_ROOT`, else `odin root`.
state_open :: proc(env: ^Env, options: Options) -> (state: ^State, ok: bool) {
	if env.project == "" {
		return nil, fail(env, "cannot locate the current project directory")
	}

	root := options.root
	if root == "" {
		root = env.default_root
	}

	if root == "" && env.find_root != nil {
		root = env.find_root()
	}

	if root == "" {
		return nil, fail(env, "no Odin root: pass --root=<path> or set ODIN_ROOT")
	}

	root = path_trim_trailing_slash(path_expand_home(root, env.home))
	if !strings.has_prefix(root, "/") {
		root = path_join(env.project, root)
	}

	if !os.is_directory(root) {
		return nil, fail(env, "the Odin root %s does not exist", root)
	}

	state = new(State)
	state.env = env
	state.options = options
	defer if !ok {
		state_close(state)
	}
	state_lock(state, root) or_return
	journal_recover(env, state.scope) or_return
	state.config = load_config(env) or_return
	state.packages = load_packages(env) or_return
	state.manifest = load_manifest(env, state.shared) or_return

	return state, true
}

// Prints a message once per command, however often it comes up.
report_once :: proc(state: ^State, format: string, arguments: ..any) {
	message := styled(state.env, format, ..arguments)
	for existing in state.reported {
		if existing == message {
			return
		}
	}

	append(&state.reported, message)
	say(state.env, "%v", message)
}

repository_open :: proc(path: string, cached := false) -> (repository: Repository, reason: string) {
	repo, ok := git_open(path)
	if !ok {
		return {}, "it is not a Git repository"
	}

	defer git_close(repo)

	repository.path = path
	repository.tags = git_semver_tags(repo)
	if len(repository.tags) == 0 {
		return {}, "it has no semantic-version tag"
	}

	if cached {
		address, found := cached_origin(repo)
		if !found || git_repository_workdir(repo) != nil {
			return {}, "it is not a bare cached repository with an origin"
		}
		repository.source = source_identity(address)
	} else {
		repository.source = git_source(repo)
	}

	return repository, ""
}

repository_has_tag :: proc(repository: ^Repository, tag: string) -> bool {
	for existing in repository.tags {
		if existing == tag {
			return true
		}
	}

	return false
}

repository_candidate :: proc(state: ^State, path, tag, origin: string, cached := false) -> (repository: Repository, ok: bool) {
	if !os.is_directory(path) {
		return {}, false
	}

	reason: string
	repository, reason = repository_open(path, cached)
	if reason == "" && cached {
		if _, valid := github_repository_from_origin(repository.source); !valid {
			reason = "it has no HTTPS GitHub origin"
		}
	}

	if reason == "" && tag != "" && !repository_has_tag(&repository, tag) {
		reason = fmt.aprintf("it has no tag %s", tag)
	}

	if reason == "" && origin != "" && origin != repository.source {
		reason = fmt.aprintf("it comes from %s, not the recorded %s", repository.source, origin)
	}

	if reason != "" {
		report_once(state, "skipped %s: %v", path, reason)
		return {}, false
	}
	return repository, true
}

// Check configured source directories before cached GitHub repositories.
repository_find :: proc(state: ^State, name, tag, source: string) -> (repository: Repository, ok: bool) {
	origin := source_identity(source)
	for directory in state.config.source_directories {
		candidate, found := repository_candidate(state, path_join(directory, name), tag, origin)
		if found {
			return candidate, true
		}
	}

	if github, valid := github_repository_from_origin(origin); valid {
		candidate, found := repository_candidate(state, github_cache_path(state.env, github), tag, origin, true)
		if found {
			return candidate, true
		}
	} else if origin == "" {
		cache := github_store(state.env)
		owners, err := os.read_all_directory_by_path(cache, context.temp_allocator)
		if err == nil {
			for owner in owners {
				if owner.type != .Directory {
					continue
				}
				locator := github_repository(path_join(owner.name, name)) or_continue
				candidate := repository_candidate(state, github_cache_path(state.env, locator), tag, github_origin(locator), true) or_continue
				if ok {
					report_once(state, "more than one cached GitHub repository matches %s; select one in %s", name, "config.json libs")
					return {}, false
				}
				repository, ok = candidate, true
			}
		}
		if ok {
			return
		}
	}

	// Older caches were stored directly under the package name.
	return repository_candidate(state, path_join(repository_store(state.env), name), tag, origin, true)
}

// A dependency's recorded source does not choose the repository; report
// when the repository that was chosen comes from elsewhere.
repository_check_pin :: proc(state: ^State, name, wanted: string, candidate: Repository) {
	if wanted == "" || candidate.source == wanted {
		return
	}

	report_once(state, "a dependency pins %s from %s; using %s, which comes from %s", name, wanted, candidate.path, candidate.source)
}

repository_resolve :: proc(state: ^State, name, tag, source, commit: string, source_trusted: bool) -> (repository: Repository, ok: bool) {
	origin := source_identity(source) if source_trusted else ""
	wanted := "" if source_trusted else source_identity(source)
	library, configured := state.config.libs[name]
	github: GitHub_Repository
	if state.fetch_configured && configured {
		if library.source != "github" {
			return {}, fail(state.env, "libs.%s must use source github", name)
		}

		valid: bool
		github, valid = github_repository(library.target)
		if !valid {
			return {}, fail(state.env, "libs.%s.target must be a GitHub owner/repo", name)
		}

		if origin == "" {
			origin = github_origin(github)
		}
	}

	candidate, found := repository_find(state, name, tag, origin)
	if found {
		repository_check_pin(state, name, wanted, candidate)
		return candidate, true
	}

	if state.fetch_configured && configured && (!state.options.frozen || (tag != "" && commit != "")) {
		if origin != github_origin(github) {
			return {}, fail(state.env, "the GitHub repository in libs.%s does not match the recorded origin %q", name, origin)
		}

		cache_github_repository(state.env, github) or_return
		if refreshed, available := repository_candidate(state, github_cache_path(state.env, github), tag, origin, true); available {
			repository_check_pin(state, name, wanted, refreshed)
			return refreshed, true
		}
		return {}, fail(state.env, "the GitHub repository for %s did not provide tag %s", name, tag)
	}

	if pinned, valid := github_repository_from_origin(origin); valid {
		note(state.env, "use %s to cache the recorded origin", fmt.tprintf("krs fetch %s", github_locator(pinned)))
	} else if _, wanted_github := github_repository_from_origin(wanted); wanted_github {
		note(state.env, "a dependency pins %s from %s; add a libs entry for %s in config.json to use it", name, wanted, name)
	}

	if tag == "" {
		return {}, fail(state.env, "no repository for \"%s\" in the source directories or repository store", name)
	}
	return {}, fail(state.env, "no repository for \"%s\" with tag %s in the source directories or repository store", name, tag)
}

decision_new :: proc(state: ^State, name: string) -> ^Decision {
	decision := new(Decision)
	decision.name = name
	state.decisions[name] = decision
	append(&state.order, name)

	return decision
}

// Looks at what `shared/` holds for a name before anything asks for a version.
decision_create :: proc(state: ^State, name: string) -> ^Decision {
	decision := decision_new(state, name)
	directory := path_join(state.shared, name)
	record := manifest_find(&state.manifest, name)

	if record == nil {
		decision.action = .Unmanaged if path_present(directory) else .Install
		return decision
	}

	if record.linked != "" {
		decision.action = .Linked
		return decision
	}

	if !path_present(directory) {
		decision.action = .Install
		return decision
	}

	decision.action = .Keep
	decision.tag = record.tag
	decision.commit = record.commit
	decision.source = record.source
	decision.repository = record.path
	decision.hash = record.hash
	decision.installed_tag = record.tag

	hash, ok := hash_directory(directory)
	if !ok || hash != record.hash {
		warn(state.env, "%s does not match the hash recorded for %s %s", directory, name, record.tag)
		if state.options.repair {
			// Clear the tag so `plan_request` resolves the recorded release
			// again through `decision_set_tag`, which checks the commit.
			decision.repair = true
			decision.action = .Install
			decision.tag = ""
			decision.commit = ""
			decision.hash = ""
		} else {
			append(&state.altered, name)
		}
	}

	return decision
}

repository_tag_commit :: proc(env: ^Env, path, name, tag, expected_commit: string) -> (commit: string, ok: bool) {
	resolved, resolved_ok := git_tag_commit(path, tag)
	if !resolved_ok {
		return "", fail(env, "cannot resolve tag %s of %s", tag, path)
	}

	if expected_commit != "" && expected_commit != resolved {
		return "", fail(
			env,
			"%s %s was recorded at commit %s but the tag now resolves to %s; a published tag must not move",
			name,
			tag,
			expected_commit,
			resolved,
		)
	}

	return resolved, true
}

// Points a decision at a tag, resolving the repository and the commit.
decision_set_tag :: proc(state: ^State, decision: ^Decision, tag, source, commit: string, source_trusted: bool) -> bool {
	repository := repository_resolve(state, decision.name, tag, source, commit, source_trusted) or_return

	chosen := tag
	if chosen == "" {
		chosen, _ = highest_tag(repository.tags[:])
	}

	resolved := repository_tag_commit(state.env, repository.path, decision.name, chosen, commit) or_return
	decision.tag = chosen
	decision.commit = resolved
	decision.source = repository.source
	decision.repository = repository.path
	decision.has_selection = false
	decision.hash = ""
	clear(&decision.contents)
	decision.action = .Install

	record := manifest_find(&state.manifest, decision.name)
	if record != nil && record.linked == "" && record.tag == chosen && record.commit == resolved &&
	   os.is_directory(path_join(state.shared, decision.name)) {
		if !decision.repair {
			decision.action = .Keep
			decision.hash = record.hash
		}
	} else {
		// A different release was chosen (for example a dependency wants a
		// newer tag): this is a normal replace, not a repair.
		decision.repair = false
	}

	return true
}

// Two versions of one package are wanted. Compatible ones resolve to the
// higher; a breaking difference is the user's choice.
reconcile :: proc(state: ^State, name, current, incoming, by: string) -> (chosen: string, ok: bool) {
	current_version, current_ok := parse_tag(current)
	incoming_version, incoming_ok := parse_tag(incoming)
	if !current_ok || !incoming_ok {
		return "", fail(state.env, "%s: cannot compare %s with %s", name, current, incoming)
	}

	higher := current
	lower := incoming
	if version_compare(incoming_version, current_version) == .Higher {
		higher = incoming
		lower = current
	}

	if version_compatibility(current_version, incoming_version) == .Compatible {
		say(state.env, "%s: %s and %s (wanted by %s) are compatible; using %s", name, current, incoming, by, higher)
		return higher, true
	}

	if state.options.frozen || !state.env.interactive {
		say(state.env, "%s: %s and %s (wanted by %s) are not compatible", name, current, incoming, by)
		return "", fail(state.env, "%s needs a decision between %s and %s; run krs install in a terminal", name, current, incoming)
	}

	conflict := Version_Conflict{name, current, incoming, by, higher, lower}
	if answer, answered := state.version_answers[conflict]; answered {
		return answer, true
	}

	if state.version_question.name == "" {
		state.version_question = conflict
	}
	return "", false
}

ask_version :: proc(env: ^Env, conflict: Version_Conflict) -> (chosen: string, ok: bool) {
	name, higher, lower := conflict.name, conflict.higher, conflict.lower
	say(env, "%s: %s and %s (wanted by %s) are not compatible", name, conflict.current, conflict.incoming, conflict.by)
	say(env, "  keep %s: bring every package that uses %s %s up to it", higher, name, lower)
	say(env, "  keep %s: adapt the package that wants %s to the older one, through krs link", lower, higher)
	prompt(env, "Which version of %s stays in shared/? %v ", name, paint(env, ANSI_DIM, fmt.tprintf("[%s]", higher)))

	answer := ask_line(env)
	switch answer {
	case "", higher:
		return higher, true
	case lower:
		return lower, true
	}

	return "", fail(env, "\"%s\" is neither %s nor %s", answer, higher, lower)
}

// Applies a request to the decision for the current resolution pass.
decision_apply :: proc(state: ^State, decision: ^Decision, request: Request) -> bool {
	if decision.action == .Unmanaged || (decision.action == .Linked && request.kind != .Restore) {
		return true
	}

	if request.kind != .Dependency {
		decision_set_tag(state, decision, request.tag, request.source, request.commit, request.source_trusted) or_return
		decision.forced = true
		return true
	}

	if request.tag == "" {
		return true
	}

	if decision.tag == "" {
		decision_set_tag(state, decision, request.tag, request.source, request.commit, request.source_trusted) or_return
		return true
	}

	if decision.tag == request.tag {
		if request.commit != "" && decision.commit != "" && request.commit != decision.commit {
			return fail(
				state.env,
				"%s %s is at commit %s here but %s recorded commit %s; a published tag must not move",
				decision.name,
				decision.tag,
				decision.commit,
				request.by,
				request.commit,
			)
		}

		if !request.source_trusted && request.source != "" && source_identity(request.source) != decision.source {
			report_once(state, "%s pins %s from %s; using the one from %s", request.by, decision.name, source_identity(request.source), decision.source)
		}
		return true
	}

	if decision.forced {
		note(state.env, "%s recorded %s %s; %s was asked for explicitly", request.by, decision.name, request.tag, decision.tag)
		return true
	}

	chosen := reconcile(state, decision.name, decision.tag, request.tag, request.by) or_return
	if chosen == decision.tag {
		return true
	}

	return decision_set_tag(state, decision, chosen, request.source, request.commit, request.source_trusted)
}

// The files a decided release installs, read once.
decision_selection :: proc(state: ^State, decision: ^Decision, release: Git_Release) -> bool {
	if decision.has_selection {
		return true
	}

	selection, ok := select_files(Source{release = release}, decision.name)
	if !ok && selection.problem != "" {
		return fail(state.env, "cannot install %s %s: %v", decision.name, decision.tag, selection.problem)
	}

	if !ok {
		return fail(state.env, "cannot read %s %s from %s", decision.name, decision.tag, decision.repository)
	}

	decision.selection = selection
	decision.has_selection = true
	return true
}

// A missing lockfile is valid. A present lockfile must be readable.
release_pins :: proc(release: Git_Release) -> (pins: Packages_File, problem: string) {
	data, status := git_read_file(release, PACKAGES_PATH)
	switch status {
	case .Missing:
		return
	case .Failed:
		return {}, "cannot be read"
	case .Read:
		problem = json_record_problem(data, &pins)
		if problem != "" {
			return
		}
		return pins, pins_problem(pins)
	}
	unreachable()
}

// A dependency's pins are not trusted: each field must have its expected shape.
// The offending values are not printed.
pins_problem :: proc(pins: Packages_File) -> string {
	for record in pins.packages {
		if !is_package_name(record.name) {
			return fmt.aprintf("has an invalid package name")
		}

		if record.tag != "" {
			if _, valid := parse_tag(record.tag); !valid {
				return fmt.aprintf("records %s with an invalid tag", record.name)
			}
		}

		if record.commit != "" && !is_commit_id(record.commit) {
			return fmt.aprintf("records %s with an invalid commit", record.name)
		}

		for character in transmute([]byte)record.source {
			if character < 0x20 || character == 0x7f {
				return fmt.aprintf("records %s with an invalid source", record.name)
			}
		}
	}
	return ""
}

// Queues what a decided package itself imports.
enqueue_dependencies :: proc(state: ^State, decision: ^Decision, recorded: bool, queue: ^[dynamic]Request) -> bool {
	imports: [dynamic]string
	pins: Packages_File
	by := decision.name

	switch decision.action {
	case .Unmanaged:
		return true
	case .Linked:
		read_ok: bool
		imports, read_ok = scan_directory_imports(path_join(state.shared, decision.name), decision.name)
		if !read_ok {
			return fail(state.env, "cannot scan the installed files of %s", by)
		}
	case .Keep, .Install:
		by = fmt.aprintf("%s %s", decision.name, decision.tag)
		release, ok := git_release_open(decision.repository, decision.tag, decision.commit)
		if ok {
			defer git_release_close(release)
			decision_selection(state, decision, release) or_return
			imports = decision.selection.imports
			problem: string
			pins, problem = release_pins(release)
			if problem != "" {
				return fail(state.env, "%s: %s %v", by, PACKAGES_PATH, problem)
			}
		} else if decision.action == .Keep {
			read_ok: bool
			imports, read_ok = scan_directory_imports(path_join(state.shared, decision.name), decision.name)
			if !read_ok {
				return fail(state.env, "cannot scan the installed files of %s", by)
			}
		} else {
			return fail(state.env, "cannot read %s %s from %s", decision.name, decision.tag, decision.repository)
		}
	}

	for imported in imports {
		request := Request{name = imported, by = by, recorded = recorded}
		pin := packages_find(&pins, imported)
		if pin != nil {
			request.tag = pin.tag
			request.commit = pin.commit
			request.source = pin.source
		}
		append(queue, request)
	}

	return true
}

plan_request :: proc(state: ^State, request: Request) -> bool {
	if !is_package_name(request.name) {
		return fail(state.env, "\"%s\" (imported by %s) is not a usable package name", request.name, request.by)
	}

	if request.name == path_base(state.env.project) && request.kind == .Dependency {
		return true
	}

	decision, existed := state.decisions[request.name]
	if !existed {
		decision = decision_create(state, request.name)
		pin := packages_find(&state.packages, request.name)
		if pin != nil && request.kind == .Dependency {
			own := Request{name = pin.name, tag = pin.tag, commit = pin.commit, source = pin.source, by = "this project", source_trusted = true}
			if !decision_apply(state, decision, own) {
				decision.failed = true
				return false
			}
		}
	}

	if !decision_apply(state, decision, request) {
		decision.failed = true
		return false
	}

	if decision.action == .Install && decision.tag == "" && decision.default_source == "" {
		decision.default_source = request.source
		decision.default_source_trusted = request.source_trusted
	}

	decision.recorded = decision.recorded || request.recorded
	return true
}

// After every request of a pass is applied, a package nobody pinned takes the
// version shared/ records for it, else its highest tag.
plan_choose_defaults :: proc(state: ^State) -> bool {
	resolved := true
	for name in state.order {
		decision := state.decisions[name]
		if decision.failed || decision.action != .Install || decision.tag != "" {
			continue
		}

		record := manifest_find(&state.manifest, name)
		ok: bool
		if record != nil && record.tag != "" {
			ok = decision_set_tag(state, decision, record.tag, record.source, record.commit, true)
		} else {
			ok = decision_set_tag(state, decision, "", decision.default_source, "", decision.default_source_trusted)
		}

		if !ok {
			resolved = false
		}
	}

	for name in state.order {
		decision := state.decisions[name]
		assert(decision.failed || !resolved || decision.action != .Install || decision.tag != "")
	}
	return resolved
}

// Walk the selected releases from the roots. A request survives the pass
// only if its parent is still reachable and its selected release asks for it.
plan_collect_requests :: proc(state: ^State, roots: []Request) -> (next: [dynamic]Request, ok: bool) {
	ok = true
	append(&next, ..roots)
	expanded: map[string]bool
	defer delete(expanded)
	for index := 0; index < len(next); index += 1 {
		request := next[index]
		decision := state.decisions[request.name]
		if decision == nil || (decision.action == .Install && decision.tag == "") {
			continue
		}

		recorded, seen := expanded[request.name]
		if seen && (recorded || !request.recorded) {
			continue
		}

		expanded[request.name] = request.recorded
		if !enqueue_dependencies(state, decision, request.recorded, &next) {
			ok = false
		}
	}
	return
}

// Recompute decisions from the requests of the previous pass. Treat errors
// and version questions as provisional until the reachable graph stabilizes.
plan_drain :: proc(state: ^State) -> bool {
	env := state.env
	roots := state.queue[:]
	requests := roots
	initial_reports := slice.clone(state.reported[:])
	history: [dynamic][]Request
	defer delete(history)
	output := strings.builder_make()
	errors := strings.builder_make()
	defer strings.builder_destroy(&output)
	defer strings.builder_destroy(&errors)
	buffered := env^
	buffered.out = strings.to_writer(&output)
	buffered.err = strings.to_writer(&errors)

	for {
		clear(&state.decisions)
		clear(&state.order)
		clear(&state.altered)
		clear(&state.reported)
		append(&state.reported, ..initial_reports)
		state.version_question = {}
		strings.builder_reset(&output)
		strings.builder_reset(&errors)

		state.env = &buffered
		resolved := true
		for request in requests {
			if !plan_request(state, request) {
				resolved = false
			}
		}

		if !plan_choose_defaults(state) {
			resolved = false
		}
		next, expanded_ok := plan_collect_requests(state, roots)
		state.env = env

		if slice.equal(requests, next[:]) {
			question := state.version_question
			if question.name != "" {
				answer := ask_version(env, question) or_return
				state.version_answers[question] = answer
				clear(&history)
				continue
			}

			fmt.wprint(env.out, strings.to_string(output))
			fmt.wprint(env.err, strings.to_string(errors))
			return resolved && expanded_ok
		}

		for previous in history {
			if slice.equal(previous, next[:]) {
				return fail(env, "the dependency graph does not stabilize; selected versions change each other's requirements")
			}
		}

		append(&history, requests)
		requests = next[:]
	}
}

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
			append(
				&file.packages,
				Package_Record {
					name = name,
					source = source_identity(decision.source),
					tag = decision.tag,
					commit = decision.commit,
					hash = decision.hash,
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
			path = decision.repository,
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
		stage_json(&transaction, path_join(state.scope.project, PACKAGES_PATH), packages) or_return
	}

	transaction_commit(&transaction) or_return

	success(state.env, "%d installed, %d already in place", len(installs), len(state.order) - len(installs))
	return true
}

// Queues one request for every `shared:` name the project imports.
plan_discover :: proc(state: ^State) -> bool {
	progress_start(state.env, "Scanning imports")
	imports, ok := scan_directory_imports(state.env.project, path_base(state.env.project))
	progress_stop(state.env)
	if !ok {
		return fail(state.env, "cannot read the Odin files under %s", state.env.project)
	}

	for imported in imports {
		append(&state.queue, Request{name = imported, by = "this project", recorded = true})
	}

	return true
}

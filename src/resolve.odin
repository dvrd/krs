package krs

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

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

// What one release of one package installs and pins.
Release_Facts :: struct {
	commit:    string, // the commit the facts were read from
	selection: Selection,
	pins:      Packages_File,
	problem:   string, // why the release's own PACKAGES_PATH is unusable, or ""
}

Installed_Hash :: struct {
	hash: string,
	ok:   bool,
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

	installed, hashed := state.installed_hashes[name]
	if !hashed {
		installed.hash, installed.ok = hash_directory(directory)
		state.installed_hashes[name] = installed
		state.counts.installed_hashes += 1
	}

	assert(installed.ok || installed.hash == "")
	hash, ok := installed.hash, installed.ok
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

// Points a decision at a tag, resolving the repository and the commit.
decision_set_tag :: proc(state: ^State, decision: ^Decision, tag, source, commit: string, source_trusted: bool) -> bool {
	repository := repository_resolve(state, decision.name, tag, source, commit, source_trusted) or_return

	chosen := tag
	if chosen == "" {
		chosen, _ = highest_tag(repository.tags[:])
	}

	resolved := state_tag_commit(state, repository.path, decision.name, chosen, commit) or_return
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

// What a decided release installs and pins, when an earlier pass read it.
decision_cached_facts :: proc(state: ^State, decision: ^Decision) -> (facts: Release_Facts, hit: bool) {
	facts, hit = state.selections[{decision.repository, decision.commit, decision.name}]
	if hit {
		assert(facts.commit == decision.commit)
		decision.selection = facts.selection
		decision.has_selection = true
	}
	return
}

// The files a decided release installs, read once per command.
decision_selection :: proc(state: ^State, decision: ^Decision, release: Git_Release) -> bool {
	if decision.has_selection {
		return true
	}

	if _, hit := decision_cached_facts(state, decision); hit {
		return true
	}

	selection, ok := select_files(Source{release = release}, decision.name)
	state.counts.selections += 1
	if !ok && selection.problem != "" {
		return fail(state.env, "cannot install %s %s: %v", decision.name, decision.tag, selection.problem)
	}

	if !ok {
		return fail(state.env, "cannot read %s %s from %s", decision.name, decision.tag, decision.repository)
	}

	facts := Release_Facts{commit = decision.commit, selection = selection}
	facts.pins, facts.problem = release_pins(release)
	state.selections[{decision.repository, decision.commit, decision.name}] = facts
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
		facts, hit := decision_cached_facts(state, decision)
		release: Git_Release
		ok := hit
		if !hit {
			release, ok = git_release_open(decision.repository, decision.tag, decision.commit)
		}

		if ok {
			if !hit {
				defer git_release_close(release)
				decision_selection(state, decision, release) or_return
				facts, hit = decision_cached_facts(state, decision)
				assert(hit)
			}

			imports = decision.selection.imports
			pins = facts.pins
			if facts.problem != "" {
				return fail(state.env, "%s: %s %v", by, PACKAGES_PATH, facts.problem)
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

// Runs one resolution pass with its output held back. The caller's env is
// restored however the pass ends.
plan_pass :: proc(state: ^State, buffered: ^Env, requests, roots: []Request) -> (next: [dynamic]Request, resolved, expanded_ok: bool) {
	original := state.env
	state.env = buffered
	defer state.env = original

	resolved = true
	for request in requests {
		if !plan_request(state, request) {
			resolved = false
		}
	}

	if !plan_choose_defaults(state) {
		resolved = false
	}

	next, expanded_ok = plan_collect_requests(state, roots)
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

		next, resolved, expanded_ok := plan_pass(state, &buffered, requests, roots)
		assert(state.env == env)

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

package krs

import "core:os"
import "core:strings"

Options :: struct {
	root:   string,
	frozen:  bool,
	yes:     bool,
	restore: bool, // `unlink` installs the recorded release in place of the link
	repair:  bool, // `install` reinstalls packages whose files no longer match
	fetch:   bool, // `update` refreshes GitHub caches before checking
	update:  Update_Options, // the flags only `update` takes
}

// How often a command touched Git or the disk; tests assert the caches work.
Resolution_Counts :: struct {
	repository_opens: int,
	tag_resolves:     int,
	selections:       int,
	installed_hashes: int,
	fetches:          int,
}

State :: struct {
	env:       ^Env,
	options:   Options,
	shared:    string,
	vendored:  bool, // shared is <project>/vendor
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
	pin_names:        map[string]bool, // pinned by this run's --pin
	// Per-command caches, kept across resolution passes; never persisted.
	repositories:     map[string]Repository_Lookup, // key: path + (cached ? "\x00cached" : "")
	tag_commits:      map[[2]string]string, // {path, tag} -> commit
	selections:       map[[3]string]Release_Facts, // {path, commit, package name} -> selection and pins
	installed_hashes: map[string]Installed_Hash, // package name -> hash of shared/<name>
	fetched:          map[string]bool, // GitHub origin -> whether this command's one fetch succeeded
	counts:           Resolution_Counts,
	git_initialized:  bool, // libgit2 stays initialized until state_close
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
	if git_libgit2_init() < 0 {
		return nil, fail(env, "cannot initialize libgit2")
	}
	state.git_initialized = true
	journal_recover(env, state.scope) or_return
	state.config = load_config(env) or_return
	state.packages = load_packages(env) or_return

	// A project with its own collection reads and writes vendor/, not the root.
	vendor := path_join(state.scope.project, VENDOR_DIR)
	if os.exists(path_join(vendor, MANIFEST_PATH)) {
		state.shared = vendor
		state.vendored = true
	}

	state.manifest = load_manifest(env, state.shared) or_return

	return state, true
}

// Forgets everything a previous plan decided, so another plan can run on
// the same state (for example after switching to vendor/).
plan_reset :: proc(state: ^State) {
	clear(&state.queue)
	clear(&state.decisions)
	clear(&state.order)
	clear(&state.altered)
	clear(&state.installed_hashes)
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

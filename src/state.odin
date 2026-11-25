package krs

import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:os"
import "core:slice"
import "core:strings"

FORMAT :: 1
KRS_DATA_PATH :: ".local/shared/krs"

PACKAGES_PATH :: ".krs/packages.json"
MANIFEST_PATH :: ".krs/manifest.json"
VENDOR_DIR :: "vendor"
CONFIG_PATH :: ".config/krs/config.json"

// One dependency of a project, as written to `.krs/packages.json`. No path of
// this machine is ever stored here.
Package_Record :: struct {
	name:   string,
	source: string,
	tag:    string,
	commit: string,
	hash:   string,
	pinned: bool `json:"pinned,omitempty"`, // held at tag: never upgraded, never moved by a dependency
}

Packages_File :: struct {
	format:   int,
	packages: [dynamic]Package_Record,
}

// One package installed in an Odin root, as written to
// `shared/.krs/manifest.json`.
Manifest_Record :: struct {
	name:   string,
	source: string,
	tag:    string,
	commit: string,
	hash:   string,
	path:   string, // the repository on this machine
	linked: string `json:"linked,omitempty"`, // the linked `src/`, when linked
}

Manifest_File :: struct {
	format:   int,
	packages: [dynamic]Manifest_Record,
}

Library_Source :: struct {
	source: string,
	target: string,
}

Config :: struct {
	format:             int,
	source_directories: [dynamic]string,
	libs:               map[string]Library_Source,
}

// Where krs runs: everything it would otherwise take from the process, so the
// commands can be driven from tests.
Env :: struct {
	project:      string, // the project directory, absolute
	home:         string,
	default_root: string,
	find_root:    proc() -> string, // `ODIN_ROOT`, or what `odin root` prints
	out:          io.Writer,
	err:          io.Writer,
	input:        io.Reader,
	interactive:  bool, // a person can be asked
	style:        Output_Style,
	progress:     ^Progress,
	download_tags: proc(env: ^Env, repo: ^Git_Repository, directory, origin: string) -> bool,
}

ask_line :: proc(env: ^Env) -> string {
	builder := strings.builder_make()
	buffer: [1]byte

	for {
		count, err := io.read(env.input, buffer[:])
		if err != nil || count == 0 || buffer[0] == '\n' {
			break
		}
		strings.write_byte(&builder, buffer[0])
	}

	return strings.trim_space(strings.to_string(builder))
}

ask_yes :: proc(env: ^Env, question: string) -> bool {
	prompt(env, "%v %v ", question, paint(env, ANSI_DIM, "[y/N]"))
	answer := strings.to_lower(ask_line(env))
	return answer == "y" || answer == "yes"
}

json_record_problem :: proc(data: []byte, value: ^$T) -> string {
	if json.unmarshal(data, value) != nil {
		return "is not valid JSON"
	}

	if value.format > FORMAT {
		return fmt.aprintf("was written by a newer krs (format %d)", value.format)
	}

	return ""
}

// Reads a JSON file into `value`. A missing file is not an error.
load_json :: proc(env: ^Env, path: string, value: ^$T) -> (found: bool, ok: bool) {
	info, stat_err := os.lstat(path, context.temp_allocator)
	if stat_err == .Not_Exist {
		return false, true
	}

	if stat_err != nil || (info.type != .Regular && info.type != .Symlink) {
		return false, fail(env, "cannot read %s", path)
	}

	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return false, fail(env, "cannot read %s: %v", path, err)
	}

	if problem := json_record_problem(data, value); problem != "" {
		return false, fail(env, "%s %v", path, problem)
	}

	return true, true
}

stage_json :: proc(transaction: ^Transaction, path: string, value: any) -> bool {
	data, marshal_err := json.marshal(value, {pretty = true, use_spaces = true, spaces = 2})
	if marshal_err != nil {
		return fail(transaction.env, "cannot encode %s: %v", path, marshal_err)
	}

	change := transaction_stage(transaction, path, .Record) or_return
	text := strings.concatenate({string(data), "\n"})
	if err := os.write_entire_file(change.staged, text); err != nil {
		return fail(transaction.env, "cannot stage %s: %v", path, err)
	}

	return true
}

// Odin's JSON omitempty skips "" but not false, so the lockfile is written
// through this shape: an unpinned record keeps the bytes it had before pins.
Package_Record_Json :: struct {
	name:   string,
	source: string,
	tag:    string,
	commit: string,
	hash:   string,
	pinned: Maybe(bool) `json:"pinned,omitempty"`,
}

Packages_File_Json :: struct {
	format:   int,
	packages: [dynamic]Package_Record_Json,
}

// Writes a project lockfile; `pinned` appears only on pinned records.
stage_packages :: proc(transaction: ^Transaction, path: string, file: Packages_File) -> bool {
	out := Packages_File_Json{format = file.format}
	for record in file.packages {
		row := Package_Record_Json{name = record.name, source = record.source, tag = record.tag, commit = record.commit, hash = record.hash}
		if record.pinned {
			row.pinned = true
		}

		append(&out.packages, row)
	}
	return stage_json(transaction, path, out)
}

load_packages :: proc(env: ^Env) -> (file: Packages_File, ok: bool) {
	load_json(env, path_join(env.project, PACKAGES_PATH), &file) or_return
	file.format = FORMAT
	return file, true
}

load_manifest :: proc(env: ^Env, shared: string) -> (file: Manifest_File, ok: bool) {
	load_json(env, path_join(shared, MANIFEST_PATH), &file) or_return
	file.format = FORMAT
	return file, true
}

stage_manifest :: proc(transaction: ^Transaction, shared: string, file: ^Manifest_File) -> bool {
	slice.sort_by(file.packages[:], proc(a, b: Manifest_Record) -> bool {
		return a.name < b.name
	})

	return stage_json(transaction, path_join(shared, MANIFEST_PATH), file^)
}

load_config :: proc(env: ^Env) -> (config: Config, ok: bool) {
	if env.home == "" {
		return config, fail(env, "cannot locate the home directory for KRS settings")
	}

	path := path_join(env.home, CONFIG_PATH)
	found := load_json(env, path, &config) or_return
	if !found {
		info(env, "no settings at %s: no source directories and no libs", path)
	}

	for &directory in config.source_directories {
		directory = path_trim_trailing_slash(path_expand_home(directory, env.home))
		if directory == "" {
			return config, fail(env, "%s contains an empty source directory", path)
		}

		if !strings.has_prefix(directory, "/") {
			if env.project == "" {
				return config, fail(env, "cannot resolve the source directory %s without a working directory", directory)
			}
			directory = path_join(env.project, directory)
		}
	}

	return config, true
}

packages_find :: proc(file: ^Packages_File, name: string) -> ^Package_Record {
	for &record in file.packages {
		if record.name == name {
			return &record
		}
	}

	return nil
}

manifest_find :: proc(file: ^Manifest_File, name: string) -> ^Manifest_Record {
	for &record in file.packages {
		if record.name == name {
			return &record
		}
	}

	return nil
}

manifest_remove :: proc(file: ^Manifest_File, name: string) {
	for record, index in file.packages {
		if record.name == name {
			ordered_remove(&file.packages, index)
			return
		}
	}
}

manifest_put :: proc(file: ^Manifest_File, record: Manifest_Record) {
	existing := manifest_find(file, record.name)
	if existing != nil {
		existing^ = record
		return
	}

	append(&file.packages, record)
}

// True when a path exists, including a symbolic link that points nowhere.
path_present :: proc(path: string) -> bool {
	_, err := os.lstat(path, context.allocator)
	return err == nil
}

is_symbolic_link :: proc(path: string) -> bool {
	info, err := os.lstat(path, context.allocator)
	return err == nil && info.type == .Symlink
}

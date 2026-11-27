package main

import "core:crypto/hash"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"

// What a build of KRS is made from, besides core: (covered by the compiler's
// version). Every file counts, so #load-ed files do too.
BUILD_SOURCES :: [?]string{"cmd/krs", "src"}
BUILD_SHARED :: [?]string{"kakunou"}
BUILD_FLAGS :: "-vet -o:speed"
FINGERPRINT_FILES_MAX :: 10_000
CHANGES_NAMED_MAX :: 3

// One entry per input: a file's path and its SHA-256, or a setting
// ("odin", "version", "flags") and its value.
Fingerprint :: map[string]string

// `krs-dev build`: builds $KRS_CHECK_DIR/krs, or nothing when the inputs are
// those of the binary already there.
build_command :: proc() -> int {
	started := time.tick_now()
	display := display_make()
	build, code := build_begin(display)
	if code != EXIT_OK {
		return code
	}
	defer os.remove(build.log_path)

	if code = build_krs(display, &build); code != EXIT_OK {
		return code
	}

	binary := fmt.tprintf("%s/krs", build.out)
	icon(display, 32, "✓", false)
	if build.skipped {
		fmt.printfln("krs: %s is up to date (%s)", binary, build.version)
	} else {
		fmt.printfln("krs: built %s (%s) in %s", binary, build.version, duration_text(time.tick_since(started)))
	}
	return EXIT_OK
}

// build_begin finds the output directory and catches SIGINT and SIGTERM, which
// the steps check between commands.
build_begin :: proc(display: Display) -> (build: Build, code: int) {
	build.out = os.get_env("KRS_CHECK_DIR", context.allocator)
	if build.out == "" {
		tmp := os.get_env("TMPDIR", context.allocator)
		build.out = fmt.tprintf("%s/krs-check", strings.trim_right(tmp, "/") if tmp != "" else "/tmp")
	}

	if !ensure_dir(build.out) {
		return build, install_fail(display, fmt.tprintf("cannot create %s", build.out))
	}

	handler: posix.sigaction_t
	handler.sa_handler = on_signal
	posix.sigemptyset(&handler.sa_mask)
	posix.sigaction(.SIGINT, &handler, nil)
	posix.sigaction(.SIGTERM, &handler, nil)

	build.log_path = fmt.tprintf("%s/krs-build.log", build.out)
	return build, EXIT_OK
}

// build_krs prepares, then compiles unless nothing changed since the last
// successful build. The fingerprint is written only after a build succeeds.
build_krs :: proc(display: Display, build: ^Build) -> int {
	if code := prepare(display, build); code != EXIT_OK {
		return code
	}

	binary := fmt.tprintf("%s/krs", build.out)
	record := fmt.tprintf("%s/krs.inputs", build.out)
	step := step_begin(display, "Looking for changes")
	current, hashed := fingerprint_make(build^)
	if !hashed {
		step_failed(display, step, "")
		return install_fail(display, "cannot read the sources of KRS")
	}

	previous, found := fingerprint_read(record)
	changes := fingerprint_changes(previous, current)
	if found && len(changes) == 0 && os.is_file(binary) {
		build.skipped = true
		step_done(display, step, "nothing changed since the last build; not compiling")
		return EXIT_OK
	}
	step_done(display, step, changes_text(changes, found))

	os.remove(record)
	if code := compile(display, build^); code != EXIT_OK {
		return code
	}

	if !fingerprint_write(record, current) {
		// The binary is fine; the next build just cannot be skipped.
		fmt.eprintfln("krs: warning: cannot write %s", record)
	}
	return EXIT_OK
}

fingerprint_make :: proc(build: Build) -> (fingerprint: Fingerprint, ok: bool) {
	assert(build.version != "")

	fingerprint = make(Fingerprint)
	fingerprint["odin"] = build.odin_version
	fingerprint["version"] = build.version
	fingerprint["flags"] = strings.join({BUILD_FLAGS, build.link_flags}, " ")
	count := 0
	for directory in BUILD_SOURCES {
		fingerprint_directory(&fingerprint, directory, directory, &count) or_return
	}

	for name in BUILD_SHARED {
		path := fmt.tprintf("%s/shared/%s", build.odin_root, name)
		fingerprint_directory(&fingerprint, path, fmt.tprintf("shared:%s", name), &count) or_return
	}
	return fingerprint, true
}

// Adds every file under `path`, named `label/<relative path>`.
fingerprint_directory :: proc(fingerprint: ^Fingerprint, path, label: string, count: ^int) -> bool {
	entries, err := os.read_all_directory_by_path(path, context.temp_allocator)
	if err != nil {
		return false
	}

	for entry in entries {
		name := fmt.tprintf("%s/%s", label, entry.name)
		if entry.type == .Directory {
			fingerprint_directory(fingerprint, entry.fullpath, name, count) or_return
			continue
		}

		count^ += 1
		if count^ > FINGERPRINT_FILES_MAX {
			return false
		}

		data, read_err := os.read_entire_file(entry.fullpath, context.temp_allocator)
		if read_err != nil {
			return false
		}
		fingerprint[name] = digest_text(hash.hash_bytes(.SHA256, data, context.temp_allocator))
	}
	return true
}

digest_text :: proc(digest: []byte) -> string {
	builder := strings.builder_make(context.temp_allocator)
	for b in digest {
		fmt.sbprintf(&builder, "%02x", b)
	}
	return strings.to_string(builder)
}

// One "key<TAB>value" line per entry, sorted.
fingerprint_text :: proc(fingerprint: Fingerprint) -> string {
	keys, _ := slice.map_keys(fingerprint, context.temp_allocator)
	slice.sort(keys)
	builder := strings.builder_make(context.temp_allocator)
	for key in keys {
		fmt.sbprintf(&builder, "%s\t%s\n", key, fingerprint[key])
	}
	return strings.to_string(builder)
}

fingerprint_parse :: proc(text: string) -> Fingerprint {
	fingerprint := make(Fingerprint)
	for line in strings.split_lines(text, context.temp_allocator) {
		tab := strings.index_byte(line, '\t')
		if tab > 0 {
			fingerprint[line[:tab]] = line[tab + 1:]
		}
	}
	return fingerprint
}

fingerprint_read :: proc(path: string) -> (fingerprint: Fingerprint, found: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return make(Fingerprint), false
	}
	return fingerprint_parse(string(data)), true
}

fingerprint_write :: proc(path: string, fingerprint: Fingerprint) -> bool {
	return os.write_entire_file(path, fingerprint_text(fingerprint)) == nil
}

// The keys added, removed or changed between two fingerprints, sorted.
fingerprint_changes :: proc(previous, current: Fingerprint) -> []string {
	changes: [dynamic]string
	for key, value in current {
		if old, present := previous[key]; !present || old != value {
			append(&changes, key)
		}
	}

	for key in previous {
		if _, present := current[key]; !present {
			append(&changes, key)
		}
	}
	slice.sort(changes[:])
	return changes[:]
}

// "src/fetch.odin changed", "src/a.odin, src/b.odin and 3 more changed".
changes_text :: proc(changes: []string, found: bool) -> string {
	if !found {
		return "no previous build"
	}

	if len(changes) == 0 {
		return "the previous binary is missing"
	}

	names: [dynamic]string
	for change in changes[:min(len(changes), CHANGES_NAMED_MAX)] {
		append(&names, change_name(change))
	}

	listed := strings.join(names[:], ", ", context.temp_allocator)
	if len(changes) > CHANGES_NAMED_MAX {
		listed = fmt.tprintf("%s and %d more", listed, len(changes) - CHANGES_NAMED_MAX)
	}
	return fmt.tprintf("%s changed", listed)
}

change_name :: proc(key: string) -> string {
	switch key {
	case "odin":
		return "the Odin compiler"
	case "version":
		return "the version"
	case "flags":
		return "the build flags"
	}
	return key
}

package krs

import "core:crypto/sha2"
import "core:encoding/endian"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// A verified Git release or a directory of working files.
Source :: struct {
	repository: string,
	release:    Git_Release,
}

Selected_File :: struct {
	repository_path: string,
	install_path:    string,
}

// The files of a package that are installed, and what they import.
Selection :: struct {
	files:    [dynamic]Selected_File,
	has_odin_files: bool,
	imports:  [dynamic]string,
	warnings: [dynamic]string,
	prefix:   string, // "src/" when the repository has one, otherwise ""
}

File_Walk :: enum {
	Source,
	Project,
	Installed,
}

// Installed files must be regular files and directories; installed walks skip
// OS metadata files (is_os_metadata). Source walks ignore Git metadata, and
// project scans also skip hidden directories.
list_files :: proc(base, relative: string, walk: File_Walk, files: ^[dynamic]string) -> bool {
	pending: [dynamic]string
	defer delete(pending)
	append(&pending, relative)

	for len(pending) > 0 {
		directory := pop(&pending)
		entries, err := os.read_all_directory_by_path(path_join(base, directory), context.allocator)
		if err != nil {
			return false
		}

		for entry in entries {
			child := path_join(directory, entry.name)
			#partial switch entry.type {
			case .Regular:
				if walk == .Installed && is_os_metadata(entry.name) {
					continue
				}

				append(files, child)
			case .Directory:
				if walk != .Installed && (entry.name == ".git" || (walk == .Project && strings.has_prefix(entry.name, "."))) {
					continue
				}
				append(&pending, child)
			case:
				if walk == .Installed {
					return false
				}
			}
		}
	}

	return true
}

source_list :: proc(source: Source) -> (files: [dynamic]string, ok: bool) {
	if source.release.tree != nil {
		return git_list_files(source.release)
	}

	list_files(source.repository, "", .Source, &files) or_return
	return files, true
}

source_read :: proc(source: Source, path: string) -> (data: []byte, ok: bool) {
	if source.release.tree != nil {
		contents, status := git_read_file(source.release, path)
		return contents, status == .Read
	}

	contents, err := os.read_entire_file(path_join(source.repository, path), context.allocator)
	return contents, err == nil
}

is_excluded_directory :: proc(name: string) -> bool {
	switch name {
	case "tests", "examples", "testdata":
		return true
	}

	return false
}

// True when any directory on the way to the file is a test, example or test
// data directory.
is_in_excluded_directory :: proc(path: string) -> bool {
	segments := strings.split(path, "/")
	if len(segments) < 2 {
		return false
	}

	for segment in segments[:len(segments) - 1] {
		if is_excluded_directory(segment) {
			return true
		}
	}

	return false
}

is_licence_file :: proc(name: string) -> bool {
	lower := strings.to_lower(name)
	for prefix in ([]string{"license", "licence", "notice", "copying"}) {
		if strings.has_prefix(lower, prefix) {
			return true
		}
	}

	return false
}

// Files an operating system's file manager creates on its own. They are never
// installed and never count as a change to an installed package.
is_os_metadata :: proc(name: string) -> bool {
	switch name {
	case ".DS_Store", "Thumbs.db", "ehthumbs.db", "desktop.ini":
		return true
	}

	return strings.has_prefix(name, "._") // AppleDouble files on non-Apple volumes
}

select_reference :: proc(selection: ^Selection, known, chosen: ^map[string]bool, file, reference: string) {
	target, ok := path_clean_relative(path_join(path_directory(file), reference))
	if !ok || strings.has_prefix(reference, "/") || !strings.has_prefix(target, selection.prefix) {
		append(&selection.warnings, fmt.aprintf("%s names \"%s\", which is outside the package", file, reference))
		return
	}

	if !known[target] {
		append(&selection.warnings, fmt.aprintf("%s names \"%s\", which is not in the release", file, reference))
		return
	}

	chosen[target] = true
}

select_directory :: proc(selection: ^Selection, files: []string, chosen: ^map[string]bool, file, reference: string) {
	target, ok := path_clean_relative(path_join(path_directory(file), reference))
	if !ok || strings.has_prefix(reference, "/") ||
	   !strings.has_prefix(strings.concatenate({target, "/"}), selection.prefix) {
		append(&selection.warnings, fmt.aprintf("%s names \"%s\", which is outside the package", file, reference))
		return
	}

	found := false
	for candidate in files {
		if path_directory(candidate) == target {
			chosen[candidate] = true
			found = true
		}
	}

	if !found {
		append(&selection.warnings, fmt.aprintf("%s names directory \"%s\", which has no files in the release", file, reference))
	}
}

// Decides which files of a release are installed: the Odin files, the files
// they name, and the licence and notice files.
select_files :: proc(source: Source, name: string) -> (selection: Selection, ok: bool) {
	listed := source_list(source) or_return
	files: [dynamic]string
	for file in listed {
		if !is_os_metadata(path_base(file)) {
			append(&files, file)
		}
	}

	known: map[string]bool
	for file in files {
		known[file] = true
		if strings.has_prefix(file, "src/") {
			selection.prefix = "src/"
		}
	}

	chosen: map[string]bool
	for file in files {
		if !strings.has_prefix(file, selection.prefix) || path_extension(file) != ".odin" {
			continue
		}

		if is_in_excluded_directory(file[len(selection.prefix):]) {
			continue
		}

		selection.has_odin_files = true
		data := source_read(source, file) or_return
		scan := scan_source(string(data))
		chosen[file] = true

		for imported in scan.shared_imports {
			if imported != name {
				append_unique(&selection.imports, imported)
			}
		}
		for reference in scan.file_refs {
			select_reference(&selection, &known, &chosen, file, reference)
		}
		for reference in scan.directory_refs {
			select_directory(&selection, files[:], &chosen, file, reference)
		}
		for directive in scan.unresolved {
			append(&selection.warnings, fmt.aprintf("%s has a #%s whose path is not a string literal", file, directive))
		}
	}

	installed: map[string]string
	root := path_trim_trailing_slash(selection.prefix) if selection.prefix != "" else ""
	for file in files {
		directory := path_directory(file)
		if directory == "" && is_licence_file(file) {
			if !(file in installed) {
				installed[file] = file
			}
		} else if directory == root && is_licence_file(path_base(file)) {
			installed[path_base(file)] = file
		}
	}
	for file in chosen {
		installed[file[len(selection.prefix):]] = file
	}

	for install_path, repository_path in installed {
		append(&selection.files, Selected_File{repository_path = repository_path, install_path = install_path})
	}
	slice.sort_by(selection.files[:], proc(a, b: Selected_File) -> bool {
		return a.install_path < b.install_path
	})
	slice.sort(selection.imports[:])

	return selection, true
}

Hasher :: struct {
	ctx: sha2.Context_256,
}

hasher_init :: proc(hasher: ^Hasher) {
	sha2.init_256(&hasher.ctx)
}

// Each file contributes its path, a zero byte, its length and its bytes, so no
// two different sets of files produce the same stream.
hasher_add :: proc(hasher: ^Hasher, path: string, data: []byte) {
	length: [8]byte
	endian.put_u64(length[:], .Little, u64(len(data)))

	sha2.update(&hasher.ctx, transmute([]byte)path)
	sha2.update(&hasher.ctx, []byte{0})
	sha2.update(&hasher.ctx, length[:])
	sha2.update(&hasher.ctx, data)
}

hasher_finish :: proc(hasher: ^Hasher) -> string {
	digest: [sha2.DIGEST_SIZE_256]byte
	sha2.final(&hasher.ctx, digest[:])

	return string(hex.encode(digest[:]))
}

// The content hash of an installed package directory.
hash_directory :: proc(directory: string) -> (hash: string, ok: bool) {
	info, stat_err := os.lstat(directory, context.temp_allocator)
	if stat_err != nil || info.type != .Directory {
		return "", false
	}

	files: [dynamic]string
	list_files(directory, "", .Installed, &files) or_return
	slice.sort(files[:])

	hasher: Hasher
	hasher_init(&hasher)
	for file in files {
		data, err := os.read_entire_file(path_join(directory, file), context.allocator)
		if err != nil {
			return "", false
		}
		hasher_add(&hasher, file, data)
	}

	return hasher_finish(&hasher), true
}

// The `shared:` names imported by the Odin files under `directory`.
scan_directory_imports :: proc(directory, own_name: string) -> (imports: [dynamic]string, ok: bool) {
	files: [dynamic]string
	list_files(directory, "", .Project, &files) or_return

	for file in files {
		if path_extension(file) != ".odin" {
			continue
		}

		data, err := os.read_entire_file(path_join(directory, file), context.allocator)
		if err != nil {
			return imports, false
		}

		scan := scan_source(string(data))
		for imported in scan.shared_imports {
			if imported != own_name {
				append_unique(&imports, imported)
			}
		}
	}
	slice.sort(imports[:])

	return imports, true
}

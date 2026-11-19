package krs

import "core:strings"

// Paths inside krs use `/` only; Windows is not supported yet.

path_join :: proc(a, b: string) -> string {
	if a == "" {
		return b
	}

	if b == "" {
		return a
	}

	if strings.has_suffix(a, "/") {
		return strings.concatenate({a, b})
	}

	return strings.concatenate({a, "/", b})
}

path_directory :: proc(path: string) -> string {
	index := strings.last_index_byte(path, '/')
	if index < 0 {
		return ""
	}

	return path[:index]
}

path_base :: proc(path: string) -> string {
	index := strings.last_index_byte(path, '/')
	if index < 0 {
		return path
	}

	return path[index + 1:]
}

path_extension :: proc(path: string) -> string {
	base := path_base(path)
	index := strings.last_index_byte(base, '.')
	if index <= 0 {
		return ""
	}

	return base[index:]
}

// Resolves `.` and `..` in a relative path. Fails when the path is absolute or
// climbs above its starting directory.
path_clean_relative :: proc(path: string) -> (cleaned: string, ok: bool) {
	if strings.has_prefix(path, "/") {
		return "", false
	}

	segments: [dynamic]string
	for segment in strings.split(path, "/") {
		switch segment {
		case "", ".":
			continue
		case "..":
			if len(segments) == 0 {
				return "", false
			}
			pop(&segments)
		case:
			append(&segments, segment)
		}
	}

	return strings.join(segments[:], "/"), true
}

path_expand_home :: proc(path, home: string) -> string {
	if path == "~" {
		return home
	}

	if strings.has_prefix(path, "~/") {
		return path_join(home, path[2:])
	}

	return path
}

path_trim_trailing_slash :: proc(path: string) -> string {
	trimmed := path
	for len(trimmed) > 1 && strings.has_suffix(trimmed, "/") {
		trimmed = trimmed[:len(trimmed) - 1]
	}

	return trimmed
}

is_package_name_byte :: proc(c: u8) -> bool {
	switch c {
	case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-', '.':
		return true
	}

	return false
}

// A package name becomes a directory name, so it must not be able to leave
// `shared/`.
is_package_name :: proc(name: string) -> bool {
	if name == "" || name[0] == '.' || name[0] == '-' {
		return false
	}

	for index in 0 ..< len(name) {
		if !is_package_name_byte(name[index]) {
			return false
		}
	}

	return true
}

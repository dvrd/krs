package krs

import "core:strings"

Version :: struct {
	major: int,
	minor: int,
	patch: int,
}

Version_Bump :: enum {
	Major,
	Minor,
	Patch,
}

VERSION_COMPONENT_MAX :: 999_999_999

version_bump :: proc(version: Version, part: Version_Bump) -> (next: Version, ok: bool) {
	switch part {
	case .Major:
		if version.major < VERSION_COMPONENT_MAX {
			return {version.major + 1, 0, 0}, true
		}
	case .Minor:
		if version.minor < VERSION_COMPONENT_MAX {
			return {version.major, version.minor + 1, 0}, true
		}
	case .Patch:
		if version.patch < VERSION_COMPONENT_MAX {
			return {version.major, version.minor, version.patch + 1}, true
		}
	}
	return {}, false
}

Version_Order :: enum {
	Lower,
	Equal,
	Higher,
}

Version_Compatibility :: enum {
	Compatible,
	Breaking,
}

version_compatibility_label :: proc(compatibility: Version_Compatibility) -> string {
	switch compatibility {
	case .Compatible:
		return "compatible"
	case .Breaking:
		return "breaking"
	}
	unreachable()
}

is_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

parse_version_number :: proc(text: string) -> (value: int, ok: bool) {
	if text == "" || len(text) > 9 {
		return 0, false
	}

	if len(text) > 1 && text[0] == '0' {
		return 0, false
	}

	for index in 0 ..< len(text) {
		if !is_digit(text[index]) {
			return 0, false
		}
		value = value * 10 + int(text[index] - '0')
	}

	return value, true
}

// Accepts exactly `vMAJOR.MINOR.PATCH`.
parse_tag :: proc(tag: string) -> (version: Version, ok: bool) {
	if !strings.has_prefix(tag, "v") {
		return {}, false
	}

	parts := strings.split(tag[1:], ".")
	if len(parts) != 3 {
		return {}, false
	}

	version.major = parse_version_number(parts[0]) or_return
	version.minor = parse_version_number(parts[1]) or_return
	version.patch = parse_version_number(parts[2]) or_return

	return version, true
}

version_compare :: proc(a, b: Version) -> Version_Order {
	if a.major != b.major {
		return .Lower if a.major < b.major else .Higher
	}

	if a.minor != b.minor {
		return .Lower if a.minor < b.minor else .Higher
	}

	if a.patch != b.patch {
		return .Lower if a.patch < b.patch else .Higher
	}

	return .Equal
}

// Same major version; at `0.x` also the same minor.
version_compatibility :: proc(a, b: Version) -> Version_Compatibility {
	if a.major != b.major || (a.major == 0 && a.minor != b.minor) {
		return .Breaking
	}

	return .Compatible
}

highest_tag :: proc(tags: []string) -> (highest: string, ok: bool) {
	best: Version
	for tag in tags {
		version := parse_tag(tag) or_continue
		if !ok || version_compare(version, best) == .Higher {
			best = version
			highest = tag
			ok = true
		}
	}

	return highest, ok
}

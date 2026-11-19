package main

import "core:strings"

import krs "../../src"

Release_Impact :: enum {
	None,
	Fix,
	Feature,
	Breaking,
}

// Git log -z separates complete commit messages with NUL bytes.
release_impact :: proc(messages: string) -> Release_Impact {
	remaining := messages
	highest := Release_Impact.None
	for message in strings.split_iterator(&remaining, "\x00") {
		highest = max(highest, commit_impact(message))
		if highest == .Breaking {
			break
		}
	}
	return highest
}

release_bump :: proc(base: krs.Version, impact: Release_Impact) -> krs.Version_Bump {
	assert(impact != .None)
	switch impact {
	case .Breaking:
		return .Minor if base.major == 0 else .Major
	case .Feature:
		return .Patch if base.major == 0 else .Minor
	case .Fix:
		return .Patch
	case .None:
		unreachable()
	}
	unreachable()
}

commit_impact :: proc(message: string) -> Release_Impact {
	body := message
	subject, found := strings.split_lines_iterator(&body)
	if !found {
		return .None
	}

	separator := strings.index(subject, ": ")
	if separator < 1 || strings.trim_space(subject[separator + 2:]) == "" {
		return .None
	}

	prefix := subject[:separator]
	breaking := strings.has_suffix(prefix, "!")
	name := strings.trim_suffix(prefix, "!")
	if scope_start := strings.index(name, "("); scope_start >= 0 {
		if !strings.has_suffix(name, ")") || scope_start + 2 >= len(name) {
			return .None
		}

		scope := name[scope_start + 1:len(name) - 1]
		if strings.contains(scope, "(") || strings.contains(scope, ")") {
			return .None
		}
		name = name[:scope_start]
	}

	if !commit_token(name) {
		return .None
	}

	if breaking || breaking_footer(body) {
		return .Breaking
	}

	if strings.equal_fold(name, "feat") {
		return .Feature
	}

	if strings.equal_fold(name, "fix") {
		return .Fix
	}
	return .None
}

breaking_footer :: proc(body: string) -> bool {
	remaining := body
	first := strings.split_lines_iterator(&remaining) or_return
	if strings.trim_space(first) != "" {
		return false
	}

	paragraph_start, footers := true, false
	for line in strings.split_lines_iterator(&remaining) {
		if strings.trim_space(line) == "" {
			paragraph_start = true
			continue
		}

		trailer, breaking := footer_kind(line)
		if breaking && (paragraph_start || footers) {
			return true
		}

		if paragraph_start {
			paragraph_start, footers = false, trailer
		}
	}
	return false
}

footer_kind :: proc(line: string) -> (trailer, breaking: bool) {
	for separator in ([]string{": ", " #"}) {
		index := strings.index(line, separator)
		if index < 1 || strings.trim_space(line[index + len(separator):]) == "" {
			continue
		}

		key := line[:index]
		if separator == ": " && (key == "BREAKING CHANGE" || key == "BREAKING-CHANGE") {
			return true, true
		}

		if commit_token(key) {
			return true, false
		}
	}
	return false, false
}

commit_token :: proc(text: string) -> bool {
	for byte in transmute([]u8)text {
		letter := (byte >= 'A' && byte <= 'Z') || (byte >= 'a' && byte <= 'z')
		if !letter && !krs.is_digit(byte) && byte != '-' {
			return false
		}
	}
	return text != ""
}

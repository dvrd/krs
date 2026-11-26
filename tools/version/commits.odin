package main

import "core:fmt"
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

	kind, _, breaking, _, valid := commit_header(subject)
	if !valid {
		return .None
	}

	if breaking {
		return .Breaking
	}

	if _, footer := breaking_footer(body); footer {
		return .Breaking
	}

	if strings.equal_fold(kind, "feat") {
		return .Feature
	}

	if strings.equal_fold(kind, "fix") {
		return .Fix
	}
	return .None
}

// Parses a Conventional Commits subject: `type(scope)!: description`.
commit_header :: proc(
	subject: string,
) -> (
	kind, scope: string,
	breaking: bool,
	description: string,
	ok: bool,
) {
	separator := strings.index(subject, ": ")
	if separator < 1 {
		return "", "", false, "", false
	}

	description = strings.trim_space(subject[separator + 2:])
	if description == "" {
		return "", "", false, "", false
	}

	prefix := subject[:separator]
	breaking = strings.has_suffix(prefix, "!")
	kind = strings.trim_suffix(prefix, "!")
	if scope_start := strings.index(kind, "("); scope_start >= 0 {
		if !strings.has_suffix(kind, ")") || scope_start + 2 >= len(kind) {
			return "", "", false, "", false
		}

		scope = kind[scope_start + 1:len(kind) - 1]
		if strings.contains(scope, "(") || strings.contains(scope, ")") {
			return "", "", false, "", false
		}
		kind = kind[:scope_start]
	}

	if !commit_token(kind) {
		return "", "", false, "", false
	}
	return kind, scope, breaking, description, true
}

// `body` is the message after its subject line. Returns the value of the first
// breaking-change footer, through its continuation lines, as a slice of `body`.
breaking_footer :: proc(body: string) -> (value: string, found: bool) {
	remaining := body
	first := strings.split_lines_iterator(&remaining) or_return
	if strings.trim_space(first) != "" {
		return "", false
	}

	paragraph_start, footers := true, false
	for {
		line_start := len(body) - len(remaining)
		line := strings.split_lines_iterator(&remaining) or_break
		if strings.trim_space(line) == "" {
			paragraph_start = true
			continue
		}

		trailer, breaking := footer_kind(line)
		if breaking && (paragraph_start || footers) {
			value_start := line_start + strings.index(line, ": ") + len(": ")
			value_end := line_start + len(line)
			for {
				next_start := len(body) - len(remaining)
				next := strings.split_lines_iterator(&remaining) or_break
				if strings.trim_space(next) == "" {
					break
				}

				if next_trailer, _ := footer_kind(next); next_trailer {
					break
				}
				value_end = next_start + len(next)
			}
			assert(value_start <= value_end)
			return body[value_start:value_end], true
		}

		if paragraph_start {
			paragraph_start, footers = false, trailer
		}
	}
	return "", false
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

Notes_Section :: enum {
	Breaking,
	Features,
	Fixes,
	Performance,
	Other,
}

NOTES_HEADINGS :: [Notes_Section]string {
	.Breaking    = "Breaking changes",
	.Features    = "Features",
	.Fixes       = "Fixes",
	.Performance = "Performance",
	.Other       = "Other changes",
}

// Writes Markdown release notes from `git log -z --no-merges --format='%h%n%B'`,
// newest commit first within each section.
release_notes :: proc(log: string, base, next, repository: string) -> string {
	sections: [Notes_Section]strings.Builder
	for &section in sections {
		strings.builder_init(&section)
	}
	defer for &section in sections {
		strings.builder_destroy(&section)
	}

	remaining := log
	for entry in strings.split_iterator(&remaining, "\x00") {
		message := entry
		hash := strings.trim_space(strings.split_lines_iterator(&message) or_continue)
		subject := strings.trim_space(strings.split_lines_iterator(&message) or_continue)
		if subject == "" {
			continue
		}

		kind, scope, breaking, description, valid := commit_header(subject)
		if !valid {
			fmt.sbprintf(&sections[.Other], "- %s (%s)\n", subject, hash)
			continue
		}

		if strings.equal_fold(kind, "chore") && strings.equal_fold(scope, "release") {
			continue
		}

		footer, footer_found := breaking_footer(message)
		section := notes_section(kind, breaking || footer_found)
		output := &sections[section]
		strings.write_string(output, "- ")
		if scope != "" {
			fmt.sbprintf(output, "**%s:** ", scope)
		}
		strings.write_string(output, description)
		if section == .Other {
			fmt.sbprintf(output, " (%s)", kind)
		}
		fmt.sbprintf(output, " (%s)\n", hash)
		for line in strings.split_lines_iterator(&footer) {
			fmt.sbprintf(output, "  %s\n", strings.trim_space(line))
		}
	}

	notes := strings.builder_make()
	headings := NOTES_HEADINGS
	for section, kind in sections {
		if strings.builder_len(section) > 0 {
			fmt.sbprintf(&notes, "## %s\n\n%s\n", headings[kind], strings.to_string(section))
		}
	}
	strings.write_string(&notes, "The macOS binary requires libgit2: `brew install libgit2`.\n\n")
	fmt.sbprintf(&notes, "**Full changelog**: https://github.com/%s/compare/%s...%s\n", repository, base, next)
	return strings.to_string(notes)
}

notes_section :: proc(kind: string, breaking: bool) -> Notes_Section {
	if breaking {
		return .Breaking
	}

	if strings.equal_fold(kind, "feat") {
		return .Features
	}

	if strings.equal_fold(kind, "fix") {
		return .Fixes
	}

	if strings.equal_fold(kind, "perf") {
		return .Performance
	}
	return .Other
}

package krs

import "core:strconv"
import "core:strings"

// What one Odin file says about the files and packages it depends on. The
// scanner reads tokens only, so it sees every `when` branch alike.
Scan_Result :: struct {
	shared_imports: [dynamic]string, // first path segment of each `shared:` import
	file_refs:      [dynamic]string, // `#load`, `#load_hash`, relative `foreign import`
	directory_refs: [dynamic]string, // `#load_directory`
	unresolved:     [dynamic]string, // directives whose path is not a string literal
}

Token_Kind :: enum {
	End,
	Identifier,
	String,
	Directive,
	Punctuation,
}

Token :: struct {
	kind: Token_Kind,
	text: string,
}

Scanner :: struct {
	source: string,
	offset: int,
}

is_identifier_start :: proc(c: u8) -> bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
}

is_identifier_byte :: proc(c: u8) -> bool {
	return is_identifier_start(c) || is_digit(c)
}

is_space :: proc(c: u8) -> bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

scanner_skip_line_comment :: proc(scanner: ^Scanner) {
	for scanner.offset < len(scanner.source) && scanner.source[scanner.offset] != '\n' {
		scanner.offset += 1
	}
}

// Block comments nest in Odin.
scanner_skip_block_comment :: proc(scanner: ^Scanner) {
	depth := 1
	scanner.offset += 2

	for scanner.offset < len(scanner.source) && depth > 0 {
		rest := scanner.source[scanner.offset:]
		if strings.has_prefix(rest, "/*") {
			depth += 1
			scanner.offset += 2
		} else if strings.has_prefix(rest, "*/") {
			depth -= 1
			scanner.offset += 2
		} else {
			scanner.offset += 1
		}
	}
}

scanner_skip_trivia :: proc(scanner: ^Scanner) {
	for scanner.offset < len(scanner.source) {
		rest := scanner.source[scanner.offset:]
		if is_space(rest[0]) {
			scanner.offset += 1
		} else if strings.has_prefix(rest, "//") {
			scanner_skip_line_comment(scanner)
		} else if strings.has_prefix(rest, "/*") {
			scanner_skip_block_comment(scanner)
		} else {
			return
		}
	}
}

// Advance past a quoted token. Return the full literal for the decoder.
scanner_quoted :: proc(scanner: ^Scanner, quote: u8) -> (literal: string, closed: bool) {
	start := scanner.offset
	scanner.offset += 1
	raw := quote == '`'

	for scanner.offset < len(scanner.source) {
		c := scanner.source[scanner.offset]
		scanner.offset += 1
		if c == quote {
			return scanner.source[start:scanner.offset], true
		}

		if !raw && c == '\n' {
			break
		}

		if !raw && c == '\\' && scanner.offset < len(scanner.source) {
			scanner.offset += 1
		}
	}

	return "", false
}

scanner_identifier :: proc(scanner: ^Scanner) -> string {
	start := scanner.offset
	for scanner.offset < len(scanner.source) && is_identifier_byte(scanner.source[scanner.offset]) {
		scanner.offset += 1
	}

	return scanner.source[start:scanner.offset]
}

scanner_next :: proc(scanner: ^Scanner) -> Token {
	scanner_skip_trivia(scanner)
	if scanner.offset >= len(scanner.source) {
		return {kind = .End}
	}

	c := scanner.source[scanner.offset]
	switch {
	case c == '"' || c == '`':
		literal, closed := scanner_quoted(scanner, c)
		if closed {
			value, _, valid := strconv.unquote_string(literal)
			if valid {
				return {kind = .String, text = value}
			}
		}
		return {kind = .Punctuation}
	case c == '\'':
		scanner_quoted(scanner, c)
		return {kind = .Punctuation, text = "'"}
	case c == '#':
		scanner.offset += 1
		return {kind = .Directive, text = scanner_identifier(scanner)}
	case is_identifier_start(c):
		return {kind = .Identifier, text = scanner_identifier(scanner)}
	}

	scanner.offset += 1
	return {kind = .Punctuation, text = scanner.source[scanner.offset - 1:scanner.offset]}
}

append_unique :: proc(list: ^[dynamic]string, value: string) {
	for existing in list {
		if existing == value {
			return
		}
	}

	append(list, value)
}

scan_add_import :: proc(result: ^Scan_Result, path: string) {
	if !strings.has_prefix(path, "shared:") {
		return
	}

	rest := path[len("shared:"):]
	index := strings.index_byte(rest, '/')
	if index >= 0 {
		rest = rest[:index]
	}

	if rest != "" {
		append_unique(&result.shared_imports, rest)
	}
}

// A foreign import path with a collection or `system:` prefix is not a file of
// the package.
scan_add_foreign :: proc(result: ^Scan_Result, path: string) {
	if path == "" || strings.contains_rune(path, ':') || strings.has_prefix(path, "/") {
		return
	}

	append_unique(&result.file_refs, path)
}

scan_import :: proc(scanner: ^Scanner, result: ^Scan_Result, is_foreign: bool) {
	token := scanner_next(scanner)
	if token.kind == .Identifier {
		token = scanner_next(scanner)
	}

	if token.kind == .String {
		if is_foreign {
			scan_add_foreign(result, token.text)
		} else {
			scan_add_import(result, token.text)
		}
		return
	}

	if !is_foreign || token.kind != .Punctuation || token.text != "{" {
		return
	}

	for {
		token = scanner_next(scanner)
		if token.kind == .End || (token.kind == .Punctuation && token.text == "}") {
			return
		}

		if token.kind == .String {
			scan_add_foreign(result, token.text)
		}
	}
}

scan_load :: proc(scanner: ^Scanner, result: ^Scan_Result, directive: string) {
	token := scanner_next(scanner)
	if token.kind != .Punctuation || token.text != "(" {
		return
	}

	token = scanner_next(scanner)
	lookahead := scanner^
	next := scanner_next(&lookahead)
	if token.kind != .String || next.kind != .Punctuation || (next.text != "," && next.text != ")") {
		append(&result.unresolved, directive)
		return
	}

	if directive == "load_directory" {
		append_unique(&result.directory_refs, token.text)
	} else {
		append_unique(&result.file_refs, token.text)
	}
}

scan_source :: proc(source: string) -> Scan_Result {
	result: Scan_Result
	scanner := Scanner{source = source}
	after_foreign := false

	for {
		token := scanner_next(&scanner)
		if token.kind == .End {
			break
		}

		is_foreign := after_foreign
		after_foreign = token.kind == .Identifier && token.text == "foreign"

		if token.kind == .Identifier && token.text == "import" {
			scan_import(&scanner, &result, is_foreign)
		} else if token.kind == .Directive {
			switch token.text {
			case "load", "load_hash", "load_directory":
				scan_load(&scanner, &result, token.text)
			}
		}
	}

	return result
}

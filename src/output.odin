package krs

import "core:fmt"
import "core:io"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

ANSI_RED :: "\x1b[31m"
ANSI_GREEN :: "\x1b[32m"
ANSI_YELLOW :: "\x1b[33m"
ANSI_CYAN :: "\x1b[36m"
ANSI_DIM :: "\x1b[2m"
ANSI_RESET :: "\x1b[0m"

// The color of package names, tags, paths, and commands, as in the usage.
ANSI_VALUE :: ANSI_RED

Output_Style :: struct {
	stdout, stderr: bool, // these streams support terminal icons
	color:          bool,
}

Progress :: struct {
	worker: ^thread.Thread,
	stop:   sync.Sema,
	output: io.Writer, // the live terminal, even when reports are buffered
	label:  string,
}

// The output procedures below color each `%s` argument as a value. Print a
// string with `%v` to keep it plain, such as prose or a message that was
// formatted already.
highlight :: proc(format: string, colored: bool) -> string {
	if !colored {
		return format
	}

	builder := strings.builder_make(context.temp_allocator)
	for index := 0; index < len(format); {
		if format[index] != '%' {
			strings.write_byte(&builder, format[index])
			index += 1
			continue
		}

		if index + 1 < len(format) && format[index + 1] == '%' {
			strings.write_string(&builder, "%%")
			index += 2
			continue
		}

		// Flags, width, precision, and argument index precede the verb.
		verb := index + 1
		for verb < len(format) && !is_verb(format[verb]) {
			verb += 1
		}

		if verb == len(format) {
			strings.write_string(&builder, format[index:])
			break
		}

		if format[verb] == 's' {
			strings.write_string(&builder, ANSI_VALUE)
			strings.write_string(&builder, format[index:verb + 1])
			strings.write_string(&builder, ANSI_RESET)
		} else {
			strings.write_string(&builder, format[index:verb + 1])
		}
		index = verb + 1
	}
	return strings.to_string(builder)
}

is_verb :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

stdout_colored :: proc(env: ^Env) -> bool {
	return env.style.stdout && env.style.color
}

stderr_colored :: proc(env: ^Env) -> bool {
	return env.style.stderr && env.style.color
}

// Text krs colored itself; printed as is.
Painted :: distinct string

// Repository content must not reach the terminal as control sequences.
printable :: proc(text: string) -> string {
	needs_escape := false
	for index := 0; index < len(text); {
		character, size := utf8.decode_rune_in_string(text[index:])
		if needs_escaping(character, size) {
			needs_escape = true
			break
		}
		index += size
	}

	if !needs_escape {
		return text
	}

	builder := strings.builder_make(context.temp_allocator)
	for index := 0; index < len(text); {
		character, size := utf8.decode_rune_in_string(text[index:])
		switch {
		case character == utf8.RUNE_ERROR && size == 1:
			fmt.sbprintf(&builder, "\\x%02X", text[index])
		case !needs_escaping(character, size):
			strings.write_string(&builder, text[index:index + size])
		case character < 0x100:
			fmt.sbprintf(&builder, "\\x%02X", int(character))
		case:
			fmt.sbprintf(&builder, "\\u{{%04X}}", int(character))
		}
		index += size
	}
	return strings.to_string(builder)
}

@(private = "file")
needs_escaping :: proc(character: rune, size: int) -> bool {
	switch {
	case character == utf8.RUNE_ERROR && size == 1:
		return true
	case character == '\t':
		return false
	case character < 0x20, character == 0x7f, character >= 0x80 && character <= 0x9f:
		return true
	case character >= 0x202a && character <= 0x202e, character >= 0x2066 && character <= 0x2069:
		return true
	}
	return false
}

// Replaces each string argument with its printable form. Painted text and
// every other value pass through.
@(private = "file")
clean_arguments :: proc(arguments: []any) -> []any {
	texts := make([]string, len(arguments), context.temp_allocator)
	cleaned := make([]any, len(arguments), context.temp_allocator)
	for argument, index in arguments {
		cleaned[index] = argument
		if argument.id == string {
			texts[index] = printable((cast(^string)argument.data)^)
			cleaned[index] = texts[index]
		}
	}
	return cleaned
}

// Colors a word for standard output, such as the action of a plan line.
paint :: proc(env: ^Env, color, text: string) -> Painted {
	clean := printable(text)
	if !stdout_colored(env) {
		return Painted(clean)
	}
	return Painted(strings.concatenate({color, clean, ANSI_RESET}, context.temp_allocator))
}

// Formats a line for standard output, with values highlighted.
styled :: proc(env: ^Env, format: string, arguments: ..any) -> Painted {
	return Painted(fmt.aprintf(highlight(format, stdout_colored(env)), ..clean_arguments(arguments)))
}

say :: proc(env: ^Env, format: string, arguments: ..any) {
	progress_stop(env)
	fmt.wprintfln(env.out, highlight(format, stdout_colored(env)), ..clean_arguments(arguments))
}

// Writes a prompt without a newline, so the answer follows it.
prompt :: proc(env: ^Env, format: string, arguments: ..any) {
	progress_stop(env)
	fmt.wprintf(env.out, highlight(format, stdout_colored(env)), ..clean_arguments(arguments))
}

// Writes `<icon>  <label>` before a message. The icon needs a terminal; the
// label is always written.
@(private = "file")
lead :: proc(output: io.Writer, terminal, colored: bool, icon, icon_color, label, label_color: string) {
	if terminal {
		if colored {
			fmt.wprint(output, icon_color, icon, ANSI_RESET, "  ", sep = "")
		} else {
			fmt.wprint(output, icon, "  ", sep = "")
		}
	}

	if colored {
		fmt.wprint(output, label_color, label, ANSI_RESET, " ", sep = "")
	} else {
		fmt.wprint(output, label, " ", sep = "")
	}
}

success :: proc(env: ^Env, format: string, arguments: ..any) {
	progress_stop(env)
	colored := stdout_colored(env)
	lead(env.out, env.style.stdout, colored, "✓", ANSI_GREEN, "krs:", ANSI_DIM)
	fmt.wprintfln(env.out, highlight(format, colored), ..clean_arguments(arguments))
}

// Reports progress that is neither a result nor a problem.
info :: proc(env: ^Env, format: string, arguments: ..any) {
	progress_stop(env)
	colored := stdout_colored(env)
	lead(env.out, env.style.stdout, colored, "•", ANSI_CYAN, "krs:", ANSI_DIM)
	fmt.wprintfln(env.out, highlight(format, colored), ..clean_arguments(arguments))
}

warn :: proc(env: ^Env, format: string, arguments: ..any) {
	progress_stop(env)
	colored := stdout_colored(env)
	lead(env.out, env.style.stdout, colored, "\uf071", ANSI_YELLOW, "warning:", ANSI_YELLOW)
	fmt.wprintfln(env.out, highlight(format, colored), ..clean_arguments(arguments))
}

note :: proc(env: ^Env, format: string, arguments: ..any) {
	progress_stop(env)
	colored := stdout_colored(env)
	lead(env.out, env.style.stdout, colored, "•", ANSI_CYAN, "note:", ANSI_CYAN)
	fmt.wprintfln(env.out, highlight(format, colored), ..clean_arguments(arguments))
}

// Reports a failure and returns false, so a caller can `return fail(...)`.
fail :: proc(env: ^Env, format: string, arguments: ..any) -> bool {
	progress_stop(env)
	colored := stderr_colored(env)
	lead(env.err, env.style.stderr, colored, "✕", ANSI_RED, "krs:", ANSI_DIM)
	fmt.wprintfln(env.err, highlight(format, colored), ..clean_arguments(arguments))
	return false
}

progress_start :: proc(env: ^Env, label: string) {
	progress := env.progress
	if progress == nil {
		return
	}

	assert(progress.worker == nil)
	progress.label = label
	progress.worker = thread.create_and_start_with_poly_data(progress, progress_draw)
}

progress_stop :: proc(env: ^Env) {
	progress := env.progress
	if progress == nil || progress.worker == nil {
		return
	}

	sync.sema_post(&progress.stop)
	thread.destroy(progress.worker)
	progress.worker = nil
}

progress_draw :: proc(progress: ^Progress) {
	frames := [?]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}
	if sync.sema_wait_with_timeout(&progress.stop, 120 * time.Millisecond) {
		return
	}

	for index := 0; ; index = (index + 1) % len(frames) {
		fmt.wprintf(progress.output, "\r\x1b[2K" + ANSI_VALUE + "%s" + ANSI_RESET + "  %s",
			frames[index], progress.label)
		if sync.sema_wait_with_timeout(&progress.stop, 90 * time.Millisecond) {
			break
		}
	}
	fmt.wprint(progress.output, "\r\x1b[2K")
}

package krs

import "core:fmt"
import "core:io"
import "core:sync"
import "core:thread"
import "core:time"

ANSI_RED :: "\x1b[31m"
ANSI_RESET :: "\x1b[0m"

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

say :: proc(env: ^Env, format: string, arguments: ..any) {
	progress_stop(env)
	fmt.wprintfln(env.out, format, ..arguments)
}

success :: proc(env: ^Env, format: string, arguments: ..any) {
	progress_stop(env)
	if env.style.stdout {
		fmt.wprint(env.out, "\x1b[32m✓\x1b[0m  " if env.style.color else "✓  ")
	}
	fmt.wprint(env.out, "krs: ")
	fmt.wprintfln(env.out, format, ..arguments)
}

// Reports a failure and returns false, so a caller can `return fail(...)`.
fail :: proc(env: ^Env, format: string, arguments: ..any) -> bool {
	progress_stop(env)
	if env.style.stderr {
		fmt.wprint(env.err, ANSI_RED + "✕" + ANSI_RESET + "  " if env.style.color else "✕  ")
	}
	fmt.wprint(env.err, "krs: ")
	fmt.wprintfln(env.err, format, ..arguments)
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
		fmt.wprintf(progress.output, "\r\x1b[2K" + ANSI_RED + "%s" + ANSI_RESET + "  %s",
			frames[index], progress.label)
		if sync.sema_wait_with_timeout(&progress.stop, 90 * time.Millisecond) {
			break
		}
	}
	fmt.wprint(progress.output, "\r\x1b[2K")
}

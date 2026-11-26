package main

import "core:os"
import "core:strings"

import krs "../../src"

Command_Result :: struct {
	stdout: string,
	stderr: string,
	code:   int,
}

// Runs a command and captures its output. ok is false, after reporting it,
// when the executable could not be run at all.
command_run :: proc(env: ^krs.Env, command: []string) -> (result: Command_Result, ok: bool) {
	assert(len(command) > 0)
	assert(command[0] != "")

	state, stdout, stderr, err := os.process_exec({command = command}, context.allocator)
	if err != nil {
		return {}, krs.fail(env, "cannot run %s: %v", command[0], err)
	}

	assert(state.exited)
	return Command_Result{stdout = string(stdout), stderr = string(stderr), code = state.exit_code}, true
}

// Runs a command and returns its stdout; a nonzero exit fails with its stderr.
command_output :: proc(env: ^krs.Env, command: []string) -> (stdout: string, ok: bool) {
	assert(len(command) > 0)

	result := command_run(env, command) or_return
	if result.code != 0 {
		message := strings.trim_space(result.stderr)
		if message == "" {
			message = strings.join(command, " ")
			return "", krs.fail(env, "%s exited with %d", message, result.code)
		}
		return "", krs.fail(env, "%s", message)
	}
	return result.stdout, true
}

git_output :: proc(env: ^krs.Env, arguments: ..string) -> (stdout: string, ok: bool) {
	assert(len(arguments) > 0)

	command := make([]string, len(arguments) + 1)
	command[0] = "git"
	copy(command[1:], arguments)
	return command_output(env, command)
}

// The output's only line, as `$(git …)` gives it in sh.
git_line :: proc(env: ^krs.Env, arguments: ..string) -> (line: string, ok: bool) {
	output := git_output(env, ..arguments) or_return
	line = strings.trim_right(output, "\n")
	assert(!strings.contains(line, "\n"))
	return line, true
}

git_head :: proc(env: ^krs.Env) -> (head: string, ok: bool) {
	head = git_line(env, "rev-parse", "--verify", "HEAD") or_return
	assert(head != "")
	return head, true
}

git_is_ancestor :: proc(env: ^krs.Env, ancestor, descendant: string) -> (is_ancestor, ok: bool) {
	assert(ancestor != "")
	assert(descendant != "")

	command := []string{"git", "merge-base", "--is-ancestor", ancestor, descendant}
	result := command_run(env, command) or_return
	switch result.code {
	case 0:
		return true, true
	case 1:
		return false, true
	}
	return false, krs.fail(env, "%s", strings.trim_space(result.stderr))
}

// Fails with `message` unless HEAD is still `head` and the tree is clean.
guard_checkout :: proc(env: ^krs.Env, head, message: string) -> bool {
	assert(head != "")
	assert(message != "")

	current := git_head(env) or_return
	status := git_output(env, "status", "--porcelain", "--untracked-files=all") or_return
	if current != head {
		return krs.fail(env, "%s", message)
	}

	if strings.trim_right(status, "\n") != "" {
		return krs.fail(env, "%s", message)
	}
	return true
}

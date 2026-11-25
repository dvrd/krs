package krs

import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

// A command started by the doctor, alone in its own process group so that a
// timeout can stop it and everything it started.
Doctor_Process :: struct {
	pid: posix.pid_t,
}

DOCTOR_POLLS_PER_SECOND :: 20
DOCTOR_POLL_INTERVAL :: 50 * time.Millisecond
DOCTOR_FORWARDED_SIGNALS :: [3]posix.Signal{.SIGINT, .SIGTERM, .SIGHUP}

// The process group `doctor_forward_signal` stops; 0 outside `doctor_wait`.
doctor_group: posix.pid_t

// Starts `arguments` with `directory` as its working directory, `environment`
// as its whole environment, stdin from /dev/null, and stdout and stderr both
// writing to `output`. The child leads a new process group.
doctor_spawn :: proc(
	directory: string,
	arguments: []string,
	environment: []string,
	output: ^os.File,
) -> (
	process: Doctor_Process,
	err: os.Error,
) {
	assert(len(arguments) > 0)
	assert(arguments[0] != "")
	assert(output != nil)

	// Everything the child touches is prepared here: after `fork` the child
	// may only call async-signal-safe functions.
	path := strings.clone_to_cstring(arguments[0], context.temp_allocator)
	argv := make([]cstring, len(arguments) + 1, context.temp_allocator)
	for argument, i in arguments {
		argv[i] = strings.clone_to_cstring(argument, context.temp_allocator)
	}

	envp := make([]cstring, len(environment) + 1, context.temp_allocator)
	for entry, i in environment {
		envp[i] = strings.clone_to_cstring(entry, context.temp_allocator)
	}

	cdir: cstring
	if directory != "" {
		cdir = strings.clone_to_cstring(directory, context.temp_allocator)
	}

	out_fd := posix.FD(os.fd(output))
	assert(out_fd > posix.STDERR_FILENO)

	// The child reports a failed exec through this pipe; a successful exec
	// closes the write end and the parent reads end-of-file.
	pipe: [2]posix.FD
	if posix.pipe(&pipe) != .OK {
		return process, os.Platform_Error(i32(posix.errno()))
	}

	if posix.fcntl(pipe[1], .SETFD, i32(posix.FD_CLOEXEC)) == -1 {
		err = os.Platform_Error(i32(posix.errno()))
		posix.close(pipe[0])
		posix.close(pipe[1])
		return process, err
	}

	pid := posix.fork()
	if pid == -1 {
		err = os.Platform_Error(i32(posix.errno()))
		posix.close(pipe[0])
		posix.close(pipe[1])
		return process, err
	}

	if pid == 0 {
		// Child: async-signal-safe calls only, and `_exit`, never `exit`.
		child: {
			if posix.setpgid(0, 0) != .OK {
				break child
			}

			null := posix.open("/dev/null", {.RDWR})
			if null == -1 {
				break child
			}

			if posix.dup2(out_fd, posix.STDOUT_FILENO) == -1 {
				break child
			}

			if posix.dup2(out_fd, posix.STDERR_FILENO) == -1 {
				break child
			}

			if posix.dup2(null, posix.STDIN_FILENO) == -1 {
				break child
			}

			if cdir != nil && posix.chdir(cdir) != .OK {
				break child
			}

			posix.execve(path, raw_data(argv), raw_data(envp))
		}

		code := u8(posix.errno())
		posix.write(pipe[1], &code, 1)
		posix._exit(126)
	}

	// Parent. The child sets its own group first; this call closes the race
	// where the parent would signal the group before it exists. EACCES (the
	// child already ran exec) and ESRCH (it already exited) are both fine.
	_ = posix.setpgid(pid, pid)
	posix.close(pipe[1])

	exec_errno: i32
	for {
		code: u8
		count := posix.read(pipe[0], &code, 1)
		if count == -1 && posix.errno() == .EINTR {
			continue
		}

		if count == 1 {
			exec_errno = i32(code)
		}
		break
	}
	posix.close(pipe[0])

	if exec_errno != 0 {
		status: i32
		for posix.waitpid(pid, &status, {}) == -1 && posix.errno() == .EINTR {
		}
		return process, os.Platform_Error(exec_errno)
	}

	process.pid = pid
	return process, nil
}

// Waits up to `seconds`. Returns exited/exit_code like os.Process_State, or
// timed_out = true after killing the whole group with SIGKILL and reaping it.
// While it waits, SIGINT, SIGTERM and SIGHUP kill the group before krs dies
// from them: the group does not receive the terminal's signals itself.
doctor_wait :: proc(
	process: Doctor_Process,
	seconds: i64,
) -> (
	exited: bool,
	exit_code: int,
	timed_out: bool,
	err: os.Error,
) {
	assert(process.pid > 0)
	assert(seconds > 0)

	signals := DOCTOR_FORWARDED_SIGNALS
	previous: [len(signals)]posix.sigaction_t
	installed: [len(signals)]bool

	action: posix.sigaction_t
	action.sa_handler = doctor_forward_signal
	posix.sigemptyset(&action.sa_mask)
	action.sa_flags = {}

	doctor_group = process.pid
	for sig, i in signals {
		installed[i] = posix.sigaction(sig, &action, &previous[i]) == .OK
	}

	defer {
		for sig, i in signals {
			if installed[i] {
				posix.sigaction(sig, &previous[i], nil)
			}
		}
		doctor_group = 0
	}

	pid := process.pid
	status: i32
	polls := seconds * DOCTOR_POLLS_PER_SECOND
	for poll: i64 = 0; poll < polls; {
		reaped := posix.waitpid(pid, &status, {.NOHANG})
		if reaped == -1 {
			if posix.errno() == .EINTR {
				continue
			}
			return false, 0, false, os.Platform_Error(i32(posix.errno()))
		}

		if reaped == pid {
			exited = posix.WIFEXITED(status)
			if exited {
				exit_code = int(posix.WEXITSTATUS(status))
			}
			return exited, exit_code, false, nil
		}

		assert(reaped == 0)
		time.sleep(DOCTOR_POLL_INTERVAL)
		poll += 1
	}

	// Timed out: stop the group, and the shell itself in case it moved to
	// another group.
	group_result := posix.killpg(pid, .SIGKILL)
	group_errno := posix.errno()
	pid_result := posix.kill(pid, .SIGKILL)
	pid_errno := posix.errno()
	if group_result != .OK && group_errno == .EPERM && pid_result != .OK && pid_errno == .EPERM {
		err = os.Platform_Error(i32(posix.Errno.EPERM))
	}

	for posix.waitpid(pid, &status, {}) == -1 && posix.errno() == .EINTR {
	}
	return false, 0, true, err
}

// Runs in a signal handler: kills the doctor's process group, then lets the
// signal take its default action on krs.
doctor_forward_signal :: proc "c" (sig: posix.Signal) {
	if doctor_group > 0 {
		posix.killpg(doctor_group, .SIGKILL)
	}

	reset: posix.sigaction_t
	reset.sa_handler = auto_cast posix.SIG_DFL
	posix.sigemptyset(&reset.sa_mask)
	posix.sigaction(sig, &reset, nil)
	posix.raise(sig)
}

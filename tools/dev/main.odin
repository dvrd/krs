package main

import "core:fmt"
import "core:os"

// Developer tooling for the KRS repository. It runs before KRS builds, so it
// imports only core: packages and nothing from src (libgit2, SQLite, kakunou).

EXIT_OK :: 0
EXIT_FAILED :: 1
EXIT_USAGE :: 2

main :: proc() {
	context.allocator = context.temp_allocator
	os.exit(run(os.args[1:]))
}

run :: proc(args: []string) -> int {
	if len(args) == 2 && args[0] == "build" {
		if !os.exists("ODIN_VERSION") {
			return fail("run krs-dev from the KRS repository")
		}

		switch args[1] {
		case "debug":
			return build_command(.Debug)
		case "release":
			return build_command(.Release)
		}
		return usage()
	}

	if len(args) != 1 {
		return usage()
	}

	if !os.exists("ODIN_VERSION") {
		return fail("run krs-dev from the KRS repository")
	}

	switch args[0] {
	case "toolchain":
		return EXIT_OK if toolchain() else EXIT_FAILED
	case "test-layout":
		return EXIT_OK if test_layout(".") else EXIT_FAILED
	case "install":
		return install()
	}
	return usage()
}

usage :: proc() -> int {
	fmt.eprintln("krs: usage: krs-dev toolchain | test-layout | build debug|release | install")
	return EXIT_USAGE
}

fail :: proc(message: string) -> int {
	assert(message != "")

	fmt.eprintfln("krs: %s", message)
	return EXIT_FAILED
}

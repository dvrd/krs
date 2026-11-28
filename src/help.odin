package krs

import "core:fmt"
import "core:io"
import "core:strings"

// One command's entry in `krs help`, and its own text for `krs <name> help`.
// In `text`, %[0]s starts and %[1]s ends a highlighted part.
Command_Help :: struct {
	name:    string,
	summary: string,
	text:    string,
}

HELP_INSTALL :: `%[0]susage:%[1]s krs install [--root=<path>] [--frozen | --repair] [--yes]

Installs the releases this project imports into the Odin root's shared/,
and records them in .krs/packages.json.

options:
  %[0]s--root=<path>%[1]s  work on the shared/ of the Odin root at <path>
  %[0]s--frozen%[1]s       install exactly what .krs/packages.json says, or fail
  %[0]s--repair%[1]s       reinstall packages whose installed files were changed
  %[0]s--yes%[1]s          do not ask before writing
`

HELP_STATUS :: `%[0]susage:%[1]s krs status [-g] [--root=<path>]

Checks that this project's packages are in place and lists those that are not:
altered, missing, a broken link, or a release other than the one this project
records. Exits 1 when one needs attention. %[0]skrs ls%[1]s lists them all.

options:
  %[0]s-g, --global%[1]s   list everything the Odin root holds, links included
  %[0]s--root=<path>%[1]s  work on the shared/ of the Odin root at <path>
`

HELP_LS :: `%[0]susage:%[1]s krs ls [--root=<path>]

Lists this project's packages: the version .krs/packages.json records, why the
project has it (imported here, or via the packages that import it), and what
the Odin root holds for it. Imports not recorded yet are listed too.

options:
  %[0]s--root=<path>%[1]s  work on the shared/ of the Odin root at <path>
`

HELP_UPDATE :: `%[0]susage:%[1]s krs update [<package>[@<tag>]...] [options]

Lists newer releases of this project's packages and changes nothing. Names
filter what is checked; name@tag checks that release.

modes:
  %[0]s-u, --upgrade%[1]s              write the chosen versions to .krs/packages.json and install them
  %[0]s-i, --interactive%[1]s          choose which upgrades to take, then apply them
  %[0]s-d, --doctor%[1]s               with -u: run the tests and keep only the upgrades that pass
  %[0]s-g, --global%[1]s               check every package of the Odin root
  %[0]s--deep%[1]s                     check every project under this directory
  %[0]s--package-file%[1]s <p>         check the projects whose lockfile matches p (repeatable)

choosing versions:
  %[0]s-t, --target%[1]s <t>           latest, greatest (default), newest, minor, patch or semver
  %[0]s-c, --cooldown%[1]s <p>         ignore releases younger than this (7, 7d, 12h, 30m)
  %[0]s-f, --filter%[1]s <p>           only names matching p (name, a,b, glob*, /regex/, !name)
  %[0]s-x, --reject%[1]s <p>           skip names matching p
  %[0]s--filter-version%[1]s <p>       only current versions matching p
  %[0]s--reject-version%[1]s <p>       skip current versions matching p
  %[0]s--fetch%[1]s                    refresh the GitHub releases of the packages first

upgrading:
  %[0]s--install%[1]s <m>              always, never (lockfile only) or prompt
  %[0]s--pin%[1]s                      pin every chosen version
  %[0]s--interactive-select%[1]s <w>   with -i: auto, none, patch, minor or all start selected
  %[0]s--doctor-test%[1]s <cmd>        test command for --doctor (default: odin test .)
  %[0]s--doctor-install%[1]s <cmd>     command run after each install for --doctor (default: none)
  %[0]s--doctor-timeout%[1]s <d>       stop a --doctor command after 30s, 10m, 2h... (default: 30m)
  %[0]s--root=<path>%[1]s              work on the shared/ of the Odin root at <path>
  %[0]s--yes%[1]s                      do not ask before writing

output:
  %[0]s--format%[1]s <v,...>           group, lines, time, repo, diff, installed-version, cooldown; no-<v> removes
  %[0]s-j, --json-all%[1]s             print the new .krs/packages.json as JSON
  %[0]s--json-upgraded%[1]s            print the upgrades as JSON
  %[0]s--json-deps%[1]s                print the new package list as JSON
  %[0]s-e, --error-level%[1]s <n>      2: exit 1 when upgrades are available
  %[0]s-s, --silent%[1]s               print nothing; use the exit code
  %[0]s-l, --loglevel%[1]s <l>         silent, error, minimal, warn, info or verbose
`

HELP_FETCH :: `%[0]susage:%[1]s krs fetch [<owner>/<repo>]

With no argument, refreshes the GitHub releases of this project's
dependencies: the packages .krs/packages.json records and the shared: names
the project imports. With <owner>/<repo>, selects or refreshes that
repository.
`

HELP_LINK :: `%[0]susage:%[1]s krs link <package> [--root=<path>] [--yes]

Uses a checkout's live src/ in place of the installed release. %[0]skrs status -g%[1]s
lists the links and flags broken ones.

options:
  %[0]s--root=<path>%[1]s  work on the shared/ of the Odin root at <path>
  %[0]s--yes%[1]s          do not ask before writing
`

HELP_UNLINK :: `%[0]susage:%[1]s krs unlink <package> [--root=<path>] [--restore] [--yes]

Removes a link from the Odin root's shared/.

options:
  %[0]s--restore%[1]s      install the recorded release in its place
  %[0]s--root=<path>%[1]s  work on the shared/ of the Odin root at <path>
  %[0]s--yes%[1]s          do not ask before writing
`

HELP_PIN :: `%[0]susage:%[1]s krs pin <package> [--root=<path>]

Holds a package at the release .krs/packages.json records. A dependency
cannot move a pinned package.

options:
  %[0]s--root=<path>%[1]s  work on the shared/ of the Odin root at <path>
`

HELP_UNPIN :: `%[0]susage:%[1]s krs unpin <package> [--root=<path>]

Lets a pinned package be upgraded again.

options:
  %[0]s--root=<path>%[1]s  work on the shared/ of the Odin root at <path>
`

HELP_VENDOR :: `%[0]susage:%[1]s krs vendor [--root=<path>] [--yes]

Copies every dependency, at this project's versions, into vendor/; every
later krs command for this project uses it. Build with:

  odin build . -collection:shared=vendor

options:
  %[0]s--root=<path>%[1]s  work on the shared/ of the Odin root at <path>
  %[0]s--yes%[1]s          do not ask before writing
`

HELP_UNINSTALL :: `%[0]susage:%[1]s krs uninstall [<package>...] [--root=<path>] [--yes]

Removes packages from the Odin root and from .krs/packages.json. With no
names, choose them from a fuzzy list.

options:
  %[0]s--root=<path>%[1]s  work on the shared/ of the Odin root at <path>
  %[0]s--yes%[1]s          do not ask before writing
`

HELP_RECOVER :: `%[0]susage:%[1]s krs recover
       krs recover abandon <id> [--yes]

Lists interrupted file publications. %[0]sabandon%[1]s gives up on one.

options:
  %[0]s--yes%[1]s  do not ask before writing
`

@(rodata)
COMMAND_HELP := [?]Command_Help {
	{"install", "install the releases this project imports", HELP_INSTALL},
	{"ls", "list this project's packages and their versions", HELP_LS},
	{"status", "check that this project's packages are in place", HELP_STATUS},
	{"update", "list newer releases; with -u, upgrade to them", HELP_UPDATE},
	{"fetch", "refresh the GitHub releases of this project's dependencies", HELP_FETCH},
	{"link", "use a checkout's live src/ in place of a release", HELP_LINK},
	{"unlink", "remove a link", HELP_UNLINK},
	{"pin", "hold a package at the release this project records", HELP_PIN},
	{"unpin", "let a pinned package be upgraded again", HELP_UNPIN},
	{"vendor", "copy this project's dependencies into vendor/", HELP_VENDOR},
	{"uninstall", "remove packages from the Odin root", HELP_UNINSTALL},
	{"recover", "list or abandon interrupted file publications", HELP_RECOVER},
}

// The longest command name, for the column in `krs help`.
HELP_NAME_WIDTH :: 9

help_paint :: proc(colored: bool) -> (start, end: string) {
	if colored {
		return ANSI_VALUE, ANSI_RESET
	}
	return "", ""
}

// `krs help`: every command once. Flags are in each command's own help.
print_usage :: proc(output: io.Writer, colored: bool) {
	start, end := help_paint(colored)
	fmt.wprintf(output, "%susage:%s krs <command> [options]\n\ncommands:\n", start, end)
	for command in COMMAND_HELP {
		assert(len(command.name) <= HELP_NAME_WIDTH)
		padding := strings.repeat(" ", HELP_NAME_WIDTH - len(command.name), context.temp_allocator)
		fmt.wprintf(output, "  %s%s%s%s  %s\n", start, command.name, end, padding, command.summary)
	}

	fmt.wprintf(output, "\n  %skrs <command> help%s  show a command's usage and options\n", start, end)
	fmt.wprintf(output, "  %skrs --version%s       print the version\n", start, end)
	fmt.wprintf(output, "  %s--color%s             force colors, with any command\n", start, end)
}

help_find :: proc(name: string) -> (command: Command_Help, found: bool) {
	for candidate in COMMAND_HELP {
		if candidate.name == name {
			return candidate, true
		}
	}
	return {}, false
}

// `krs <name> help`. False when `name` is not a command.
print_command_help :: proc(output: io.Writer, colored: bool, name: string) -> bool {
	command := help_find(name) or_return
	start, end := help_paint(colored)
	fmt.wprintf(output, command.text, start, end)
	return true
}

// What a help request asks about: `krs help [<command>]`, `krs --help`,
// `krs -h`, `krs <command> help`, or a command with --help or -h anywhere.
// `topic` is "" for the list of commands.
help_request :: proc(arguments: []string) -> (topic: string, asked: bool) {
	if len(arguments) == 0 {
		return "", false
	}

	first := arguments[0]
	if first == "help" || first == "--help" || first == "-h" {
		if len(arguments) >= 2 {
			return arguments[1], true
		}
		return "", true
	}

	if _, found := help_find(first); !found {
		return "", false
	}

	if len(arguments) >= 2 && arguments[1] == "help" {
		return first, true
	}

	for argument in arguments[1:] {
		if argument == "--help" || argument == "-h" {
			return first, true
		}
	}
	return "", false
}

// Prints the help `arguments` asks for, on stdout.
help_run :: proc(env: ^Env, topic: string) -> int {
	colored := env.style.stdout && env.style.color
	if topic == "" || topic == "help" {
		print_usage(env.out, colored)
		return EXIT_OK
	}

	if !print_command_help(env.out, colored, topic) {
		fail(env, "%s is not a command; run krs help", topic)
		return EXIT_USAGE
	}
	return EXIT_OK
}

// Misuse of a known command shows that command's usage; anything else the
// list of commands. Both go to stderr.
print_misuse :: proc(env: ^Env, name: string) {
	colored := env.style.stderr && env.style.color
	if !print_command_help(env.err, colored, name) {
		print_usage(env.err, colored)
	}
}

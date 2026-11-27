package unit

import "core:strings"
import "core:testing"

import krs "../../src"

@(test)
print_usage_lists_every_command_once :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	plain := strings.builder_make()
	krs.print_usage(strings.to_writer(&plain), false)
	text := strings.to_string(plain)
	testing.expect(t, strings.has_prefix(text, "usage: krs <command> [options]\n"))
	testing.expect(t, !strings.contains(text, "\x1b"))
	testing.expect(t, !strings.contains(text, "%!"), "every verb has an argument")
	testing.expect(t, !strings.contains(text, "--doctor"), "flags belong to each command's help")
	for command in krs.COMMAND_HELP {
		row := strings.concatenate({"\n  ", command.name, " "})
		testing.expectf(t, strings.count(text, row) == 1, "%s is listed once in: %s", command.name, text)
	}

	colored := strings.builder_make()
	krs.print_usage(strings.to_writer(&colored), true)
	painted := strings.to_string(colored)
	testing.expect(t, strings.has_prefix(painted, krs.ANSI_VALUE + "usage:" + krs.ANSI_RESET))
	testing.expect(t, strings.contains(painted, "  " + krs.ANSI_VALUE + "install" + krs.ANSI_RESET))
}

@(test)
print_command_help_formats_every_command :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	for command in krs.COMMAND_HELP {
		plain := strings.builder_make()
		testing.expect(t, krs.print_command_help(strings.to_writer(&plain), false, command.name))
		text := strings.to_string(plain)
		usage := strings.concatenate({"usage: krs ", command.name})
		testing.expectf(t, strings.has_prefix(text, usage), "%s help starts with its usage: %s", command.name, text)
		testing.expectf(t, !strings.contains(text, "%!"), "%s help has an argument for every verb", command.name)

		colored := strings.builder_make()
		krs.print_command_help(strings.to_writer(&colored), true, command.name)
		testing.expectf(t, !strings.contains(strings.to_string(colored), "%!"), "%s colored help", command.name)
	}

	none := strings.builder_make()
	testing.expect(t, !krs.print_command_help(strings.to_writer(&none), false, "bogus"))
	testing.expect_value(t, strings.to_string(none), "")
}

Help_Case :: struct {
	arguments: []string,
	topic:     string,
	asked:     bool,
}

@(test)
help_request_finds_the_topic :: proc(t: ^testing.T) {
	table := []Help_Case {
		{{}, "", false},
		{{"help"}, "", true},
		{{"--help"}, "", true},
		{{"-h"}, "", true},
		{{"help", "update"}, "update", true},
		{{"update", "help"}, "update", true},
		{{"update", "-u", "--help"}, "update", true},
		{{"link", "-h"}, "link", true},
		{{"update", "surf"}, "", false},
		{{"bogus", "help"}, "", false},
		{{"update", "surf", "help"}, "", false},
	}
	for row in table {
		topic, asked := krs.help_request(row.arguments)
		testing.expectf(t, topic == row.topic && asked == row.asked, "%v: got (%q, %v), want (%q, %v)", row.arguments, topic, asked, row.topic, row.asked)
	}
}

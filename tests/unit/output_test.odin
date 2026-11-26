package unit

import "core:strings"
import "core:testing"

import krs "../../src"

@(test)
output_highlights_string_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	V :: krs.ANSI_VALUE
	R :: krs.ANSI_RESET
	testing.expect_value(t, krs.highlight("%s is at %s", false), "%s is at %s")
	testing.expect_value(t, krs.highlight("%s is at %s", true), V + "%s" + R + " is at " + V + "%s" + R)
	testing.expect_value(t, krs.highlight("%v, %d, 100%% and %-8s", true), "%v, %d, 100%% and " + V + "%-8s" + R)
	testing.expect_value(t, krs.highlight("trailing %", true), "trailing %")

	out := strings.builder_make()
	env := krs.Env {
		out   = strings.to_writer(&out),
		style = {stdout = true, color = true},
	}
	krs.warn(&env, "%s is %v", "alpha", "stale")
	testing.expect_value(
		t,
		strings.to_string(out),
		krs.ANSI_YELLOW + "\uf071" + R + "  " + krs.ANSI_YELLOW + "warning:" + R + " " + V + "alpha" + R + " is stale\n",
	)

	strings.builder_reset(&out)
	env.style = {}
	krs.warn(&env, "%s is %v", "alpha", "stale")
	testing.expect_value(t, strings.to_string(out), "warning: alpha is stale\n")
}

@(test)
printable_escapes_control_characters :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	testing.expect_value(t, krs.printable("plain/path.odin"), "plain/path.odin")
	testing.expect_value(t, krs.printable("café"), "café")
	testing.expect_value(t, krs.printable("a\x1b[2Jb"), "a\\x1B[2Jb")
	testing.expect_value(t, krs.printable("tab\there"), "tab\there")
	testing.expect_value(t, krs.printable("line\nbreak"), "line\\x0Abreak")
	testing.expect_value(t, krs.printable("a\u009bb"), "a\\x9Bb")
	testing.expect_value(t, krs.printable("\xff"), "\\xFF")
	testing.expect_value(t, krs.printable("a‮b"), "a\\u{202E}b")

	out := strings.builder_make()
	env := krs.Env {
		out   = strings.to_writer(&out),
		style = {stdout = true, color = true},
	}
	painted := krs.paint(&env, krs.ANSI_GREEN, "ok")
	krs.warn(&env, "%s then %v", "bad\x1b[2J", painted)
	text := strings.to_string(out)
	testing.expect(t, strings.contains(text, "bad\\x1B[2J"))
	testing.expect(t, !strings.contains(text, "bad\x1b"))
	testing.expect(t, strings.contains(text, krs.ANSI_GREEN + "ok" + krs.ANSI_RESET))
}

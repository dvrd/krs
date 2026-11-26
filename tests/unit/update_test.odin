package unit

import "core:io"
import "core:strings"
import "core:testing"

import krs "../../src"

@(test)
cooldown_periods_parse :: proc(t: ^testing.T) {
	for text in ([]string{"7", "7d"}) {
		seconds, ok := krs.cooldown_seconds(text)
		testing.expect(t, ok)
		testing.expect_value(t, seconds, 604800)
	}

	seconds, ok := krs.cooldown_seconds("12h")
	testing.expect(t, ok)
	testing.expect_value(t, seconds, 43200)
	seconds, ok = krs.cooldown_seconds("30m")
	testing.expect(t, ok)
	testing.expect_value(t, seconds, 1800)

	for text in ([]string{"0", "", "d", "7x", "99999", "87601h", "-7", "+7", "0x7", "7D"}) {
		_, valid := krs.cooldown_seconds(text)
		testing.expectf(t, !valid, "%q should be rejected", text)
	}
}

// One scripted read: bytes to hand back, or an error to return.
Script_Step :: struct {
	bytes: string,
	error: io.Error,
}

Script_Reader :: struct {
	steps: [dynamic]Script_Step,
	next:  int,
}

script_reader_proc :: proc(data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
	reader := cast(^Script_Reader)data
	if mode != .Read {
		return 0, .Empty
	}

	if reader.next >= len(reader.steps) {
		return 0, .EOF
	}

	step := reader.steps[reader.next]
	reader.next += 1
	if step.error != nil {
		return 0, step.error
	}

	copy(p, step.bytes)
	return i64(len(step.bytes)), nil
}

@(test)
interactive_cancels_on_a_partial_answer_at_end_of_input :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	reader := Script_Reader{}
	append(&reader.steps, Script_Step{bytes = "a"})
	append(&reader.steps, Script_Step{error = .Unexpected_EOF})
	append(&reader.steps, Script_Step{bytes = "\n"})

	out := strings.builder_make()
	errors := strings.builder_make()
	env := krs.Env {
		out         = strings.to_writer(&out),
		err         = strings.to_writer(&errors),
		input       = io.Stream{procedure = script_reader_proc, data = &reader},
		interactive = true,
	}

	candidates := []krs.Update_Candidate {
		{name = "alpha", current = "v0.1.0", chosen = "v0.1.1", group = .Patch},
		{name = "beta", current = "v0.2.0", chosen = "v0.2.1", group = .Patch},
	}

	chosen, ok := krs.update_choose_interactive(&env, candidates, .None)
	testing.expect(t, !ok)
	testing.expect_value(t, len(chosen), 0)
}

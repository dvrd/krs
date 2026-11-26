package unit

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

import krs "../../src"

// The match is a case-insensitive subsequence, and the score prefers
// consecutive matches and a match at the start of the text.
@(test)
fuzzy_score_matches_subsequences :: proc(t: ^testing.T) {
	score, matched := krs.fuzzy_score("", "beta")
	testing.expect(t, matched)
	testing.expect_value(t, score, 0)

	_, matched = krs.fuzzy_score("bt", "beta")
	testing.expect(t, matched)

	_, matched = krs.fuzzy_score("tb", "beta")
	testing.expect(t, !matched)

	_, matched = krs.fuzzy_score("BE", "beta")
	testing.expect(t, matched)

	_, matched = krs.fuzzy_score("x", "beta")
	testing.expect(t, !matched)

	beta, beta_matched := krs.fuzzy_score("be", "beta")
	tribe, tribe_matched := krs.fuzzy_score("be", "tribe")
	testing.expect(t, beta_matched)
	testing.expect(t, tribe_matched)
	testing.expectf(t, beta > tribe, "beta %d should beat tribe %d", beta, tribe)

	kessel, kessel_matched := krs.fuzzy_score("k", "kessel")
	ok_k, ok_k_matched := krs.fuzzy_score("k", "ok_k")
	testing.expect(t, kessel_matched)
	testing.expect(t, ok_k_matched)
	testing.expectf(t, kessel > ok_k, "kessel %d should beat ok_k %d (start bonus)", kessel, ok_k)
}

picker_test_items :: proc() -> []krs.Picker_Item {
	items := make([]krs.Picker_Item, 3)
	items[0] = {label = "beta", detail = "v1.0.0"}
	items[1] = {label = "gamma", detail = "v1.0.0"}
	items[2] = {label = "kessel", detail = "v0.2.0 pinned"}
	return items
}

// Filtering keeps only matching labels, best first, and keeps the cursor
// inside the shorter list.
@(test)
picker_filter_keeps_matches_best_first :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	picker: krs.Picker
	krs.picker_init(&picker, picker_test_items())
	testing.expect_value(t, len(picker.visible), 3)

	picker.cursor = 2
	append(&picker.query, 'e')
	krs.picker_filter(&picker)
	testing.expect_value(t, len(picker.visible), 2)
	for index in picker.visible {
		testing.expect(t, strings.contains(picker.items[index].label, "e"))
	}
	// kessel's e follows its first byte; beta's follows b as well, so the
	// equal scores fall back to the label.
	testing.expect_value(t, picker.items[picker.visible[0]].label, "beta")
	testing.expect_value(t, picker.items[picker.visible[1]].label, "kessel")
	testing.expect_value(t, picker.cursor, 1)

	append(&picker.query, 's')
	krs.picker_filter(&picker)
	testing.expect_value(t, len(picker.visible), 1)
	testing.expect_value(t, picker.items[picker.visible[0]].label, "kessel")
	testing.expect_value(t, picker.cursor, 0)

	append(&picker.query, 'z')
	krs.picker_filter(&picker)
	testing.expect_value(t, len(picker.visible), 0)
	testing.expect_value(t, picker.cursor, 0)
}

@(test)
picker_apply_moves_and_selects :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	picker: krs.Picker
	krs.picker_init(&picker, picker_test_items())

	// Up at the top stays there; Backspace on an empty query does nothing.
	done, cancelled := krs.picker_apply(&picker, .Up, 0)
	testing.expect(t, !done)
	testing.expect_value(t, picker.cursor, 0)
	krs.picker_apply(&picker, .Backspace, 0)
	testing.expect_value(t, len(picker.query), 0)
	testing.expect_value(t, len(picker.visible), 3)

	// Toggle selects the item under the cursor and moves down.
	krs.picker_apply(&picker, .Toggle, 0)
	testing.expect(t, picker.selected[picker.visible[0]])
	testing.expect_value(t, picker.cursor, 1)

	// Down stops at the bottom.
	krs.picker_apply(&picker, .Down, 0)
	krs.picker_apply(&picker, .Down, 0)
	testing.expect_value(t, picker.cursor, 2)

	// Toggle_All selects every visible item, then clears them all.
	krs.picker_apply(&picker, .Toggle_All, 0)
	for selected in picker.selected {
		testing.expect(t, selected)
	}
	krs.picker_apply(&picker, .Toggle_All, 0)
	for selected in picker.selected {
		testing.expect(t, !selected)
	}

	// Typing refilters; Cancel ends without a choice.
	krs.picker_apply(&picker, .Char, 'g')
	testing.expect_value(t, string(picker.query[:]), "g")
	testing.expect_value(t, len(picker.visible), 1)
	done, cancelled = krs.picker_apply(&picker, .Cancel, 0)
	testing.expect(t, done)
	testing.expect(t, cancelled)
}

// Enter with nothing selected chooses the item under the cursor.
@(test)
picker_apply_enter_takes_the_cursor_item :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	picker: krs.Picker
	krs.picker_init(&picker, picker_test_items())

	krs.picker_apply(&picker, .Down, 0)
	done, cancelled := krs.picker_apply(&picker, .Enter, 0)
	testing.expect(t, done)
	testing.expect(t, !cancelled)
	testing.expect(t, !picker.selected[0])
	testing.expect(t, picker.selected[1])
	testing.expect(t, !picker.selected[2])

	// With a selection, Enter keeps it as it is.
	krs.picker_init(&picker, picker_test_items())
	krs.picker_apply(&picker, .Toggle, 0)
	krs.picker_apply(&picker, .Enter, 0)
	testing.expect(t, picker.selected[0])
	testing.expect(t, !picker.selected[1])
}

// Each byte string reads as one key; escape sequences take several bytes.
@(test)
picker_read_key_decodes_bytes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	Case :: struct {
		input: string,
		key:   krs.Picker_Key,
		char:  u8,
		ended: bool,
	}
	cases := []Case {
		{input = "\x1b[A", key = .Up},
		{input = "\x1b[B", key = .Down},
		{input = "\x1b[C", key = .None},
		{input = "\x1bOA", key = .Up},
		{input = "\x1bOB", key = .Down},
		{input = "\x1bq", key = .Cancel},
		{input = "\x1b", key = .Cancel},
		{input = "\x7f", key = .Backspace},
		{input = "\x08", key = .Backspace},
		{input = " ", key = .Toggle},
		{input = "\t", key = .Toggle},
		{input = "\x01", key = .Toggle_All},
		{input = "\x10", key = .Up},
		{input = "\x0e", key = .Down},
		{input = "\r", key = .Enter},
		{input = "\n", key = .Enter},
		{input = "\x03", key = .Cancel},
		{input = "\x07", key = .Cancel},
		{input = "z", key = .Char, char = 'z'},
		{input = "\x02", key = .None},
		{input = "", key = .None, ended = true},
	}

	for test_case in cases {
		reader: strings.Reader
		env := krs.Env {
			input = strings.to_reader(&reader, test_case.input),
		}
		key, char, ended := krs.picker_read_key(&env)
		testing.expectf(t, key == test_case.key, "%q: key %v, want %v", test_case.input, key, test_case.key)
		testing.expectf(t, char == test_case.char, "%q: char %v, want %v", test_case.input, char, test_case.char)
		testing.expectf(t, ended == test_case.ended, "%q: ended %v", test_case.input, ended)
	}

	// Only the key's bytes are read; the rest stays for the next reader.
	reader: strings.Reader
	env := krs.Env {
		input = strings.to_reader(&reader, "\ry\n"),
	}
	key, _, _ := krs.picker_read_key(&env)
	testing.expect_value(t, key, krs.Picker_Key.Enter)
	testing.expect_value(t, krs.ask_line(&env), "y")
}

// A label too long for the terminal is cut with `…`, so the row never wraps
// and the frame keeps its line count, which the redraw relies on.
@(test)
picker_render_cuts_long_lines :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	short_picker: krs.Picker
	krs.picker_init(&short_picker, picker_test_items())
	short_out := strings.builder_make()
	short_env := krs.Env {
		out = strings.to_writer(&short_out),
	}
	short_lines := krs.picker_render(&short_env, &short_picker, "uninstall>", 0)

	items := picker_test_items()
	items[1].label = strings.repeat("g", 100)
	picker: krs.Picker
	krs.picker_init(&picker, items)
	out := strings.builder_make()
	env := krs.Env {
		out = strings.to_writer(&out),
	}
	lines := krs.picker_render(&env, &picker, "uninstall>", 0)
	testing.expect_value(t, lines, short_lines)

	rows := strings.split_lines(strings.trim_right(strings.to_string(out), "\n"))
	testing.expect_value(t, len(rows), lines)
	long := ""
	for row in rows {
		testing.expectf(t, utf8.rune_count_in_string(row) <= krs.PICKER_WIDTH_MAX, "row too wide: %q", row)
		if strings.contains(row, "ggg") {
			long = row
		}
	}
	testing.expect(t, strings.has_suffix(long, "…"))
	testing.expect_value(t, utf8.rune_count_in_string(long), krs.PICKER_WIDTH_MAX)
	testing.expect(t, !strings.contains(long, "v1.0.0"))

	// A detail that does not fit is cut, and the label stays whole.
	label, detail, cut := krs.picker_fit("kessel", "v1.0.0 pinned linked", 16)
	testing.expect(t, cut)
	testing.expect_value(t, label, "kessel")
	testing.expect_value(t, detail, "v1.0.0 p")
	label, detail, cut = krs.picker_fit("kessel", "v1.0.0", 16)
	testing.expect(t, !cut)
	testing.expect_value(t, detail, "v1.0.0")
}

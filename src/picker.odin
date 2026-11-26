package krs

import "core:fmt"
import "core:io"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

// A fuzzy multi-select list read key by key from env.input. In a terminal,
// env.raw_input switches the terminal to raw mode for the picker's lifetime;
// tests leave it nil and feed the key bytes as they are.

Picker_Item :: struct {
	label:  string, // what is matched and shown first, e.g. the package name
	detail: string, // shown dimmed after the label, e.g. "v1.2.0 pinned"
}

Picker :: struct {
	items:    []Picker_Item,
	query:    [dynamic]u8,
	selected: []bool, // by item index
	visible:  [dynamic]int, // item indexes matching the query, best first
	cursor:   int, // index into visible
}

Picker_Key :: enum {
	None,
	Char,
	Backspace,
	Up,
	Down,
	Toggle,
	Toggle_All,
	Enter,
	Cancel,
}

// Every key press redraws the frame; a person never needs this many.
PICKER_KEYS_MAX :: 4096
PICKER_ROWS_MAX :: 10
PICKER_HINT :: "Space select · Ctrl-A all · Enter confirm · Ctrl-C cancel"
// The widest line the picker writes, so that no frame line wraps on an
// 80-column terminal: a wrapped line would make the redraw move up too few
// lines and leave parts of old frames behind.
PICKER_WIDTH_MAX :: 76
// The `> [x] ` before each label.
PICKER_ROW_PREFIX_WIDTH :: 6

#assert(PICKER_ROWS_MAX > 0)
#assert(PICKER_ROW_PREFIX_WIDTH + 2 < PICKER_WIDTH_MAX)
#assert(len(PICKER_HINT) <= PICKER_WIDTH_MAX + 6) // each · is 2 bytes and 1 column

// Lets a person choose items. Returns the chosen item indexes in item order;
// `ok` is false when they cancelled, input ended, or nothing was chosen.
picker_run :: proc(env: ^Env, items: []Picker_Item, title: string) -> (chosen: [dynamic]int, ok: bool) {
	assert(len(items) > 0) // the caller has something to offer
	assert(title != "")

	if env.raw_input != nil {
		if !env.raw_input(true) {
			return chosen, fail(env, "cannot read keys from this terminal")
		}
	}
	// Registered only once raw mode is on, and run on every return below, so
	// the terminal is never left raw.
	defer if env.raw_input != nil {
		env.raw_input(false)
	}

	picker: Picker
	picker_init(&picker, items)
	progress_stop(env)

	lines := 0
	for _ in 0 ..< PICKER_KEYS_MAX {
		lines = picker_render(env, &picker, title, lines)
		key, char, ended := picker_read_key(env)
		done, cancelled := ended, ended // input ending counts as cancel, like update -i
		if !ended {
			done, cancelled = picker_apply(&picker, key, char)
		}

		if !done {
			continue
		}

		picker_clear(env, lines)
		if cancelled {
			return chosen, fail(env, "nothing was chosen")
		}

		for selected, index in picker.selected {
			if selected {
				append(&chosen, index)
			}
		}

		if len(chosen) == 0 {
			return chosen, fail(env, "nothing was chosen")
		}
		assert(len(chosen) <= len(items))
		return chosen, true
	}

	picker_clear(env, lines)
	return chosen, fail(env, "too many keys; nothing was chosen")
}

// Initializes `picker` in place with nothing selected and an empty query.
picker_init :: proc(picker: ^Picker, items: []Picker_Item) {
	picker^ = Picker {
		items    = items,
		selected = make([]bool, len(items)),
	}
	picker_filter(picker)
	assert(len(picker.visible) == len(items))
	assert(picker.cursor == 0)
}

// A case-insensitive subsequence match of `query` in `text`; higher scores
// are better. Consecutive matches, a match at the start and a match after a
// word separator score up; every text byte skipped between matches scores
// down.
fuzzy_score :: proc(query, text: string) -> (score: int, matched: bool) {
	if len(query) == 0 {
		return 0, true
	}

	query_index := 0
	previous := -1
	for text_index in 0 ..< len(text) {
		if query_index == len(query) {
			break
		}

		if ascii_lower(text[text_index]) != ascii_lower(query[query_index]) {
			continue
		}

		if previous < 0 {
			if text_index == 0 {
				score += 8
			}
		} else {
			if text_index == previous + 1 {
				score += 10
			} else {
				score -= text_index - previous - 1
			}
		}

		if text_index > 0 {
			switch text[text_index - 1] {
			case '_', '-', '/':
				score += 5
			}
		}

		previous = text_index
		query_index += 1
	}

	assert(query_index <= len(query))
	if query_index < len(query) {
		return 0, false
	}
	return score, true
}

@(private = "file")
ascii_lower :: proc(character: u8) -> u8 {
	if character >= 'A' && character <= 'Z' {
		return character + ('a' - 'A')
	}
	return character
}

// Rebuilds `visible` from the items whose label matches the query: best
// score first, then by label, then by index. Clamps the cursor.
picker_filter :: proc(picker: ^Picker) {
	Scored :: struct {
		score: int,
		label: string,
		index: int,
	}

	query := string(picker.query[:])
	scored := make([dynamic]Scored, context.temp_allocator)
	for item, index in picker.items {
		score, matched := fuzzy_score(query, item.label)
		if matched {
			append(&scored, Scored{score = score, label = item.label, index = index})
		}
	}

	slice.sort_by(scored[:], proc(a, b: Scored) -> bool {
		if a.score != b.score {
			return a.score > b.score
		}

		if a.label != b.label {
			return a.label < b.label
		}
		return a.index < b.index
	})

	clear(&picker.visible)
	for entry in scored {
		append(&picker.visible, entry.index)
	}

	if len(picker.visible) == 0 {
		picker.cursor = 0
	} else {
		picker.cursor = clamp(picker.cursor, 0, len(picker.visible) - 1)
	}
	assert(len(picker.visible) <= len(picker.items))
	assert(picker.cursor >= 0)
}

// Applies one key. `done` ends the picker; `cancelled` means without a choice.
picker_apply :: proc(picker: ^Picker, key: Picker_Key, char: u8) -> (done, cancelled: bool) {
	assert(len(picker.selected) == len(picker.items))

	switch key {
	case .None:
	case .Char:
		assert(char >= 0x21 && char <= 0x7e)
		append(&picker.query, char)
		picker_filter(picker)
	case .Backspace:
		if len(picker.query) > 0 {
			pop(&picker.query)
			picker_filter(picker)
		}
	case .Up:
		if picker.cursor > 0 {
			picker.cursor -= 1
		}
	case .Down:
		if picker.cursor + 1 < len(picker.visible) {
			picker.cursor += 1
		}
	case .Toggle:
		if picker.cursor < len(picker.visible) {
			index := picker.visible[picker.cursor]
			picker.selected[index] = !picker.selected[index]
			if picker.cursor + 1 < len(picker.visible) {
				picker.cursor += 1
			}
		}
	case .Toggle_All:
		all := true
		for index in picker.visible {
			all &&= picker.selected[index]
		}
		for index in picker.visible {
			picker.selected[index] = !all
		}
	case .Enter:
		if !slice.contains(picker.selected, true) && picker.cursor < len(picker.visible) {
			picker.selected[picker.visible[picker.cursor]] = true
		}
		return true, false
	case .Cancel:
		return true, true
	}

	if len(picker.visible) > 0 {
		assert(picker.cursor < len(picker.visible))
	}
	return false, false
}

// Reads one key from env.input: one byte, or more for an escape sequence.
// `ended` is true when the input ended or could not be read.
picker_read_key :: proc(env: ^Env) -> (key: Picker_Key, char: u8, ended: bool) {
	first, read := picker_read_byte(env)
	if !read {
		return .None, 0, true
	}

	switch first {
	case '\r', '\n':
		return .Enter, 0, false
	case 0x7f, 0x08:
		return .Backspace, 0, false
	case '\t', ' ':
		return .Toggle, 0, false // package names never contain spaces
	case 0x01:
		return .Toggle_All, 0, false
	case 0x10:
		return .Up, 0, false
	case 0x0e:
		return .Down, 0, false
	case 0x03, 0x07:
		return .Cancel, 0, false
	case 0x1b:
		return picker_read_escape(env)
	case 0x21 ..= 0x7e:
		return .Char, first, false
	}
	return .None, 0, false
}

// After Esc: `[A` and `[B`, or `OA` and `OB`, are the arrow keys. A lone
// Esc cancels, but only once the next byte arrives, since reads have no
// timeout.
@(private = "file")
picker_read_escape :: proc(env: ^Env) -> (key: Picker_Key, char: u8, ended: bool) {
	second, read := picker_read_byte(env)
	if !read {
		return .Cancel, 0, false
	}

	// `ESC [` is normal cursor mode; `ESC O` is application cursor mode,
	// which some terminals and shells leave on.
	switch second {
	case '[', 'O':
	case:
		return .Cancel, 0, false
	}

	third, third_read := picker_read_byte(env)
	if !third_read {
		return .None, 0, true
	}

	switch third {
	case 'A':
		return .Up, 0, false
	case 'B':
		return .Down, 0, false
	}
	return .None, 0, false
}

// Reads exactly one byte, so whatever follows stays in env.input for the
// next reader, such as a confirmation.
@(private = "file")
picker_read_byte :: proc(env: ^Env) -> (character: u8, read: bool) {
	buffer: [1]u8
	count, err := io.read(env.input, buffer[:])
	if err != nil || count == 0 {
		return 0, false
	}
	assert(count == 1)
	return buffer[0], true
}

// Writes one frame and returns how many lines it took. In a terminal it first
// moves up over the previous frame and clears it.
picker_render :: proc(env: ^Env, picker: ^Picker, title: string, previous_lines: int) -> int {
	assert(previous_lines >= 0)

	builder := strings.builder_make(context.temp_allocator)
	if env.style.stdout {
		if previous_lines > 0 {
			fmt.sbprintf(&builder, "\x1b[%dA", previous_lines)
		}
		strings.write_string(&builder, "\r\x1b[J")
	}

	// A query too long to fit shows its end, where the typing happens.
	query := string(picker.query[:])
	room := PICKER_WIDTH_MAX - len(title) - 2
	if len(query) > room {
		query = strings.concatenate({"…", query[len(query) - room:]}, context.temp_allocator)
	}
	fmt.sbprintf(&builder, "%s %s\n", title, query)
	lines := 1

	if len(picker.visible) == 0 {
		fmt.sbprintf(&builder, "  %v\n", paint(env, ANSI_DIM, "no match"))
		lines += 1
	}

	// Scrolled so that the cursor row is always in view.
	top := max(0, picker.cursor - (PICKER_ROWS_MAX - 1))
	bottom := min(len(picker.visible), top + PICKER_ROWS_MAX)
	for row in top ..< bottom {
		item := picker.items[picker.visible[row]]
		marker := "> " if row == picker.cursor else "  "
		mark := paint(env, ANSI_GREEN, "[x]") if picker.selected[picker.visible[row]] else paint(env, ANSI_DIM, "[ ]")
		label, detail, cut := picker_fit(printable(item.label), printable(item.detail), PICKER_WIDTH_MAX - PICKER_ROW_PREFIX_WIDTH)
		fmt.sbprintf(&builder, "%s%v %s %v%s\n", marker, mark, label, paint(env, ANSI_DIM, detail), "…" if cut else "")
		lines += 1
	}

	fmt.sbprintf(&builder, "%v\n", paint(env, ANSI_DIM, PICKER_HINT))
	lines += 1

	fmt.wprint(env.out, strings.to_string(builder), sep = "")
	assert(lines >= 3)
	assert(lines <= PICKER_ROWS_MAX + 2)
	return lines
}

// Cuts `detail` and then `label` so that the row text `label detail`, plus a
// closing `…` when anything was cut, takes at most `width` columns (one per
// rune). The space after the label is always written.
picker_fit :: proc(label, detail: string, width: int) -> (label_shown, detail_shown: string, cut: bool) {
	assert(width > 2)

	label_width := utf8.rune_count_in_string(label)
	detail_width := utf8.rune_count_in_string(detail)
	if label_width + 1 + detail_width <= width {
		return label, detail, false
	}

	// Room for the space and the `…`.
	if label_width > width - 2 {
		return picker_cut(label, width - 2), "", true
	}

	detail_shown = picker_cut(detail, width - 2 - label_width)
	assert(utf8.rune_count_in_string(detail_shown) < detail_width)
	return label, detail_shown, true
}

// The first `count` runes of `text`.
@(private = "file")
picker_cut :: proc(text: string, count: int) -> string {
	assert(count >= 0)

	runes := 0
	for _, offset in text {
		if runes == count {
			return text[:offset]
		}
		runes += 1
	}
	return text
}

// Removes the last frame, in a terminal, so the output that follows starts
// where the picker did.
@(private = "file")
picker_clear :: proc(env: ^Env, lines: int) {
	assert(lines >= 0)
	if !env.style.stdout {
		return
	}

	if lines > 0 {
		fmt.wprintf(env.out, "\x1b[%dA", lines)
	}
	fmt.wprint(env.out, "\r\x1b[J", sep = "")
}

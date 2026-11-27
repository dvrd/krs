package main

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
fingerprint_round_trips_and_names_changes :: proc(t: ^testing.T) {
	previous := make(Fingerprint)
	previous["version"] = "v0.2.3"
	previous["src/a.odin"] = "aa"
	previous["src/gone.odin"] = "gg"

	parsed := fingerprint_parse(fingerprint_text(previous))
	testing.expect_value(t, len(fingerprint_changes(previous, parsed)), 0)

	current := make(Fingerprint)
	current["version"] = "v0.2.4"
	current["src/a.odin"] = "aa"
	current["src/new.odin"] = "nn"
	changes := fingerprint_changes(previous, current)
	testing.expect_value(t, len(changes), 3)
	testing.expect_value(t, changes_text(changes, true), "src/gone.odin, src/new.odin, the version changed")
	testing.expect_value(t, changes_text(changes[:1], true), "src/gone.odin changed")
	testing.expect_value(t, changes_text({}, false), "no previous build")
	testing.expect_value(t, changes_text({"a", "b", "c", "d", "e"}, true), "a, b, c and 2 more changed")
}

@(test)
fingerprint_directory_covers_nested_files :: proc(t: ^testing.T) {
	temporary, _ := os.temp_directory(context.temp_allocator)
	base, err := os.make_directory_temp(temporary, "krs-dev-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(base)

	os.make_directory_all(fmt.tprintf("%s/deep/er", base))
	_ = os.write_entire_file(fmt.tprintf("%s/top.odin", base), "package x\n")
	_ = os.write_entire_file(fmt.tprintf("%s/deep/er/data.bin", base), "loaded")

	fingerprint := make(Fingerprint)
	count := 0
	testing.expect(t, fingerprint_directory(&fingerprint, base, "pkg", &count))
	testing.expect_value(t, count, 2)
	testing.expect(t, "pkg/top.odin" in fingerprint)
	testing.expect(t, "pkg/deep/er/data.bin" in fingerprint)

	before := fingerprint["pkg/deep/er/data.bin"]
	_ = os.write_entire_file(fmt.tprintf("%s/deep/er/data.bin", base), "changed")
	count = 0
	testing.expect(t, fingerprint_directory(&fingerprint, base, "pkg", &count))
	testing.expect(t, fingerprint["pkg/deep/er/data.bin"] != before)

	missing := make(Fingerprint)
	testing.expect(t, !fingerprint_directory(&missing, fmt.tprintf("%s/absent", base), "pkg", &count))
}

package main

import "core:testing"
import "core:time"

@(test)
timings_summary_names_the_phases :: proc(t: ^testing.T) {
	output := `Total Time        - 23192.772 ms - 100.00%
initialization    -     2.733 ms -   0.01%
parse files       -    28.824 ms -   0.12%
type check        -    66.742 ms -   0.28%
LLVM API Code Gen - 22890.019 ms -  98.69%
ld-link           -   204.438 ms -   0.88%
`
	testing.expect_value(t, timings_summary(output, {"parse files", "type check"}), "parsing 28ms, type checking 66ms")
	testing.expect_value(t, timings_summary(output, {"LLVM API Code Gen", "ld-link"}), "code generation 22.9s, linking 204ms")
	testing.expect_value(t, timings_summary("no table here\n", {"ld-link"}), "")
}

@(test)
duration_text_scales_its_unit :: proc(t: ^testing.T) {
	testing.expect_value(t, duration_text(45 * time.Millisecond), "45ms")
	testing.expect_value(t, duration_text(1200 * time.Millisecond), "1.2s")
	testing.expect_value(t, duration_text(65 * time.Second), "1m05s")
}

@(test)
link_flags_add_an_rpath_off_macos :: proc(t: ^testing.T) {
	testing.expect_value(t, link_flags("/opt/lib", true), `-L"/opt/lib"`)
	testing.expect_value(t, link_flags("/usr/lib", false), `-L"/usr/lib" -Wl,-rpath,/usr/lib`)
}

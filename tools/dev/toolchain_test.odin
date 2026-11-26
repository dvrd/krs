package main

import "core:testing"

@(test)
toolchain_versions_match_by_date_and_hash_prefix :: proc(t: ^testing.T) {
	full := "dev-2026-11:54322e177abcdef0123456789abcdef012345678"
	cases := [?]struct {
		actual, expected: string,
		matches:         bool,
	} {
		{"dev-2026-11:54322e177", "dev-2026-11:54322e177", true},
		{"dev-2026-11:54322e177", full, true},
		{full, "dev-2026-11:54322e177", true},
		{"dev-2026-11", full, false},
		{full, "dev-2026-11", false},
		{"dev-2026-11:", full, false},
		{"dev-2026-10:54322e177", full, false},
		{"dev-2026-11:deadbeef0", full, false},
		{"dev-2026-11:54322e177\n", "dev-2026-11:54322e177", true},
		{"dev-2026-11:54322e177", "dev-2026-11:54322e177\n", true},
	}
	for example in cases {
		testing.expect_value(t, toolchain_matches(example.actual, example.expected), example.matches)
	}
}

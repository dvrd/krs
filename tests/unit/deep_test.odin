package unit

import "core:testing"

import krs "../../src"

@(test)
package_file_patterns_match :: proc(t: ^testing.T) {
	Case :: struct {
		pattern:  string,
		lockfile: string,
		matches:  bool,
	}
	cases := []Case {
		{"**/.krs/packages.json", "a/b/.krs/packages.json", true},
		{".krs/packages.json", ".krs/packages.json", true},
		{"tools/*", "tools/gen/.krs/packages.json", true},
		{"tools/*", "tools/gen/sub/.krs/packages.json", false},
		{"tools/gen", "tools/gen/.krs/packages.json", true},
		{"x", ".krs/packages.json", false},
		{".", ".krs/packages.json", true},
		{"**", ".krs/packages.json", true},
		{"./tools/gen", "tools/gen/.krs/packages.json", true},
	}
	for entry in cases {
		testing.expectf(t, krs.package_file_matches(entry.pattern, entry.lockfile) == entry.matches, "%s against %s", entry.pattern, entry.lockfile)
	}
}

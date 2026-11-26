package unit

import "core:testing"

import krs "../../src"

@(test)
tag_form :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	version, ok := krs.parse_tag("v1.20.3")
	testing.expect(t, ok)
	testing.expect_value(t, version, krs.Version{1, 20, 3})

	for bad in ([]string{"1.2.3", "v1.2", "v1.2.3.4", "v1.2.x", "v01.2.3", "v1.2.3-rc1", "v", ""}) {
		_, bad_ok := krs.parse_tag(bad)
		testing.expectf(t, !bad_ok, "%s should not be a release tag", bad)
	}
}

@(test)
version_rules :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	testing.expect_value(t, krs.version_compatibility({0, 4, 0}, {0, 4, 9}), .Compatible)
	testing.expect_value(t, krs.version_compatibility({0, 4, 0}, {0, 5, 0}), .Breaking)
	testing.expect_value(t, krs.version_compatibility({1, 0, 0}, {1, 9, 0}), .Compatible)
	testing.expect_value(t, krs.version_compatibility({1, 0, 0}, {2, 0, 0}), .Breaking)
	testing.expect_value(t, krs.version_compare({0, 10, 0}, {0, 9, 9}), .Higher)
	testing.expect_value(t, krs.version_compare({1, 0, 0}, {1, 0, 0}), .Equal)
	testing.expect_value(t, krs.version_compare({1, 0, 0}, {2, 0, 0}), .Lower)

	highest, ok := krs.highest_tag({"v0.9.0", "v0.10.0", "nightly", "v0.2.11"})
	testing.expect(t, ok)
	testing.expect_value(t, highest, "v0.10.0")
}

@(test)
version_bumps_reset_lower_components :: proc(t: ^testing.T) {
	version := krs.Version{0, 4, 9}
	patch, patch_ok := krs.version_bump(version, .Patch)
	minor, minor_ok := krs.version_bump(version, .Minor)
	major, major_ok := krs.version_bump(version, .Major)
	testing.expect(t, patch_ok && minor_ok && major_ok)
	testing.expect_value(t, patch, krs.Version{0, 4, 10})
	testing.expect_value(t, minor, krs.Version{0, 5, 0})
	testing.expect_value(t, major, krs.Version{1, 0, 0})

	limit := krs.VERSION_COMPONENT_MAX
	for part in krs.Version_Bump {
		_, ok := krs.version_bump({limit, limit, limit}, part)
		testing.expectf(t, !ok, "a %v bump must stay within the supported tag format", part)
	}
}

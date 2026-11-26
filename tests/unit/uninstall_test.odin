package unit

import "core:os"
import "core:testing"

import krs "../../src"
import "../fixtures"

// packages_remove drops only the named record, in place, and ignores a name
// the file does not hold.
@(test)
packages_remove_drops_only_the_named_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	file := krs.Packages_File{format = krs.FORMAT}
	append(&file.packages, krs.Package_Record{name = "alpha", tag = "v1.0.0"})
	append(&file.packages, krs.Package_Record{name = "beta", tag = "v0.1.0", pinned = true})
	append(&file.packages, krs.Package_Record{name = "gamma", tag = "v2.0.0"})

	krs.packages_remove(&file, "beta")
	testing.expect_value(t, len(file.packages), 2)
	testing.expect(t, krs.packages_find(&file, "beta") == nil)
	testing.expect_value(t, file.packages[0].name, "alpha")
	testing.expect_value(t, file.packages[1].name, "gamma")
	testing.expect_value(t, file.packages[1].tag, "v2.0.0")

	krs.packages_remove(&file, "nope")
	testing.expect_value(t, len(file.packages), 2)
	testing.expect_value(t, file.packages[0].name, "alpha")
	testing.expect_value(t, file.packages[1].name, "gamma")
}

// The picker shows the tag, then whether the package is pinned or linked.
@(test)
uninstall_pick_detail_lists_tag_and_flags :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, krs.uninstall_pick_detail("v1.0.0", false, false), "v1.0.0")
	testing.expect_value(t, krs.uninstall_pick_detail("v1.0.0", true, false), "v1.0.0 pinned")
	testing.expect_value(t, krs.uninstall_pick_detail("v1.0.0", false, true), "v1.0.0 linked")
	testing.expect_value(t, krs.uninstall_pick_detail("v1.0.0", true, true), "v1.0.0 pinned linked")
}

// The project's own files that import shared:beta (directly or a
// subpackage), and not those under a krs vendor/ or importing another name.
@(test)
uninstall_importers_lists_the_project_files :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	temporary, _ := os.temp_directory(context.allocator)
	project, err := os.make_directory_temp(temporary, "krs-uninstall-*", context.allocator)
	testing.expect_value(t, err, nil)
	defer os.remove_all(project)

	fixtures.write_file(t, krs.path_join(project, "a.odin"), "package app\n\nimport \"shared:beta\"\n")
	fixtures.write_file(t, krs.path_join(project, "sub/b.odin"), "package sub\n\nimport b \"shared:beta/inner\"\n")
	fixtures.write_file(t, krs.path_join(project, "c.odin"), "package app\n\nimport \"shared:gamma\"\n")
	fixtures.write_file(t, krs.path_join(project, "vendor/x.odin"), "package x\n\nimport \"shared:beta\"\n")
	fixtures.write_file(t, krs.path_join(krs.path_join(project, "vendor"), krs.MANIFEST_PATH), "{\"format\": 1, \"packages\": []}\n")

	importers, ok := krs.uninstall_importers(project, "beta")
	testing.expect(t, ok)
	testing.expect_value(t, len(importers), 2)
	if len(importers) == 2 {
		testing.expect_value(t, importers[0], "a.odin")
		testing.expect_value(t, importers[1], "sub/b.odin")
	}

	none, none_ok := krs.uninstall_importers(project, "delta")
	testing.expect(t, none_ok)
	testing.expect_value(t, len(none), 0)
}

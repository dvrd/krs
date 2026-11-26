package unit

import "core:testing"

import krs "../../src"

@(test)
journal_accepts_vendor_paths_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	scope := krs.Journal_Scope{project = "/p", root = "/r"}

	change :: proc(target: string) -> krs.Journal_Change {
		directory := krs.path_join(krs.path_directory(target), ".krs-stage-abc")
		return {target = target, directory = directory, staging = {device = 1, inode = 1}}
	}

	for target in ([]string{"/p/vendor/beta", "/p/vendor/.krs/manifest.json", "/r/shared/beta"}) {
		testing.expectf(t, krs.journal_change_valid(scope, change(target)), "%s should be valid", target)
	}

	for target in ([]string{"/p/vendor/beta/inner", "/p/other/beta", "/p/vendor", "/q/vendor/beta"}) {
		testing.expectf(t, !krs.journal_change_valid(scope, change(target)), "%s should be invalid", target)
	}
}

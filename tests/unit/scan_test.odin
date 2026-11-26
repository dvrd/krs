package unit

import "core:slice"
import "core:testing"

import krs "../../src"

@(test)
scan_reads_imports_and_file_references :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	source := `package demo

import "core:fmt"
import http "shared:http/v2"
import "shared:saba"
// import "shared:commented"
/* import "shared:blocked" /* nested */ import "shared:nested" */

NOTE :: "import \"shared:quoted\" #load(\"quoted.js\")"
RAW :: ` + "`#load(\"raw.js\")`" + `
QUOTE :: '"'

RUNTIME :: #load("modules/dom.js", string)
DIGEST :: #load_hash("modules/dom.js", "sha256")
ASSETS :: #load_directory("assets")
DYNAMIC :: #load(NAME)

when ODIN_OS == .Darwin {
	foreign import lib "native/lib.a"
} else {
	foreign import lib {
		"native/other.a",
		"system:m",
	}
}
`
	result := krs.scan_source(source)

	testing.expect_value(t, len(result.shared_imports), 2)
	testing.expect_value(t, result.shared_imports[0], "http")
	testing.expect_value(t, result.shared_imports[1], "saba")

	testing.expect_value(t, len(result.file_refs), 3)
	testing.expect_value(t, result.file_refs[0], "modules/dom.js")
	testing.expect_value(t, result.file_refs[1], "native/lib.a")
	testing.expect_value(t, result.file_refs[2], "native/other.a")

	testing.expect_value(t, len(result.directory_refs), 1)
	testing.expect_value(t, result.directory_refs[0], "assets")
	testing.expect_value(t, len(result.unresolved), 1)
}

@(test)
scanner_decodes_escapes_and_rejects_computed_load_paths :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	result := krs.scan_source(`package demo
import "shared:\x62eta"
DATA :: #load("asset\x20file.txt", string)
COMPUTED :: #load("assets/" + NAME, string)
`)
	testing.expect(t, slice.equal(result.shared_imports[:], []string{"beta"}))
	testing.expect(t, slice.equal(result.file_refs[:], []string{"asset file.txt"}))
	testing.expect(t, slice.equal(result.unresolved[:], []string{"load"}))
}

@(test)
scan_reads_triple_quoted_strings_as_one_literal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	source := `package demo

DOC :: """
	import "shared:fake_one"
	#load("fake.txt")
	/* never closed
	an escaped \""" does not close it
"""
` + "```" + `
	import "shared:fake_two"
	#load_directory("fake_dir")
` + "```" + `
X :: ""
import "shared:after_empty"
import "shared:real"
DATA :: #load("real.txt", string)
`
	result := krs.scan_source(source)
	testing.expect(t, slice.equal(result.shared_imports[:], []string{"after_empty", "real"}))
	testing.expect(t, slice.equal(result.file_refs[:], []string{"real.txt"}))
	testing.expect_value(t, len(result.directory_refs), 0)
	testing.expect_value(t, len(result.unresolved), 0)
}

@(test)
scan_decodes_triple_quoted_import_path :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	result := krs.scan_source(`package demo
import """shared:tripled"""
`)
	testing.expect(t, slice.equal(result.shared_imports[:], []string{"tripled"}))
}

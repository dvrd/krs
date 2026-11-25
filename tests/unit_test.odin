package tests

import "core:slice"
import "core:strings"
import "core:testing"

import krs "../src"

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
tree_names_reject_git_metadata_and_controls :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// "‌" is ZERO WIDTH NON-JOINER, which some filesystems ignore.
	for bad in ([]string{".git", ".GIT", ".Git", ".g‌it", "a\x1bb", "", ".", ".."}) {
		testing.expectf(t, krs.git_tree_name_problem(bad) != "", "%q should be refused", bad)
	}

	for good in ([]string{".github", "git", "x.odin"}) {
		testing.expectf(t, krs.git_tree_name_problem(good) == "", "%q should be allowed", good)
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
relative_paths_cannot_escape :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	cleaned, ok := krs.path_clean_relative("src/a/../b/./c.js")
	testing.expect(t, ok)
	testing.expect_value(t, cleaned, "src/b/c.js")

	_, escaped := krs.path_clean_relative("src/../../etc/passwd")
	testing.expect(t, !escaped)
	_, absolute := krs.path_clean_relative("/etc/passwd")
	testing.expect(t, !absolute)

	testing.expect(t, krs.is_package_name("saba"))
	testing.expect(t, krs.is_package_name("odin-http_2"))
	testing.expect(t, !krs.is_package_name(".."))
	testing.expect(t, !krs.is_package_name("a/b"))
	testing.expect(t, !krs.is_package_name(""))
}

@(test)
source_never_carries_credentials :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	testing.expect_value(t, krs.strip_credentials("https://user:token@github.com/o/r.git"), "https://github.com/o/r.git")
	testing.expect_value(t, krs.strip_credentials("https://github.com/o/r.git"), "https://github.com/o/r.git")
	testing.expect_value(t, krs.strip_credentials("git@github.com:o/r.git"), "git@github.com:o/r.git")
	testing.expect_value(t, krs.source_identity("https://user:token@github.com/o/r.git?token=second#secret"), "https://github.com/o/r.git")
	testing.expect_value(t, krs.source_identity("file:///some/local/repo.git"), "local")
}

@(test)
ssh_github_origins_share_the_https_identity :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	testing.expect_value(t, krs.source_identity("git@github.com:Owner/Repo.git"), "https://github.com/owner/repo.git")
	testing.expect_value(t, krs.source_identity("git@github.com:owner/repo"), "https://github.com/owner/repo.git")
	testing.expect_value(t, krs.source_identity("ssh://git@github.com/owner/repo.git"), "https://github.com/owner/repo.git")
	testing.expect_value(t, krs.source_identity("ssh://git@github.com:22/owner/repo.git"), "https://github.com/owner/repo.git")
	// Not GitHub: unchanged.
	testing.expect_value(t, krs.source_identity("git@gitlab.com:o/r.git"), "git@gitlab.com:o/r.git")
	// Malformed GitHub SSH address: unchanged, never a wrong repository.
	testing.expect_value(t, krs.source_identity("git@github.com:onlyowner"), "git@github.com:onlyowner")
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

@(test)
output_highlights_string_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	V :: krs.ANSI_VALUE
	R :: krs.ANSI_RESET
	testing.expect_value(t, krs.highlight("%s is at %s", false), "%s is at %s")
	testing.expect_value(t, krs.highlight("%s is at %s", true), V + "%s" + R + " is at " + V + "%s" + R)
	testing.expect_value(t, krs.highlight("%v, %d, 100%% and %-8s", true), "%v, %d, 100%% and " + V + "%-8s" + R)
	testing.expect_value(t, krs.highlight("trailing %", true), "trailing %")

	out := strings.builder_make()
	env := krs.Env {
		out   = strings.to_writer(&out),
		style = {stdout = true, color = true},
	}
	krs.warn(&env, "%s is %v", "alpha", "stale")
	testing.expect_value(
		t,
		strings.to_string(out),
		krs.ANSI_YELLOW + "\uf071" + R + "  " + krs.ANSI_YELLOW + "warning:" + R + " " + V + "alpha" + R + " is stale\n",
	)

	strings.builder_reset(&out)
	env.style = {}
	krs.warn(&env, "%s is %v", "alpha", "stale")
	testing.expect_value(t, strings.to_string(out), "warning: alpha is stale\n")
}

@(test)
printable_escapes_control_characters :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	testing.expect_value(t, krs.printable("plain/path.odin"), "plain/path.odin")
	testing.expect_value(t, krs.printable("café"), "café")
	testing.expect_value(t, krs.printable("a\x1b[2Jb"), "a\\x1B[2Jb")
	testing.expect_value(t, krs.printable("tab\there"), "tab\there")
	testing.expect_value(t, krs.printable("line\nbreak"), "line\\x0Abreak")
	testing.expect_value(t, krs.printable("a\u009bb"), "a\\x9Bb")
	testing.expect_value(t, krs.printable("\xff"), "\\xFF")
	testing.expect_value(t, krs.printable("a‮b"), "a\\u{202E}b")

	out := strings.builder_make()
	env := krs.Env {
		out   = strings.to_writer(&out),
		style = {stdout = true, color = true},
	}
	painted := krs.paint(&env, krs.ANSI_GREEN, "ok")
	krs.warn(&env, "%s then %v", "bad\x1b[2J", painted)
	text := strings.to_string(out)
	testing.expect(t, strings.contains(text, "bad\\x1B[2J"))
	testing.expect(t, !strings.contains(text, "bad\x1b"))
	testing.expect(t, strings.contains(text, krs.ANSI_GREEN + "ok" + krs.ANSI_RESET))
}

@(test)
cooldown_periods_parse :: proc(t: ^testing.T) {
	for text in ([]string{"7", "7d"}) {
		seconds, ok := krs.cooldown_seconds(text)
		testing.expect(t, ok)
		testing.expect_value(t, seconds, 604800)
	}

	seconds, ok := krs.cooldown_seconds("12h")
	testing.expect(t, ok)
	testing.expect_value(t, seconds, 43200)
	seconds, ok = krs.cooldown_seconds("30m")
	testing.expect(t, ok)
	testing.expect_value(t, seconds, 1800)

	for text in ([]string{"0", "", "d", "7x", "99999", "87601h", "-7", "+7", "0x7", "7D"}) {
		_, valid := krs.cooldown_seconds(text)
		testing.expectf(t, !valid, "%q should be rejected", text)
	}
}

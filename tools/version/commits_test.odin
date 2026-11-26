package main

import "core:testing"

import krs "../../src"

@(test)
commit_messages_report_release_impact :: proc(t: ^testing.T) {
	cases := [?]struct { message: string, impact: Release_Impact } {
		{"fix: read the cached version", .Fix},
		{"Feat(cli): add a command", .Feature},
		{"feat!: remove a command", .Breaking},
		{"refactor(config)!: change the format", .Breaking},
		{"fix: update an option\n\nBREAKING CHANGE: the default changed", .Breaking},
		{"chore: migrate\r\n\r\nRefs #42\r\nBREAKING-CHANGE: drop legacy config", .Breaking},
		{"docs: clarify errors\n\nSee the example below:\nBREAKING CHANGE: demo", .None},
		{"fix: adjust examples\n\n    BREAKING CHANGE: quoted example", .Fix},
		{"docs: update the release notes", .None},
		{"chore(release): v0.2.0", .None},
		{"Merge branch 'feature'", .None},
		{"fix:missing space", .None},
		{"fix(): missing scope", .None},
		{"fix: ", .None},
	}
	for example in cases {
		testing.expect_value(t, commit_impact(example.message), example.impact)
	}
}

@(test)
git_log_uses_the_highest_impact :: proc(t: ^testing.T) {
	testing.expect_value(t, release_impact(""), .None)
	testing.expect_value(t, release_impact("docs: example\n\x00chore: bump\n\x00"), .None)
	testing.expect_value(t, release_impact("feat: add\n\x00fix: adjust\n\x00"), .Feature)
	messages := "fix: adjust\n\x00feat: add\n\x00refactor!: remove\n\x00"
	testing.expect_value(t, release_impact(messages), .Breaking)
}

@(test)
release_bumps_follow_the_version_series :: proc(t: ^testing.T) {
	pre_stable := krs.Version{0, 3, 8}
	stable := krs.Version{1, 3, 8}
	testing.expect_value(t, release_bump(pre_stable, .Fix), .Patch)
	testing.expect_value(t, release_bump(pre_stable, .Feature), .Patch)
	testing.expect_value(t, release_bump(pre_stable, .Breaking), .Minor)
	testing.expect_value(t, release_bump(stable, .Fix), .Patch)
	testing.expect_value(t, release_bump(stable, .Feature), .Minor)
	testing.expect_value(t, release_bump(stable, .Breaking), .Major)
}

@(test)
release_notes_group_commits_by_kind :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	log :=
		"aaa1111\nfeat(update): add --target\n\x00" +
		"bbb2222\nfix: stop the test command\n\x00" +
		"ccc3333\nfeat!: drop the old flag\n\x00" +
		"ddd4444\nfeat(cli)!: rename commands\n\nLonger body.\n\n" +
		"BREAKING CHANGE: `krs up` is now `krs update`\nand `krs ls` is gone\nRefs #12\n\x00" +
		"eee5555\nrefactor(config): change the format\n\nBREAKING-CHANGE: config.json needs format 2\n\x00" +
		"fff6666\nperf(install): hash files once\n\x00" +
		"abc7777\ndocs: explain releases\n\x00" +
		"abc8888\nUpdate the readme\n\x00" +
		"abc9999\nchore(release): v0.1.0\n\x00" +
		"abc0000\nci(release): publish binaries\n\x00"
	expected :=
		"## Breaking changes\n\n" +
		"- drop the old flag (ccc3333)\n" +
		"- **cli:** rename commands (ddd4444)\n" +
		"  `krs up` is now `krs update`\n" +
		"  and `krs ls` is gone\n" +
		"- **config:** change the format (eee5555)\n" +
		"  config.json needs format 2\n\n" +
		"## Features\n\n" +
		"- **update:** add --target (aaa1111)\n\n" +
		"## Fixes\n\n" +
		"- stop the test command (bbb2222)\n\n" +
		"## Performance\n\n" +
		"- **install:** hash files once (fff6666)\n\n" +
		"## Other changes\n\n" +
		"- explain releases (docs) (abc7777)\n" +
		"- Update the readme (abc8888)\n" +
		"- **release:** publish binaries (ci) (abc0000)\n\n" +
		"The macOS binary requires libgit2: `brew install libgit2`.\n\n" +
		"**Full changelog**: https://github.com/dvrd/krs/compare/v0.1.0...v0.2.0\n"
	testing.expect_value(t, release_notes(log, "v0.1.0", "v0.2.0", "dvrd/krs"), expected)
}

@(test)
release_notes_omit_empty_sections :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	expected :=
		"## Fixes\n\n" +
		"- **doctor:** stop on timeout (1234567)\n\n" +
		"The macOS binary requires libgit2: `brew install libgit2`.\n\n" +
		"**Full changelog**: https://github.com/someone/fork/compare/v1.2.3...v1.2.4\n"
	log := "1234567\nfix(doctor): stop on timeout\n"
	testing.expect_value(t, release_notes(log, "v1.2.3", "v1.2.4", "someone/fork"), expected)

	trailer :=
		"The macOS binary requires libgit2: `brew install libgit2`.\n\n" +
		"**Full changelog**: https://github.com/dvrd/krs/compare/v0.1.0...v0.1.1\n"
	testing.expect_value(t, release_notes("", "v0.1.0", "v0.1.1", "dvrd/krs"), trailer)
	only_release := "abc9999\nchore(release): v0.1.0\n\x00"
	testing.expect_value(t, release_notes(only_release, "v0.1.0", "v0.1.1", "dvrd/krs"), trailer)
}

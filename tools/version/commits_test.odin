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

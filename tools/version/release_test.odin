package main

import "core:testing"

@(test)
dist_must_not_contain_the_checkout :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	top := "/a/krs"
	cases := [?]struct {
		dist:   string,
		ok:     bool,
		reason: string,
	} {
		{"/a/krs", false, "refusing to use /a/krs: it contains the checkout"},
		{"/a", false, "refusing to use /a: it contains the checkout"},
		{"/", false, "refusing to use /"},
		{"/a/dist", true, ""},
		{"/a/krs2", true, ""},
		{"/a/krs/dist", true, ""},
	}
	for example in cases {
		ok, reason := dist_is_safe(example.dist, top)
		testing.expect_value(t, ok, example.ok)
		testing.expect_value(t, reason, example.reason)
	}
}

@(test)
asset_names_follow_uname :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, asset_name("v0.3.0", "Darwin", "arm64"), "krs-v0.3.0-darwin-arm64.tar.gz")
	testing.expect_value(t, asset_name("v1.2.3", "Linux", "x86_64"), "krs-v1.2.3-linux-amd64.tar.gz")
}

@(test)
checksum_lines_match_shasum :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	expected := "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  krs.tar.gz\n"
	testing.expect_value(t, sha256_line(transmute([]byte)string("abc"), "krs.tar.gz"), expected)
}

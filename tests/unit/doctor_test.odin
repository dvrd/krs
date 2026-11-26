package unit

import "core:testing"

import krs "../../src"

@(test)
doctor_recovery_quotes_paths :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	testing.expect_value(t, krs.shell_quote("/a b/it's"), "'/a b/it'\\''s'")
	testing.expect_value(t, krs.shell_quote("/plain"), "'/plain'")
}

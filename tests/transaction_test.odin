package tests

import "core:os"
import "core:strings"
import "core:testing"
import db "shared:kakunou"

import krs "../src"

@(test)
publication_preflight_preserves_previous_paths :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixture_make(t)
	defer fixture_destroy(&fixture)

	output := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&output)}
	project, _ := os.get_absolute_path(fixture.project, context.allocator)
	root, _ := os.get_absolute_path(fixture.root, context.allocator)
	transaction := krs.Transaction{env = &env, scope = {project, root}}
	defer krs.transaction_close(&transaction)

	shared := krs.path_join(root, "shared")
	manifest := krs.path_join(shared, krs.MANIFEST_PATH)
	write_file(t, manifest, "previous manifest")
	first, first_ok := krs.transaction_stage(&transaction, manifest, .Record)
	if !testing.expect(t, first_ok) {
		return
	}
	write_file(t, first.staged, "new manifest")

	occupied := krs.path_join(shared, "beta")
	second, second_ok := krs.transaction_stage(&transaction, occupied, .New)
	if !testing.expect(t, second_ok) {
		return
	}
	write_file(t, krs.path_join(second.staged, "beta.odin"), "package beta")
	write_file(t, krs.path_join(occupied, "manual.odin"), "package manual")

	testing.expect(t, !krs.transaction_commit(&transaction))
	expect_contains(&fixture, strings.to_string(output), "appeared during the install")
	testing.expect_value(t, read_file(manifest), "previous manifest")
	testing.expect_value(t, read_file(krs.path_join(occupied, "manual.odin")), "package manual")
	testing.expect(t, !os.exists(krs.path_join(occupied, "beta.odin")))
}

@(test)
journal_recovers_every_publication_prefix :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// The package is replaced, a second package is added, the first lockfile
	// is replaced and the second is removed. Test each rename boundary.
	for checkpoint in 0..=7 {
		fixture := fixture_make(t)
		defer fixture_destroy(&fixture)
		project, _ := os.get_absolute_path(fixture.project, context.allocator)
		root, _ := os.get_absolute_path(fixture.root, context.allocator)
		shared := krs.path_join(root, "shared")
		pkg_file := krs.path_join(shared, "alpha/alpha.odin")
		added_file := krs.path_join(shared, "beta/beta.odin")
		manifest := krs.path_join(shared, krs.MANIFEST_PATH)
		pins := krs.path_join(project, krs.PACKAGES_PATH)
		before :: `{"format":1,"packages":[],"test":"before"}`
		after :: `{"format":1,"packages":[],"test":"after"}`
		write_file(t, pkg_file, "package old")
		write_file(t, manifest, before)
		write_file(t, pins, before)

		output := strings.builder_make()
		env := krs.Env{home = fixture.home, err = strings.to_writer(&output)}
		transaction := krs.Transaction{env = &env, scope = {project, root}}
		defer krs.transaction_close(&transaction)
		for index in 0..<4 {
			targets := []string{krs.path_join(shared, "alpha"), krs.path_join(shared, "beta"), manifest, pins}
			kinds := []krs.Target_Kind{.Package, .New, .Record, .Record}
			change, ok := krs.transaction_stage(&transaction, targets[index], kinds[index])
			if !testing.expect(t, ok) {
				return
			}
			switch index {
			case 0:
				write_file(t, krs.path_join(change.staged, "alpha.odin"), "package new")
			case 1:
				write_file(t, krs.path_join(change.staged, "beta.odin"), "package beta")
			case 2:
				write_file(t, change.staged, after)
			case 3:
				change.staged = ""
			}
		}

		// At the first partial replacement, exercise recovery of the old filename.
		filename := "transactions.sqlite3" if checkpoint == 1 else "transactions.db"
		database, opened := krs.journal_open(&env, true, filename)
		if !testing.expect(t, opened) {
			return
		}
		changes, id, prepared := krs.transaction_prepare(&transaction, database)
		if !testing.expect(t, prepared) {
			db.close(database)
			return
		}

		renames := 0
		for change in changes {
			if change.original.inode != 0 && renames < checkpoint {
				testing.expect_value(t, os.rename(change.target, krs.path_join(change.directory, "old")), nil)
				renames += 1
			}

			if change.replacement.inode != 0 && renames < checkpoint {
				testing.expect_value(t, os.rename(krs.path_join(change.directory, "new"), change.target), nil)
				renames += 1
			}
		}
		committed := checkpoint == 7
		if committed {
			testing.expect(t, krs.journal_mark_settled(&env, database, id))
			// Recovery can resume a cleanup that already removed one backup.
			testing.expect_value(t, os.remove_all(changes[0].directory), nil)
		}
		db.close(database)

		// Recover through a different project sharing the same Odin root.
		other := fixture_make(t)
		defer fixture_destroy(&other)
		other.home = fixture.home
		other.root = fixture.root
		expect_ok(&other, run(&other, "", "update"))
		if committed {
			testing.expect_value(t, read_file(pkg_file), "package new")
			testing.expect_value(t, read_file(manifest), after)
			testing.expect(t, os.exists(added_file))
			testing.expect(t, !os.exists(pins))
		} else {
			testing.expect_value(t, read_file(pkg_file), "package old")
			testing.expect_value(t, read_file(manifest), before)
			testing.expect(t, !os.exists(added_file))
			testing.expect_value(t, read_file(pins), before)
		}
		for change in changes {
			testing.expect(t, !os.exists(change.directory))
		}
		expect_ok(&fixture, run(&fixture, "", "update"))
	}
}

@(test)
simultaneous_commands_share_the_odin_root_lock :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	first := fixture_make(t)
	defer fixture_destroy(&first)
	second := fixture_make(t)
	defer fixture_destroy(&second)
	second.root = first.root

	output := strings.builder_make()
	env := krs.Env{
		project = first.project,
		home = first.home,
		default_root = first.root,
		err = strings.to_writer(&output),
	}
	state, ok := krs.state_open(&env, {})
	if !testing.expect(t, ok) {
		return
	}
	expect_failure(&second, run(&second, "", "install", "--yes"), "cannot lock")
	krs.state_close(state)
	expect_ok(&second, run(&second, "", "install", "--yes"))
}

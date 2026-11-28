package e2e

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import db "shared:kakunou"

import krs "../../src"
import "../fixtures"

@(test)
publication_preflight_preserves_previous_paths :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	output := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&output)}
	project, _ := os.get_absolute_path(fixture.project, context.allocator)
	root, _ := os.get_absolute_path(fixture.root, context.allocator)
	transaction := krs.Transaction{env = &env, scope = {project, root}}
	defer krs.transaction_close(&transaction)

	shared := krs.path_join(root, "shared")
	manifest := krs.path_join(shared, krs.MANIFEST_PATH)
	fixtures.write_file(t, manifest, "previous manifest")
	first, first_ok := krs.transaction_stage(&transaction, manifest, .Record)
	if !testing.expect(t, first_ok) {
		return
	}
	fixtures.write_file(t, first.staged, "new manifest")

	occupied := krs.path_join(shared, "beta")
	second, second_ok := krs.transaction_stage(&transaction, occupied, .New)
	if !testing.expect(t, second_ok) {
		return
	}
	fixtures.write_file(t, krs.path_join(second.staged, "beta.odin"), "package beta")
	fixtures.write_file(t, krs.path_join(occupied, "manual.odin"), "package manual")

	testing.expect(t, !krs.transaction_commit(&transaction))
	fixtures.expect_contains(&fixture, strings.to_string(output), "appeared during the install")
	testing.expect_value(t, fixtures.read_file(manifest), "previous manifest")
	testing.expect_value(t, fixtures.read_file(krs.path_join(occupied, "manual.odin")), "package manual")
	testing.expect(t, !os.exists(krs.path_join(occupied, "beta.odin")))
}

@(test)
journal_recovers_every_publication_prefix :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator

	// The package is replaced, a second package is added, the first lockfile
	// is replaced and the second is removed. Test each rename boundary.
	for checkpoint in 0..=7 {
		fixture := fixtures.fixture_make(t)
		defer fixtures.fixture_destroy(&fixture)
		project, _ := os.get_absolute_path(fixture.project, context.allocator)
		root, _ := os.get_absolute_path(fixture.root, context.allocator)
		shared := krs.path_join(root, "shared")
		pkg_file := krs.path_join(shared, "alpha/alpha.odin")
		added_file := krs.path_join(shared, "beta/beta.odin")
		manifest := krs.path_join(shared, krs.MANIFEST_PATH)
		pins := krs.path_join(project, krs.PACKAGES_PATH)
		before :: `{"format":1,"packages":[],"test":"before"}`
		after :: `{"format":1,"packages":[],"test":"after"}`
		fixtures.write_file(t, pkg_file, "package old")
		fixtures.write_file(t, manifest, before)
		fixtures.write_file(t, pins, before)

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
				fixtures.write_file(t, krs.path_join(change.staged, "alpha.odin"), "package new")
			case 1:
				fixtures.write_file(t, krs.path_join(change.staged, "beta.odin"), "package beta")
			case 2:
				fixtures.write_file(t, change.staged, after)
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
		other := fixtures.fixture_make(t)
		defer fixtures.fixture_destroy(&other)
		other.home = fixture.home
		other.root = fixture.root
		fixtures.expect_ok(&other, fixtures.run(&other, "", "update"))
		if committed {
			testing.expect_value(t, fixtures.read_file(pkg_file), "package new")
			testing.expect_value(t, fixtures.read_file(manifest), after)
			testing.expect(t, os.exists(added_file))
			testing.expect(t, !os.exists(pins))
		} else {
			testing.expect_value(t, fixtures.read_file(pkg_file), "package old")
			testing.expect_value(t, fixtures.read_file(manifest), before)
			testing.expect(t, !os.exists(added_file))
			testing.expect_value(t, fixtures.read_file(pins), before)
		}
		for change in changes {
			testing.expect(t, !os.exists(change.directory))
		}
		fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update"))
	}
}

@(test)
simultaneous_commands_share_the_odin_root_lock :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	first := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&first)
	second := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&second)
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
	fixtures.expect_failure(&second, fixtures.run(&second, "", "install", "--yes"), "cannot lock")
	krs.state_close(state)
	fixtures.expect_ok(&second, fixtures.run(&second, "", "install", "--yes"))
}

@(test)
simultaneous_commands_share_the_project_lock :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	output := strings.builder_make()
	env := krs.Env{
		project = fixture.project,
		home = fixture.home,
		default_root = fixture.root,
		err = strings.to_writer(&output),
	}
	state, ok := krs.state_open(&env, {})
	if !testing.expect(t, ok, strings.to_string(output)) {
		return
	}

	other := krs.path_join(fixture.base, "other-root")
	os.make_directory_all(krs.path_join(other, "shared"))
	root_option := fmt.aprintf("--root=%s", other)
	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "install", "--yes", root_option), "cannot lock")
	krs.state_close(state)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "install", "--yes", root_option))
}

JOURNAL_BEFORE :: `{"format":1,"packages":[],"test":"before"}`
JOURNAL_AFTER :: `{"format":1,"packages":[],"test":"after"}`

// Records the four changes of journal_recovers_every_publication_prefix and
// performs the first `renames` renames. The caller closes the database.
journal_fixture_prepare :: proc(
	fixture: ^fixtures.Fixture,
	env: ^krs.Env,
	renames: int,
) -> (database: ^db.SQLite_DB, changes: []krs.Journal_Change, id: i64, ok: bool) {
	t := fixture.t
	project, _ := os.get_absolute_path(fixture.project, context.allocator)
	root, _ := os.get_absolute_path(fixture.root, context.allocator)
	shared := krs.path_join(root, "shared")
	manifest := krs.path_join(shared, krs.MANIFEST_PATH)
	pins := krs.path_join(project, krs.PACKAGES_PATH)
	fixtures.write_file(t, krs.path_join(shared, "alpha/alpha.odin"), "package old")
	fixtures.write_file(t, manifest, JOURNAL_BEFORE)
	fixtures.write_file(t, pins, JOURNAL_BEFORE)

	transaction := krs.Transaction{env = env, scope = {project, root}}
	defer krs.transaction_close(&transaction)
	targets := []string{krs.path_join(shared, "alpha"), krs.path_join(shared, "beta"), manifest, pins}
	kinds := []krs.Target_Kind{.Package, .New, .Record, .Record}
	for index in 0..<4 {
		change := krs.transaction_stage(&transaction, targets[index], kinds[index]) or_return
		switch index {
		case 0:
			fixtures.write_file(t, krs.path_join(change.staged, "alpha.odin"), "package new")
		case 1:
			fixtures.write_file(t, krs.path_join(change.staged, "beta.odin"), "package beta")
		case 2:
			fixtures.write_file(t, change.staged, JOURNAL_AFTER)
		case 3:
			change.staged = ""
		}
	}

	database = krs.journal_open(env, true, "transactions.db") or_return
	changes, id, ok = krs.transaction_prepare(&transaction, database)
	if !ok {
		db.close(database)
		return nil, nil, 0, false
	}

	done := 0
	for change in changes {
		if change.original.inode != 0 && done < renames {
			testing.expect_value(t, os.rename(change.target, krs.path_join(change.directory, "old")), nil)
			done += 1
		}

		if change.replacement.inode != 0 && done < renames {
			testing.expect_value(t, os.rename(krs.path_join(change.directory, "new"), change.target), nil)
			done += 1
		}
	}
	return database, changes, id, true
}

@(test)
deleted_project_does_not_block_the_odin_root :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	project, _ := os.get_absolute_path(fixture.project, context.allocator)
	root, _ := os.get_absolute_path(fixture.root, context.allocator)
	manifest := krs.path_join(krs.path_join(root, "shared"), krs.MANIFEST_PATH)
	fixtures.write_file(t, manifest, JOURNAL_BEFORE)

	output := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&output)}
	transaction := krs.Transaction{env = &env, scope = {project, root}}
	defer krs.transaction_close(&transaction)
	change, staged := krs.transaction_stage(&transaction, manifest, .Record)
	if !testing.expect(t, staged) {
		return
	}
	fixtures.write_file(t, change.staged, JOURNAL_AFTER)

	database, opened := krs.journal_open(&env, true, "transactions.db")
	if !testing.expect(t, opened) {
		return
	}
	changes, _, prepared := krs.transaction_prepare(&transaction, database)
	db.close(database)
	if !testing.expect(t, prepared) {
		return
	}
	testing.expect_value(t, os.remove_all(project), nil)

	other := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&other)
	other.root = fixture.root
	other.home = fixture.home
	fixtures.expect_ok(&other, fixtures.run(&other, "", "status", "-g"))
	testing.expect_value(t, fixtures.read_file(manifest), JOURNAL_BEFORE)
	testing.expect(t, !os.exists(changes[0].directory))
	fixtures.expect_contains(&other, fixtures.run(&other, "", "recover").out, "no interrupted transactions")
}

@(test)
settled_cleanup_failure_is_skipped_with_a_warning :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	if os.get_euid() == 0 {
		return
	}

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	output := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&output)}
	database, changes, id, prepared := journal_fixture_prepare(&fixture, &env, 7)
	if !testing.expect(t, prepared) {
		return
	}
	testing.expect(t, krs.journal_mark_settled(&env, database, id))
	db.close(database)

	// Without write permission the backup's own files cannot be removed.
	old := krs.path_join(changes[0].directory, "old")
	testing.expect_value(t, os.chmod(old, {.Read_User, .Execute_User}), nil)
	defer os.chmod(old, {.Read_User, .Write_User, .Execute_User})

	other := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&other)
	other.root = fixture.root
	other.home = fixture.home
	skipped := fixtures.run(&other, "", "update")
	fixtures.expect_ok(&other, skipped)
	fixtures.expect_contains(&other, skipped.out, "cannot recover transaction")

	testing.expect_value(t, os.chmod(old, {.Read_User, .Write_User, .Execute_User}), nil)
	retried := fixtures.run(&other, "", "update")
	fixtures.expect_ok(&other, retried)
	testing.expect(t, !strings.contains(retried.out, "cannot recover transaction"))
	testing.expect(t, !os.exists(changes[0].directory))
}

@(test)
pending_record_in_scope_still_blocks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	output := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&output)}
	database, changes, _, prepared := journal_fixture_prepare(&fixture, &env, 1)
	if !testing.expect(t, prepared) {
		return
	}
	old := krs.path_join(changes[0].directory, "old")
	testing.expect_value(t, os.remove_all(old), nil)
	fixtures.write_file(t, old, "tampered")
	db.close(database)

	result := fixtures.run(&fixture, "", "update")
	fixtures.expect_failure(&fixture, result, "cannot verify the backup")
	fixtures.expect_contains(&fixture, result.out, "krs recover")
}

@(test)
recover_lists_and_abandons :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	output := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&output)}
	database, changes, id, prepared := journal_fixture_prepare(&fixture, &env, 1)
	if !testing.expect(t, prepared) {
		return
	}
	old := krs.path_join(changes[0].directory, "old")
	testing.expect_value(t, os.remove_all(old), nil)
	fixtures.write_file(t, old, "tampered")
	db.close(database)

	listed := fixtures.run(&fixture, "", "recover")
	fixtures.expect_ok(&fixture, listed)
	fixtures.expect_contains(&fixture, listed.out, "pending")
	fixtures.expect_contains(&fixture, listed.out, "transactions.db")
	fixtures.expect_contains(&fixture, listed.out, changes[0].target)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "recover", "abandon", fmt.tprint(id)), "pass --yes to forget it")
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "recover", "abandon", fmt.tprint(id), "--yes"))
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update"))
	testing.expect(t, os.exists(changes[0].directory))
}

@(test)
recover_rejects_unknown_ids :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	fixtures.expect_failure(&fixture, fixtures.run(&fixture, "", "recover", "abandon", "999", "--yes"), "no transaction 999")
	invalid := fixtures.run(&fixture, "", "recover", "abandon", "x")
	testing.expect_value(t, invalid.code, krs.EXIT_USAGE)
	fixtures.expect_contains(&fixture, invalid.err, "x is not a transaction id")
}

@(test)
missing_root_keeps_a_pending_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	testing.expect_value(t, os.make_directory_all(krs.path_join(fixture.base, "root2/shared")), nil)
	project, _ := os.get_absolute_path(fixture.project, context.allocator)
	second, _ := os.get_absolute_path(krs.path_join(fixture.base, "root2"), context.allocator)
	away := fmt.tprintf("%s.away", second)
	targets := []string{krs.path_join(krs.path_join(second, "shared"), krs.MANIFEST_PATH), krs.path_join(project, krs.PACKAGES_PATH)}

	output := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&output)}
	transaction := krs.Transaction{env = &env, scope = {project, second}}
	defer krs.transaction_close(&transaction)
	for target in targets {
		fixtures.write_file(t, target, JOURNAL_BEFORE)
		change, staged := krs.transaction_stage(&transaction, target, .Record)
		if !testing.expect(t, staged) {
			return
		}
		fixtures.write_file(t, change.staged, JOURNAL_AFTER)
	}

	database, opened := krs.journal_open(&env, true, "transactions.db")
	if !testing.expect(t, opened) {
		return
	}
	changes, id, prepared := krs.transaction_prepare(&transaction, database)
	db.close(database)
	if !testing.expect(t, prepared) {
		return
	}

	// The Odin root of the record is away, as an unmounted volume would be.
	testing.expect_value(t, os.rename(second, away), nil)
	skipped := fixtures.run(&fixture, "", "update")
	fixtures.expect_ok(&fixture, skipped)
	fixtures.expect_contains(&fixture, skipped.out, "cannot recover transaction")
	testing.expect_value(t, os.rename(away, second), nil)
	for change in changes {
		testing.expect(t, os.exists(change.directory))
	}
	testing.expect_value(t, fixtures.read_file(targets[0]), JOURNAL_BEFORE)
	testing.expect_value(t, fixtures.read_file(targets[1]), JOURNAL_BEFORE)

	listed := fixtures.run(&fixture, "", "recover")
	fixtures.expect_ok(&fixture, listed)
	fixtures.expect_contains(&fixture, listed.out, fmt.tprintf("transactions.db #%d", id))

	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update", fmt.tprintf("--root=%s", second)))
	for change in changes {
		testing.expect(t, !os.exists(change.directory))
	}
}

@(test)
cleanup_failure_after_publish_still_succeeds :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	if os.get_euid() == 0 {
		return
	}

	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	project, _ := os.get_absolute_path(fixture.project, context.allocator)
	root, _ := os.get_absolute_path(fixture.root, context.allocator)
	alpha := krs.path_join(root, "shared/alpha")
	locked := krs.path_join(alpha, "locked")
	fixtures.write_file(t, krs.path_join(locked, "file.txt"), "kept")

	out := strings.builder_make()
	err := strings.builder_make()
	env := krs.Env{home = fixture.home, out = strings.to_writer(&out), err = strings.to_writer(&err)}
	transaction := krs.Transaction{env = &env, scope = {project, root}}
	defer krs.transaction_close(&transaction)
	change, staged := krs.transaction_stage(&transaction, alpha, .Package)
	if !testing.expect(t, staged) {
		return
	}
	fixtures.write_file(t, krs.path_join(change.staged, "alpha.odin"), "package new")
	directory := change.directory
	backup := krs.path_join(directory, "old/locked")
	testing.expect_value(t, os.chmod(locked, {.Read_User, .Execute_User}), nil)
	defer os.chmod(backup, {.Read_User, .Write_User, .Execute_User})

	testing.expect(t, krs.transaction_commit(&transaction))
	fixtures.expect_contains(&fixture, strings.to_string(out), "staging files remain")
	testing.expect_value(t, fixtures.read_file(krs.path_join(alpha, "alpha.odin")), "package new")

	testing.expect_value(t, os.chmod(backup, {.Read_User, .Write_User, .Execute_User}), nil)
	fixtures.expect_ok(&fixture, fixtures.run(&fixture, "", "update"))
	testing.expect(t, !os.exists(directory))
}

@(test)
journal_recovers_a_vendor_publication :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)
	project, _ := os.get_absolute_path(fixture.project, context.allocator)
	root, _ := os.get_absolute_path(fixture.root, context.allocator)
	vendor := krs.path_join(project, krs.VENDOR_DIR)
	pkg_file := krs.path_join(vendor, "alpha/alpha.odin")
	manifest := krs.path_join(vendor, krs.MANIFEST_PATH)
	before :: `{"format": 1, "packages": []}`
	fixtures.write_file(t, pkg_file, "package old")
	fixtures.write_file(t, manifest, before)

	output := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&output)}
	transaction := krs.Transaction{env = &env, scope = {project, root}}
	defer krs.transaction_close(&transaction)
	staged, staged_ok := krs.transaction_stage(&transaction, krs.path_join(vendor, "alpha"), .Package)
	if !testing.expect(t, staged_ok) {
		return
	}
	fixtures.write_file(t, krs.path_join(staged.staged, "alpha.odin"), "package new")
	record, record_ok := krs.transaction_stage(&transaction, manifest, .Record)
	if !testing.expect(t, record_ok) {
		return
	}
	fixtures.write_file(t, record.staged, `{"format": 1, "packages": [], "test": "after"}`)

	database, opened := krs.journal_open(&env, true, "transactions.db")
	if !testing.expect(t, opened) {
		return
	}
	changes, _, prepared := krs.transaction_prepare(&transaction, database)
	if !testing.expectf(t, prepared, "transaction_prepare rejected vendor paths: %s", strings.to_string(output)) {
		db.close(database)
		return
	}

	// Interrupt the publication after its first rename.
	testing.expect_value(t, os.rename(changes[0].target, krs.path_join(changes[0].directory, "old")), nil)
	db.close(database)

	result := fixtures.run(&fixture, "", "status")
	fixtures.expect_ok(&fixture, result)
	testing.expect_value(t, fixtures.read_file(pkg_file), "package old")
	testing.expect_value(t, fixtures.read_file(manifest), before)
	for change in changes {
		testing.expect(t, !os.exists(change.directory))
	}
}

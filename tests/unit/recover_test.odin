package unit

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import db "shared:kakunou"

import krs "../../src"
import "../fixtures"

Recover_Fixture :: struct {
	fixture: fixtures.Fixture,
	out:     strings.Builder,
	err:     strings.Builder,
	env:     krs.Env,
	scope:   krs.Journal_Scope,
}

// A journal in the fixture's home whose scope names the fixture's real,
// lockable project and Odin root.
recover_fixture_make :: proc(t: ^testing.T, recover: ^Recover_Fixture) {
	recover.fixture = fixtures.fixture_make(t)
	recover.out = strings.builder_make()
	recover.err = strings.builder_make()
	recover.env = krs.Env {
		home = recover.fixture.home,
		out  = strings.to_writer(&recover.out),
		err  = strings.to_writer(&recover.err),
	}
	project, _ := os.get_absolute_path(recover.fixture.project, context.allocator)
	root, _ := os.get_absolute_path(recover.fixture.root, context.allocator)
	recover.scope = {project = project, root = root}
}

// Records one change of shared/<name> and returns the record's id.
recover_insert :: proc(t: ^testing.T, recover: ^Recover_Fixture, name: string, settled: bool) -> i64 {
	database, opened := krs.journal_open(&recover.env, true)
	if !testing.expect(t, opened && database != nil) {
		return 0
	}
	defer db.close(database)

	target := krs.path_join(recover.scope.root, fmt.tprintf("shared/%s", name))
	changes := []krs.Journal_Change{{target = target, directory = krs.path_join(recover.scope.root, "shared/.krs-stage-unit")}}
	payload, err := json.marshal(changes)
	testing.expect_value(t, err, nil)
	id, inserted := krs.journal_insert(&recover.env, database, recover.scope, payload)
	testing.expect(t, inserted)
	if settled {
		testing.expect(t, krs.journal_mark_settled(&recover.env, database, id))
	}
	return id
}

recover_count :: proc(t: ^testing.T, recover: ^Recover_Fixture) -> int {
	database, opened := krs.journal_open(&recover.env, false)
	if !testing.expect(t, opened && database != nil) {
		return -1
	}
	defer db.close(database)

	records, listed := krs.journal_list_all(&recover.env, database)
	if !testing.expect(t, listed) {
		return -1
	}
	return len(records)
}

@(test)
recover_list_reports_an_empty_journal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	recover: Recover_Fixture
	recover_fixture_make(t, &recover)
	defer fixtures.fixture_destroy(&recover.fixture)

	testing.expect(t, krs.command_recover_list(&recover.env))
	testing.expect(t, strings.contains(strings.to_string(recover.out), "no interrupted transactions"))

	database, opened := krs.journal_open(&recover.env, true)
	if testing.expect(t, opened && database != nil) {
		db.close(database)
	}
	strings.builder_reset(&recover.out)
	testing.expect(t, krs.command_recover_list(&recover.env))
	testing.expect(t, strings.contains(strings.to_string(recover.out), "no interrupted transactions"))
	testing.expect_value(t, strings.to_string(recover.err), "")
}

@(test)
recover_list_describes_each_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	recover: Recover_Fixture
	recover_fixture_make(t, &recover)
	defer fixtures.fixture_destroy(&recover.fixture)

	pending := recover_insert(t, &recover, "beta", false)
	settled := recover_insert(t, &recover, "gamma", true)
	testing.expect(t, krs.command_recover_list(&recover.env))

	out := strings.to_string(recover.out)
	testing.expect(t, strings.contains(out, fmt.tprintf("%s #%d pending", krs.JOURNAL_FILENAME, pending)), out)
	testing.expect(t, strings.contains(out, fmt.tprintf("%s #%d settled", krs.JOURNAL_FILENAME, settled)), out)
	testing.expect(t, strings.contains(out, fmt.tprintf("project %s", recover.scope.project)), out)
	testing.expect(t, strings.contains(out, fmt.tprintf("change %s", krs.path_join(recover.scope.root, "shared/gamma"))), out)
	testing.expect(t, strings.contains(out, "(missing)"), out)
	testing.expect(t, !strings.contains(out, "(in use)"), out)
	testing.expect(t, !strings.contains(out, "no interrupted transactions"), out)
}

@(test)
recover_in_use_follows_the_scope_locks :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	recover: Recover_Fixture
	recover_fixture_make(t, &recover)
	defer fixtures.fixture_destroy(&recover.fixture)

	testing.expect(t, !krs.recover_in_use(&recover.env, recover.scope))

	held, locked := krs.directory_lock(&recover.env, recover.scope.project)
	if !testing.expect(t, locked) {
		return
	}
	testing.expect(t, krs.recover_in_use(&recover.env, recover.scope))
	krs.directory_unlock(held)

	testing.expect(t, !krs.recover_in_use(&recover.env, recover.scope))
	testing.expect_value(t, strings.to_string(recover.err), "")
}

@(test)
recover_find_tells_present_from_absent_ids :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	recover: Recover_Fixture
	recover_fixture_make(t, &recover)
	defer fixtures.fixture_destroy(&recover.fixture)

	id := recover_insert(t, &recover, "beta", false)
	database, opened := krs.journal_open(&recover.env, false)
	if !testing.expect(t, opened && database != nil) {
		return
	}
	defer db.close(database)

	record, found, ok := krs.recover_find(&recover.env, database, id)
	testing.expect(t, ok && found)
	testing.expect_value(t, record.id, id)
	testing.expect_value(t, record.scope, recover.scope)

	_, found, ok = krs.recover_find(&recover.env, database, id + 1)
	testing.expect(t, ok)
	testing.expect(t, !found)
}

@(test)
recover_abandon_rejects_unknown_ids :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	recover: Recover_Fixture
	recover_fixture_make(t, &recover)
	defer fixtures.fixture_destroy(&recover.fixture)

	testing.expect(t, !krs.command_recover_abandon(&recover.env, {yes = true}, 999))
	testing.expect(t, strings.contains(strings.to_string(recover.err), "no transaction 999"))

	id := recover_insert(t, &recover, "beta", true)
	strings.builder_reset(&recover.err)
	testing.expect(t, !krs.command_recover_abandon(&recover.env, {yes = true}, id + 1))
	testing.expect(t, strings.contains(strings.to_string(recover.err), fmt.tprintf("no transaction %d", id + 1)))
	testing.expect_value(t, recover_count(t, &recover), 1)
}

@(test)
recover_abandon_needs_yes_for_a_pending_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	recover: Recover_Fixture
	recover_fixture_make(t, &recover)
	defer fixtures.fixture_destroy(&recover.fixture)

	id := recover_insert(t, &recover, "beta", false)
	testing.expect(t, !krs.command_recover_abandon(&recover.env, {}, id))
	testing.expect(t, strings.contains(strings.to_string(recover.err), "pass --yes to forget it"))
	testing.expect(t, strings.contains(strings.to_string(recover.out), "half-published"))
	testing.expect_value(t, recover_count(t, &recover), 1)

	testing.expect(t, krs.command_recover_abandon(&recover.env, {yes = true}, id))
	testing.expect(t, strings.contains(strings.to_string(recover.out), "no files were moved or deleted"))
	testing.expect_value(t, recover_count(t, &recover), 0)
}

@(test)
recover_abandon_forgets_a_settled_record_and_notes_staging :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	recover: Recover_Fixture
	recover_fixture_make(t, &recover)
	defer fixtures.fixture_destroy(&recover.fixture)

	id := recover_insert(t, &recover, "beta", true)
	staging := krs.path_join(recover.scope.root, "shared/.krs-stage-unit")
	testing.expect_value(t, os.make_directory_all(staging), nil)

	testing.expect(t, krs.command_recover_abandon(&recover.env, {}, id))
	out := strings.to_string(recover.out)
	testing.expect(t, strings.contains(out, fmt.tprintf("staging files remain at %s", staging)), out)
	testing.expect(t, strings.contains(out, fmt.tprintf("forgot transaction %d", id)), out)
	testing.expect(t, os.is_directory(staging))
	testing.expect_value(t, recover_count(t, &recover), 0)
}

@(test)
recover_abandon_refuses_a_record_in_use :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	recover: Recover_Fixture
	recover_fixture_make(t, &recover)
	defer fixtures.fixture_destroy(&recover.fixture)

	id := recover_insert(t, &recover, "beta", true)
	held, locked := krs.directory_lock(&recover.env, recover.scope.root)
	if !testing.expect(t, locked) {
		return
	}
	defer krs.directory_unlock(held)

	testing.expect(t, !krs.command_recover_abandon(&recover.env, {yes = true}, id))
	testing.expect(t, strings.contains(strings.to_string(recover.err), "is in use by another krs command"))
	testing.expect_value(t, recover_count(t, &recover), 1)
}

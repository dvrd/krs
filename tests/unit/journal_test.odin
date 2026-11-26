package unit

import "core:os"
import "core:strings"
import "core:testing"
import db "shared:kakunou"

import krs "../../src"
import "../fixtures"

@(test)
journal_open_without_create_leaves_a_missing_journal_alone :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	errors := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&errors)}
	database, ok := krs.journal_open(&env, false)
	testing.expect(t, ok)
	testing.expect(t, database == nil)
	testing.expect_value(t, strings.to_string(errors), "")
	testing.expect(t, !os.exists(krs.path_join(fixture.home, krs.KRS_DATA_PATH)))

	created, created_ok := krs.journal_open(&env, true)
	if !testing.expect(t, created_ok && created != nil) {
		return
	}
	db.close(created)
	path := krs.path_join(fixture.home, krs.KRS_DATA_PATH + "/" + krs.JOURNAL_FILENAME)
	testing.expectf(t, os.exists(path), "%s should exist", path)
}

@(test)
journal_open_rejects_a_missing_home_and_a_non_file_journal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	errors := strings.builder_make()
	env := krs.Env{err = strings.to_writer(&errors)}
	database, ok := krs.journal_open(&env, true)
	testing.expect(t, !ok)
	testing.expect(t, database == nil)
	testing.expect(t, strings.contains(strings.to_string(errors), "cannot locate the home directory"))

	strings.builder_reset(&errors)
	env.home = fixture.home
	path := krs.path_join(fixture.home, krs.KRS_DATA_PATH + "/" + krs.JOURNAL_FILENAME)
	testing.expect_value(t, os.make_directory_all(path), nil)
	database, ok = krs.journal_open(&env, true)
	testing.expect(t, !ok)
	testing.expect(t, database == nil)
	testing.expect(t, strings.contains(strings.to_string(errors), "invalid transaction journal"))
}

@(test)
journal_list_returns_only_the_records_of_a_scope :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	errors := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&errors)}
	database, opened := krs.journal_open(&env, true)
	if !testing.expect(t, opened && database != nil) {
		return
	}
	defer db.close(database)

	first_scope := krs.Journal_Scope{project = "/p/one", root = "/r/one"}
	second_scope := krs.Journal_Scope{project = "/p/two", root = "/r/two"}
	first, first_ok := krs.journal_insert(&env, database, first_scope, transmute([]byte)string("[1]"))
	second, second_ok := krs.journal_insert(&env, database, second_scope, transmute([]byte)string("[2]"))
	testing.expect(t, first_ok && second_ok)
	testing.expect(t, first != second)

	by_project, project_ok := krs.journal_list(&env, database, {project = "/p/one", root = "/elsewhere"})
	testing.expect(t, project_ok)
	if testing.expect_value(t, len(by_project), 1) {
		testing.expect_value(t, by_project[0].id, first)
		testing.expect_value(t, by_project[0].scope, first_scope)
		testing.expect_value(t, by_project[0].phase, krs.Journal_Phase.Pending)
		testing.expect_value(t, string(by_project[0].payload), "[1]")
	}

	// A record matches when either directory of the asked scope is either of
	// its own: here the asked project is the second record's Odin root.
	by_root, root_ok := krs.journal_list(&env, database, {project = "/r/two", root = "/elsewhere"})
	testing.expect(t, root_ok)
	if testing.expect_value(t, len(by_root), 1) {
		testing.expect_value(t, by_root[0].id, second)
	}

	none, none_ok := krs.journal_list(&env, database, {project = "/nowhere", root = "/elsewhere"})
	testing.expect(t, none_ok)
	testing.expect_value(t, len(none), 0)

	all, all_ok := krs.journal_list_all(&env, database)
	testing.expect(t, all_ok)
	if testing.expect_value(t, len(all), 2) {
		testing.expect_value(t, all[0].id, first)
		testing.expect_value(t, all[1].id, second)
		testing.expect_value(t, string(all[1].payload), "[2]")
	}
	testing.expect_value(t, strings.to_string(errors), "")
}

@(test)
journal_settles_and_deletes_one_record :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	errors := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&errors)}
	database, opened := krs.journal_open(&env, true)
	if !testing.expect(t, opened && database != nil) {
		return
	}
	defer db.close(database)

	scope := krs.Journal_Scope{project = "/p", root = "/r"}
	kept, _ := krs.journal_insert(&env, database, scope, transmute([]byte)string("[]"))
	settled, _ := krs.journal_insert(&env, database, scope, transmute([]byte)string("[]"))
	testing.expect(t, krs.journal_mark_settled(&env, database, settled))

	records, _ := krs.journal_list_all(&env, database)
	if testing.expect_value(t, len(records), 2) {
		testing.expect_value(t, records[0].phase, krs.Journal_Phase.Pending)
		testing.expect_value(t, records[1].phase, krs.Journal_Phase.Settled)
	}

	testing.expect(t, krs.journal_delete(&env, database, settled))
	records, _ = krs.journal_list_all(&env, database)
	if testing.expect_value(t, len(records), 1) {
		testing.expect_value(t, records[0].id, kept)
		testing.expect_value(t, records[0].phase, krs.Journal_Phase.Pending)
	}
	testing.expect_value(t, strings.to_string(errors), "")
}

@(test)
journal_list_rejects_an_unknown_phase :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fixture := fixtures.fixture_make(t)
	defer fixtures.fixture_destroy(&fixture)

	errors := strings.builder_make()
	env := krs.Env{home = fixture.home, err = strings.to_writer(&errors)}
	database, opened := krs.journal_open(&env, true)
	if !testing.expect(t, opened && database != nil) {
		return
	}
	defer db.close(database)

	id, _ := krs.journal_insert(&env, database, {project = "/p", root = "/r"}, transmute([]byte)string("[]"))
	error := db.execute_sql(database, "PRAGMA ignore_check_constraints = ON; UPDATE journal_v1 SET phase = 7")
	testing.expect_value(t, error.kind, db.Database_Error_Kind.None)

	_, ok := krs.journal_list_all(&env, database)
	testing.expect(t, !ok)
	testing.expect(t, strings.contains(strings.to_string(errors), "cannot read pending transactions"))
	testing.expect(t, id > 0)
}

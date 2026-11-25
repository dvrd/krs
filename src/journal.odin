package krs

import "core:os"
import "core:strings"
import db "shared:kakunou"

JOURNAL_FILENAME :: "transactions.db"
JOURNAL_LEGACY_FILENAME :: "transactions.sqlite3"

Journal_Scope :: struct {
	project: string,
	root:    string,
}

Journal_Phase :: enum i64 {
	Pending,
	Settled, // publication or rollback completed, only cleanup remains
}

Journal_Record :: struct {
	id:      i64,
	scope:   Journal_Scope,
	phase:   Journal_Phase,
	payload: []byte,
}

JOURNAL_SCHEMA :: `
	CREATE TABLE IF NOT EXISTS journal_v1 (
		id INTEGER PRIMARY KEY,
		project TEXT NOT NULL,
		odin_root TEXT NOT NULL,
		phase INTEGER NOT NULL CHECK (phase IN (0, 1)),
		changes BLOB NOT NULL
	);
	CREATE INDEX IF NOT EXISTS journal_v1_project ON journal_v1(project);
	CREATE INDEX IF NOT EXISTS journal_v1_root ON journal_v1(odin_root);
`

journal_check :: proc(env: ^Env, action: string, error: db.Database_Error) -> bool {
	if error.kind != .None {
		details := error
		return fail(env, "%v: %v (%v)", action, db.error_message(&details), error.sqlite_code)
	}
	return true
}

journal_open :: proc(env: ^Env, create: bool, filename := JOURNAL_FILENAME) -> (database: ^db.SQLite_DB, ok: bool) {
	if env.home == "" {
		return nil, fail(env, "cannot locate the home directory for the transaction journal")
	}

	directory := path_join(env.home, KRS_DATA_PATH)
	path := path_join(directory, filename)
	info, err := os.lstat(path, context.temp_allocator)
	switch err {
	case .Not_Exist:
		if !create {
			return nil, true
		}
		if mkdir_err := os.make_directory_all(directory, {.Read_User, .Write_User, .Execute_User});
		   mkdir_err != nil && !os.is_directory(directory) {
			return nil, fail(env, "cannot create %s: %v", directory, mkdir_err)
		}
	case nil:
		if info.type != .Regular {
			return nil, fail(env, "invalid transaction journal at %s", path)
		}
	case:
		return nil, fail(env, "cannot inspect %s: %v", path, err)
	}

	dir_info, dir_err := os.lstat(directory, context.temp_allocator)
	if dir_err != nil || dir_info.type != .Directory ||
	   .Write_Group in dir_info.mode || .Write_Other in dir_info.mode {
		return nil, fail(env, "the transaction journal requires a private directory at %s", directory)
	}

	c_path := strings.clone_to_cstring(path, context.temp_allocator)
	journal_check(env, "cannot open the transaction journal", db.open(&database, c_path)) or_return
	defer if !ok {
		db.close(database)
	}
	if db.sqlite3_busy_timeout(database, 5000) != .OK {
		return database, fail(env, "cannot set the transaction journal timeout")
	}

	journal_check(env, "cannot initialize the transaction journal",
		db.execute_sql(database, "PRAGMA synchronous=FULL; " + JOURNAL_SCHEMA)) or_return
	return database, true
}

journal_insert :: proc(env: ^Env, database: ^db.SQLite_DB, scope: Journal_Scope, payload: []byte) -> (id: i64, ok: bool) {
	parameters := []db.SQLite_Value{
		strings.clone_to_cstring(scope.project, context.temp_allocator),
		strings.clone_to_cstring(scope.root, context.temp_allocator),
		payload,
	}
	journal_check(env, "cannot record the transaction", db.insert(database,
		"INSERT INTO journal_v1(project, odin_root, phase, changes) VALUES (?, ?, 0, ?)", parameters)) or_return
	return db.last_insert_rowid(database), true
}

journal_mark_settled :: proc(env: ^Env, database: ^db.SQLite_DB, id: i64) -> bool {
	return journal_check(env, "cannot mark the transaction settled", db.insert(database,
		"UPDATE journal_v1 SET phase = 1 WHERE id = ?", {id}))
}

journal_delete :: proc(env: ^Env, database: ^db.SQLite_DB, id: i64) -> bool {
	return journal_check(env, "cannot remove the transaction record", db.insert(database,
		"DELETE FROM journal_v1 WHERE id = ?", {id}))
}

journal_decode_row :: proc(statement: ^db.SQLite_Statement, record: ^Journal_Record) -> db.Database_Error {
	error: db.Database_Error
	record.id, error = db.column_int(statement, 0)
	if error.kind != .None {
		return error
	}

	record.scope.project, error = db.column_text(statement, 1, context.temp_allocator)
	if error.kind != .None {
		return error
	}

	record.scope.root, error = db.column_text(statement, 2, context.temp_allocator)
	if error.kind != .None {
		return error
	}

	phase: i64
	phase, error = db.column_int(statement, 3)
	if error.kind != .None {
		return error
	}

	if phase != i64(Journal_Phase.Pending) && phase != i64(Journal_Phase.Settled) {
		return db.make_error(.Execution_Failed, "Invalid transaction phase")
	}

	record.phase = Journal_Phase(phase)
	record.payload, error = db.column_blob(statement, 4, context.temp_allocator)
	return error
}

journal_list :: proc(env: ^Env, database: ^db.SQLite_DB, scope: Journal_Scope) -> (records: []Journal_Record, ok: bool) {
	project := strings.clone_to_cstring(scope.project, context.temp_allocator)
	root := strings.clone_to_cstring(scope.root, context.temp_allocator)
	rows, error := db.query_many(database,
		"SELECT id, project, odin_root, phase, changes FROM journal_v1 " +
		"WHERE project IN (?1, ?2) OR odin_root IN (?1, ?2) ORDER BY id",
		{project, root}, journal_decode_row)
	journal_check(env, "cannot read pending transactions", error) or_return
	return rows, true
}

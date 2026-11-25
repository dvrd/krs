package krs

import "core:encoding/json"
import "core:os"
import "core:strings"
import db "shared:kakunou"

// `krs recover`: lists the records of both journal files. The transactions of
// a running krs command appear as well, marked as in use.
command_recover_list :: proc(env: ^Env) -> bool {
	filenames := [?]string{JOURNAL_LEGACY_FILENAME, JOURNAL_FILENAME}
	listed := 0
	for filename in filenames {
		database := journal_open(env, false, filename) or_return
		if database == nil {
			continue
		}
		defer db.close(database)

		records := journal_list_all(env, database) or_return
		for record in records {
			recover_say_record(env, filename, record)
			listed += 1
		}
	}

	if listed == 0 {
		info(env, "no interrupted transactions")
	}
	return true
}

recover_say_record :: proc(env: ^Env, filename: string, record: Journal_Record) {
	phase := "pending" if record.phase == .Pending else "settled"
	usage := " (in use)" if recover_in_use(env, record.scope) else ""
	say(env, "%s #%d %v%v", filename, record.id, phase, usage)
	say(env, "  project %s", record.scope.project)
	say(env, "  root %s", record.scope.root)

	changes: []Journal_Change
	if err := json.unmarshal(record.payload, &changes); err != nil {
		say(env, "  changes: %v", "cannot be decoded")
		return
	}

	for change in changes {
		staging := "present" if os.exists(change.directory) else "missing"
		say(env, "  change %s", change.target)
		say(env, "    staging %s (%v)", change.directory, staging)
	}
}

// A running krs command holds the locks of its directories. The locks taken
// here are released at once, and their failures are not reported.
recover_in_use :: proc(env: ^Env, recorded: Journal_Scope) -> bool {
	errors := strings.builder_make(context.temp_allocator)
	quiet := env^
	quiet.err = strings.to_writer(&errors)
	quiet.progress = nil

	scope, _, _ := journal_lock_scope(recorded, {})
	locks: [2]^os.File
	defer scope_unlock(&locks)
	return !scope_lock(&quiet, scope, {}, &locks)
}

recover_find :: proc(env: ^Env, database: ^db.SQLite_DB, id: i64) -> (record: Journal_Record, found: bool, ok: bool) {
	records := journal_list_all(env, database) or_return
	for candidate in records {
		if candidate.id == id {
			return candidate, true, true
		}
	}
	return {}, false, true
}

// `krs recover abandon <id>`: forgets a record without moving or deleting any
// file. A pending record needs --yes, because shared/ may be half published.
command_recover_abandon :: proc(env: ^Env, options: Options, id: i64) -> bool {
	assert(id > 0)

	filenames := [?]string{JOURNAL_LEGACY_FILENAME, JOURNAL_FILENAME}
	databases: [len(filenames)]^db.SQLite_DB
	defer for database in databases {
		if database != nil {
			db.close(database)
		}
	}

	record: Journal_Record
	found := -1
	for filename, index in filenames {
		databases[index] = journal_open(env, false, filename) or_return
		if databases[index] == nil {
			continue
		}

		candidate, exists := recover_find(env, databases[index], id) or_return
		if !exists {
			continue
		}

		if found >= 0 {
			return fail(env, "transaction %d exists in both %s and %s; remove the legacy file's record by hand",
				id, JOURNAL_LEGACY_FILENAME, JOURNAL_FILENAME)
		}
		record = candidate
		found = index
	}

	if found < 0 {
		return fail(env, "no transaction %d", id)
	}

	scope, _, _ := journal_lock_scope(record.scope, {})
	locks: [2]^os.File
	defer scope_unlock(&locks)
	if !scope_lock(env, scope, {}, &locks) {
		return fail(env, "transaction %d is in use by another krs command", id)
	}

	// Recovery may have finished the record before the locks were taken.
	recorded := record.scope
	exists: bool
	record, exists = recover_find(env, databases[found], id) or_return
	if !exists {
		return fail(env, "no transaction %d", id)
	}
	assert(record.scope == recorded)

	if record.phase == .Pending {
		recover_say_pending(env, record)
		if !options.yes {
			return fail(env, "transaction %d is pending; pass %s to forget it", id, "--yes")
		}
	}

	journal_delete(env, databases[found], id) or_return
	if record.phase == .Pending {
		success(env, "forgot transaction %d; no files were moved or deleted", id)
		return true
	}

	recover_note_staging(env, record)
	success(env, "forgot transaction %d", id)
	return true
}

recover_say_pending :: proc(env: ^Env, record: Journal_Record) {
	assert(record.phase == .Pending)

	changes: []Journal_Change
	if err := json.unmarshal(record.payload, &changes); err != nil {
		say(env, "  changes: %v", "cannot be decoded")
		changes = nil
	}

	for change in changes {
		say(env, "  previous contents of %s: %s", change.target, path_join(change.directory, "old"))
		say(env, "  new contents: %s", path_join(change.directory, "new"))
	}
	warn(env, "%s may hold a half-published state", path_join(record.scope.root, "shared"))
}

recover_note_staging :: proc(env: ^Env, record: Journal_Record) {
	assert(record.phase == .Settled)

	changes: []Journal_Change
	if err := json.unmarshal(record.payload, &changes); err != nil {
		return
	}

	for change in changes {
		if os.exists(change.directory) {
			note(env, "staging files remain at %s", change.directory)
		}
	}
}

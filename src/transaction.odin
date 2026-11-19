package krs

import "core:encoding/json"
import "core:os"
import "core:strings"
import db "shared:kakunou"

Target_Kind :: enum {
	New,
	Package,
	Link,
	Record,
}

File_Change :: struct {
	target:        string,
	directory:     string,
	staged:        string,
	backup:        string,
	kind:          Target_Kind,
	expected_link: string,
}

Transaction :: struct {
	env:        ^Env,
	scope:      Journal_Scope,
	changes:    [dynamic]File_Change,
	journalled: bool,
}

stage_package_path :: proc(
	transaction: ^Transaction,
	target: string,
	record: ^Manifest_Record,
) -> (^File_Change, bool) {
	if record == nil {
		return transaction_stage(transaction, target, .New)
	}

	if record.linked != "" {
		return transaction_stage(transaction, target, .Link, record.linked)
	}

	return transaction_stage(transaction, target, .Package)
}

// Every staged path and backup shares a filesystem with its destination.
transaction_stage :: proc(
	transaction: ^Transaction,
	target: string,
	kind: Target_Kind,
	expected_link := "",
) -> (change: ^File_Change, ok: bool) {
	parent := path_directory(target)
	if err := os.make_directory_all(parent); err != nil && !os.is_directory(parent) {
		return nil, fail(transaction.env, "cannot create %s: %v", parent, err)
	}

	directory, err := os.make_directory_temp(parent, ".krs-stage-*", context.allocator)
	if err != nil {
		return nil, fail(transaction.env, "cannot stage %s: %v", target, err)
	}

	append(&transaction.changes, File_Change{
		target = target,
		directory = directory,
		staged = path_join(directory, "new"),
		backup = path_join(directory, "old"),
		kind = kind,
		expected_link = expected_link,
	})
	return &transaction.changes[len(transaction.changes) - 1], true
}

transaction_close :: proc(transaction: ^Transaction) {
	if transaction.journalled {
		return
	}

	for change in transaction.changes {
		if err := os.remove_all(change.directory); err != nil && err != .Not_Exist {
			say(transaction.env, "warning: cannot remove staging directory %s: %v", change.directory, err)
		}
	}
}

change_check_target :: proc(env: ^Env, change: ^File_Change) -> (present: bool, ok: bool) {
	info, err := os.lstat(change.target, context.temp_allocator)
	if err == .Not_Exist {
		return false, true
	}

	if err != nil {
		return false, fail(env, "cannot inspect %s: %v", change.target, err)
	}

	switch change.kind {
	case .New:
		return false, fail(env, "%s appeared during the install and is not managed by krs", change.target)
	case .Package:
		if info.type != .Directory {
			return false, fail(env, "%s is no longer an installed package directory", change.target)
		}
	case .Link:
		link, link_err := os.read_link(change.target, context.temp_allocator)
		if link_err != nil || link != change.expected_link {
			return false, fail(env, "%s is no longer the link recorded by krs", change.target)
		}
	case .Record:
		if info.type != .Regular && info.type != .Symlink {
			return false, fail(env, "%s is not a record file", change.target)
		}
	}

	return true, true
}

// Device and inode identify entries moved by rename. The zero identity
// denotes an absent path.
Path_Identity :: struct {
	device: u64,
	inode:  u64,
}

Journal_Change :: struct {
	target:      string,
	directory:   string,
	staging:     Path_Identity,
	original:    Path_Identity,
	replacement: Path_Identity,
}

path_identity :: proc(env: ^Env, path: string) -> (id: Path_Identity, ok: bool) {
	info, err := os.lstat(path, context.temp_allocator)
	if err == .Not_Exist {
		return {}, true
	}

	if err != nil || info.inode == 0 || info.inode > u128(max(u64)) {
		return {}, fail(env, "cannot identify %s: %v", path, err)
	}

	return {device = info.device, inode = u64(info.inode)}, true
}

transaction_prepare :: proc(
	transaction: ^Transaction,
	database: ^db.SQLite_DB,
) -> (changes: []Journal_Change, id: i64, ok: bool) {
	env := transaction.env
	changes = make([]Journal_Change, len(transaction.changes))
	for &change, index in transaction.changes {
		present := change_check_target(env, &change) or_return
		original := path_identity(env, change.target) or_return
		staging := path_identity(env, change.directory) or_return
		if present != (original.inode != 0) || staging.inode == 0 {
			return nil, 0, fail(env, "the paths for %s changed during preparation", change.target)
		}

		replacement: Path_Identity
		if change.staged != "" {
			replacement = path_identity(env, change.staged) or_return
			if replacement.inode == 0 || replacement == original {
				return nil, 0, fail(env, "invalid staged replacement for %s", change.target)
			}
		}

		changes[index] = {change.target, change.directory, staging, original, replacement}
		if !journal_change_valid(transaction.scope, changes[index]) {
			return nil, 0, fail(env, "cannot journal transaction path %s", change.target)
		}
	}

	payload, err := json.marshal(changes)
	if err != nil {
		return nil, 0, fail(env, "cannot encode the transaction: %v", err)
	}

	// An insert failure can leave an uncertain database outcome. Keep staging
	// intact once we attempt to record it in SQLite.
	transaction.journalled = true
	id = journal_insert(env, database, transaction.scope, payload) or_return
	return changes, id, true
}

transaction_publish :: proc(env: ^Env, changes: []Journal_Change) -> bool {
	for change in changes {
		target := path_identity(env, change.target) or_return
		if target != change.original {
			return fail(env, "%s changed during publication", change.target)
		}

		if target.inode != 0 {
			backup := path_join(change.directory, "old")
			if err := os.rename(change.target, backup); err != nil {
				return fail(env, "cannot back up %s: %v", change.target, err)
			}
		}

		if change.replacement.inode != 0 {
			staged := path_join(change.directory, "new")
			if err := os.rename(staged, change.target); err != nil {
				return fail(env, "cannot replace %s: %v", change.target, err)
			}
		}
	}

	return true
}

journal_cleanup :: proc(env: ^Env, database: ^db.SQLite_DB, id: i64, changes: []Journal_Change) -> bool {
	for change in changes {
		staging := path_identity(env, change.directory) or_return
		if staging.inode == 0 {
			continue
		}

		if staging != change.staging {
			return fail(env, "the staging directory changed: %s", change.directory)
		}

		if err := os.remove_all(change.directory); err != nil {
			return fail(env, "cannot remove staging directory %s: %v", change.directory, err)
		}
	}
	return journal_delete(env, database, id)
}

// The database record outlives all renames and remains until cleanup succeeds.
transaction_commit :: proc(transaction: ^Transaction) -> bool {
	if len(transaction.changes) == 0 {
		return true
	}

	env := transaction.env
	database := journal_open(env, true) or_return
	defer db.close(database)
	changes, id := transaction_prepare(transaction, database) or_return
	if !transaction_publish(env, changes) {
		journal_revert(env, database, id, changes)
		return false
	}

	journal_mark_settled(env, database, id) or_return
	return journal_cleanup(env, database, id, changes)
}

journal_change_valid :: proc(scope: Journal_Scope, change: Journal_Change) -> bool {
	if change.staging.inode == 0 || path_directory(change.directory) != path_directory(change.target) {
		return false
	}

	prefix :: ".krs-stage-"
	name := path_base(change.directory)
	if !strings.has_prefix(name, prefix) || !is_package_name(name[len(prefix):]) {
		return false
	}

	shared := path_join(scope.root, "shared")
	return change.target == path_join(shared, MANIFEST_PATH) ||
	       change.target == path_join(scope.project, PACKAGES_PATH) ||
	       (path_directory(change.target) == shared && is_package_name(path_base(change.target)))
}

// Reverse the two renames using identities recorded before publication. Each
// step can be retried after interruption, including restoration of a link.
journal_restore_change :: proc(env: ^Env, change: Journal_Change) -> bool {
	staging := path_identity(env, change.directory) or_return
	if staging != change.staging {
		return fail(env, "the staging directory changed: %s", change.directory)
	}

	old_path := path_join(change.directory, "old")
	new_path := path_join(change.directory, "new")
	target := path_identity(env, change.target) or_return
	backup := path_identity(env, old_path) or_return
	staged := path_identity(env, new_path) or_return
	if target == change.original && backup.inode == 0 && staged == change.replacement {
		return true
	}

	if backup != change.original {
		return fail(env, "cannot verify the backup for %s in %s", change.target, change.directory)
	}

	if target.inode != 0 {
		if target != change.replacement || staged.inode != 0 {
			return fail(env, "%s changed outside the interrupted transaction", change.target)
		}

		if err := os.rename(change.target, new_path); err != nil {
			return fail(env, "cannot roll back %s: %v", change.target, err)
		}
	} else if staged != change.replacement {
		return fail(env, "cannot verify the staged files for %s in %s", change.target, change.directory)
	}

	if backup.inode != 0 {
		if err := os.rename(old_path, change.target); err != nil {
			return fail(env, "cannot restore %s; previous contents kept at %s: %v", change.target, old_path, err)
		}
	}
	return true
}

journal_revert :: proc(env: ^Env, database: ^db.SQLite_DB, id: i64, changes: []Journal_Change) -> bool {
	restored := true
	for index := len(changes) - 1; index >= 0; index -= 1 {
		if !journal_restore_change(env, changes[index]) {
			restored = false
		}
	}

	if !restored {
		return false
	}

	journal_mark_settled(env, database, id) or_return
	return journal_cleanup(env, database, id, changes)
}

journal_recover_record :: proc(env: ^Env, database: ^db.SQLite_DB, current: Journal_Scope, record: Journal_Record) -> bool {
	locks: [2]^os.File
	defer scope_unlock(&locks)
	scope_lock(env, record.scope, current, &locks) or_return

	changes: []Journal_Change
	if err := json.unmarshal(record.payload, &changes); err != nil || len(changes) == 0 {
		return fail(env, "cannot decode the changes in transaction %d", record.id)
	}

	for change in changes {
		if !journal_change_valid(record.scope, change) {
			return fail(env, "invalid path in transaction %d", record.id)
		}
	}

	switch record.phase {
	case .Pending:
		journal_revert(env, database, record.id, changes) or_return
		say(env, "krs: restored the previous state after interrupted transaction %d", record.id)
	case .Settled:
		journal_cleanup(env, database, record.id, changes) or_return
	}
	return true
}

journal_recover :: proc(env: ^Env, scope: Journal_Scope) -> bool {
	filenames := [?]string{JOURNAL_LEGACY_FILENAME, JOURNAL_FILENAME}
	for filename in filenames {
		database := journal_open(env, false, filename) or_return
		if database == nil {
			continue
		}
		defer db.close(database)

		records := journal_list(env, database, scope) or_return
		for record in records {
			journal_recover_record(env, database, scope, record) or_return
		}
	}
	return true
}

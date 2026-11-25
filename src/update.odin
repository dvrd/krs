package krs

// The tag `krs update` picks for each package. `Latest` and `Greatest` are
// both the highest tag: KRS has no registry dist-tags, only vMAJOR.MINOR.PATCH.
Update_Target :: enum {
	Latest,
	Newest,
	Greatest,
	Minor,
	Patch,
	Semver,
}

Update_Format :: enum {
	Group,
	Lines,
	Time,
	Repo,
	Diff,
	Installed_Version,
}

Update_Json :: enum {
	None,
	All,
	Upgraded,
	Deps,
}

// Zero value is .Info, so every Env literal prints everything by default.
Log_Level :: enum i8 {
	Silent  = -4,
	Error   = -3,
	Minimal = -2,
	Warn    = -1,
	Info    = 0,
	Verbose = 1,
}

// Flags of `krs update`, as parsed by `run`.
Update_Options :: struct {
	upgrade:        bool, // -u
	target:         Update_Target, // -t, default .Latest
	filter:         [dynamic]string, // -f, raw patterns
	reject:         [dynamic]string, // -x
	filter_version: [dynamic]string,
	reject_version: [dynamic]string,
	format:         bit_set[Update_Format], // default {.Group}
	json:           Update_Json,
	error_level:    int, // 1 (default) or 2
	global:         bool, // -g
}

UPDATE_TARGET_NAMES :: [Update_Target]string {
	.Latest   = "latest",
	.Newest   = "newest",
	.Greatest = "greatest",
	.Minor    = "minor",
	.Patch    = "patch",
	.Semver   = "semver",
}

UPDATE_FORMAT_NAMES :: [Update_Format]string {
	.Group             = "group",
	.Lines             = "lines",
	.Time              = "time",
	.Repo              = "repo",
	.Diff              = "diff",
	.Installed_Version = "installed-version",
}

LOG_LEVEL_NAMES :: [Log_Level]string {
	.Silent  = "silent",
	.Error   = "error",
	.Minimal = "minimal",
	.Warn    = "warn",
	.Info    = "info",
	.Verbose = "verbose",
}

// Flags followed by a value: `--name=value`, `--name value` or `-n value`.
update_flag_takes_value :: proc(flag: string) -> bool {
	switch flag {
	case "-t", "--target", "-f", "--filter", "-x", "--reject", "--filter-version", "--reject-version",
	     "--format", "-e", "--error-level", "-l", "--loglevel":
		return true
	}
	return false
}

// Flags that only `krs update` takes. `--color` applies to every command.
update_flag_only :: proc(flag: string) -> bool {
	if update_flag_takes_value(flag) {
		return true
	}

	switch flag {
	case "-u", "--upgrade", "-j", "--json-all", "--json-upgraded", "--json-deps", "-g", "--global",
	     "-s", "--silent":
		return true
	}
	return false
}

update_target_parse :: proc(text: string) -> (target: Update_Target, ok: bool) {
	for name, candidate in UPDATE_TARGET_NAMES {
		if name == text {
			return candidate, true
		}
	}
	return .Latest, false
}

// One `--format` value: `name` adds the format, `no-name` removes it.
update_format_parse :: proc(text: string) -> (format: Update_Format, enabled: bool, ok: bool) {
	name := text
	enabled = true
	if len(name) > len("no-") && name[:len("no-")] == "no-" {
		name = name[len("no-"):]
		enabled = false
	}

	for candidate_name, candidate in UPDATE_FORMAT_NAMES {
		if candidate_name == name {
			return candidate, enabled, true
		}
	}
	return .Group, false, false
}

log_level_parse :: proc(text: string) -> (level: Log_Level, ok: bool) {
	for name, candidate in LOG_LEVEL_NAMES {
		if name == text {
			return candidate, true
		}
	}
	return .Info, false
}

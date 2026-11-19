# KRS

KRS is an Odin package manager. It discovers `shared:` imports in the current
project and installs tagged releases into the selected Odin root's `shared/`.

Before editing code, read the [TigerStyle guide](TYGER_STYLE.md) and apply its
principles to Odin. Leave a blank line between consecutive `if` statements.
Keep Git operations in-process through libgit2.

## Build and test

Install Task, Odin, libgit2, SQLite, and pkg-config. The Odin compiler used for
the build needs `shared:kakunou` in its shared collection. The tests also use
the Git CLI to create fixture repositories.

- `task` or `task check` builds KRS and runs the suite.
- `task build` builds the CLI and prints its path.
- `task test` runs the suite on its own.

Set `KRS_CHECK_DIR` to choose the output directory. The default is
`${TMPDIR:-/tmp}/krs-check`.

## Run KRS

Set up `~/.config/krs/config.json` with the parent directories of local Odin
libraries and the GitHub libraries you want KRS to fetch automatically.

```json
{
  "format": 1,
  "source_directories": ["~/dev/odin-libs"],
  "libs": {
    "kessel": {"source": "github", "target": "dvrd/kessel"}
  }
}
```

Run the binary from the Odin project that imports those libraries. Use the path
printed by `task build` if `krs` is outside your `PATH`.

- `krs install` resolves the project's `shared:` imports. With the example config, `import "shared:kessel"` can fetch `dvrd/kessel` automatically when a matching local or cached release is missing. Use `--frozen` to require the versions already recorded in `.krs/packages.json`.
- `krs update` lists newer local tags. Use `krs update surf` to install the latest or `krs update surf@v1.2.3` to select a release.
- `krs fetch dvrd/kessel` selects or refreshes GitHub releases over HTTPS. Then run `krs install` or `krs update kessel`.
- `krs link surf` uses the checkout's live `src/`. `krs unlink surf` restores the recorded release when one is available.

Choose the Odin root with `--root=<path>` or `ODIN_ROOT`. Otherwise KRS uses
`odin root`. Every project using that root sees changes to its `shared/`.
Commit the project's `.krs/packages.json` to record its dependency versions.

GitHub releases are cached in `~/.local/shared/krs/repos/github/<owner>/<repo>`
and must have `vMAJOR.MINOR.PATCH` tags. A populated cache supports offline
installs. The project lockfile keeps the recorded origin and commit. Use
`libs` to choose an owner if two cached repositories share a name or to
give a repository a different import name.

KRS records file publications in
`~/.local/shared/krs/transactions.db`. On the next command using the
same project or Odin root, KRS rolls back an interrupted publication or
finishes cleaning up a settled one before reading the package records.

## Release version

[`src/VERSION`](src/VERSION) holds the stable `vMAJOR.MINOR.PATCH` version.
`task version` reads it from the checkout. `krs --version` reports the
version embedded when the binary was built.

1. Run `task version:patch`, `task version:minor`, or `task version:major`.
   For `v0.x`, use a patch for compatible changes and a minor for breaking
   changes. Starting at `v1.0.0`, use a patch for compatible fixes, a minor for
   compatible features, and a major for breaking changes.
2. Commit `src/VERSION` with the changes included in the release.
3. Run `task release` from a clean checkout. It builds KRS, runs the tests,
   and creates a local annotated tag for that commit when its version is
   higher than all existing release tags. Keep published tags at their
   original commits.

When changing command behavior, check the CLI usage in
[`src/commands.odin`](src/commands.odin) and the package resolution tests in
[`tests/version_test.odin`](tests/version_test.odin).

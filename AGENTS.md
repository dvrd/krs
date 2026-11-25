# KRS

KRS is an Odin package manager. It discovers `shared:` imports in the current
project and installs tagged releases into the selected Odin root's `shared/`.

Before editing code, read the [TigerStyle guide](TYGER_STYLE.md) and apply its
principles to Odin. Leave a blank line between consecutive `if` statements.
Keep Git operations in-process through libgit2.

## Build, test, and install

Install Task, Odin, libgit2, SQLite, and pkg-config. The Odin compiler used for
the build needs `shared:kakunou` in its shared collection. The tests also use
the Git CLI to create fixture repositories.

- `task` or `task check` builds KRS and runs the suite.
- `task build` builds the CLI and prints its path.
- `task test` runs the suite on its own.
- `task install` builds the CLI and installs it as `~/.local/bin/krs`.

Set `KRS_CHECK_DIR` to choose the output directory. The default is
`${TMPDIR:-/tmp}/krs-check`.

Set `KRS_INSTALL_DIR` to override the installation directory, for example
`KRS_INSTALL_DIR=/usr/local/bin task install`. Add the installation directory
to your `PATH` to run `krs` from any project.

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

Set `KRS_NO_ANIMATION=1` to keep terminal colors with static output. Set
`NO_COLOR=1` to turn off colors and animations in `krs` and `task install`.

- `krs install` resolves the project's `shared:` imports. With the example config, `import "shared:kessel"` can fetch `dvrd/kessel` automatically when a matching local or cached release is missing. Use `--frozen` to require the versions already recorded in `.krs/packages.json`.
- `krs update` lists newer local tags. Use `krs update surf` to install the latest or `krs update surf@v1.2.3` to select a release.
- `krs fetch dvrd/kessel` selects or refreshes GitHub releases over HTTPS. Then run `krs install` or `krs update kessel`.
- `krs link surf` uses the checkout's live `src/`. `krs link ls` lists the links and flags broken ones. `krs unlink surf` removes the link from `shared/`. Add `--restore` to install the recorded release in its place.

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

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
`fix:` bumps the patch. `feat:` bumps the minor from `v1.0.0` onward and the
patch on `v0.x`. A `!` after the type or scope, or a `BREAKING CHANGE:` or
`BREAKING-CHANGE:` footer, bumps the major from `v1.0.0` onward and the minor
on `v0.x`. Other commit types only trigger a bump if marked as breaking.

1. Run `task version:next` to see the version selected from the highest-impact
   commit since the latest release tag. Fetch release tags and history if your
   checkout is missing them.
2. Run `task release` from a clean branch that contains the latest release.
   It updates `src/VERSION`, builds and tests KRS, commits the version file as
   `chore(release): vMAJOR.MINOR.PATCH`, and creates a local annotated tag.
   If tagging fails after the commit, rerun `task release` from that commit.

When changing command behavior, check the CLI usage in
[`src/commands.odin`](src/commands.odin) and the package resolution tests in
[`tests/version_test.odin`](tests/version_test.odin).

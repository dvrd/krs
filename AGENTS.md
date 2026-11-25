# KRS

KRS is an Odin package manager. It discovers `shared:` imports in the current
project and installs tagged releases into the selected Odin root's `shared/`.

Before editing code, read the [TigerStyle guide](TYGER_STYLE.md) and apply its
principles to Odin. Leave a blank line between consecutive `if` statements.
Keep Git operations in-process through libgit2.

## Build, test, and install

Install Task, Odin, libgit2 1.2 or newer, SQLite, pkg-config, and the Git CLI.
The tests use Git to create fixture repositories. The compiler's `shared/`
directory must contain `kakunou`. Task reports the missing directory on startup.

KRS pins `shared:kakunou` in its own `.krs/packages.json`. On a new machine,
copy the pinned tag's `src/` into the compiler's `shared/kakunou/`. If you
already have a `krs` binary, run `krs install` in this repository to install
that release. CI runs `KRS_STRICT_TOOLCHAIN=1 task check` on macOS with the
compiler recorded in `ODIN_VERSION`.

`ODIN_VERSION` records the tested compiler as `dev-YYYY-MM:<full commit>`.
Task warns if the running compiler differs. Set `KRS_STRICT_TOOLCHAIN=1`
to make a mismatch fail the build.

- `task` or `task check` builds KRS and runs the suite.
- `task build` builds the CLI with `-o:speed` and prints its path.
- `task test` builds the tests with `-o:none` and runs them.
- `task install` builds the same optimized CLI and installs it as `~/.local/bin/krs`.

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
- `krs status` lists what the Odin root holds for this project and exits 1 when a package is altered, missing, broken or pinned differently.
- `krs install --repair` reinstalls packages whose installed files were changed, at their recorded release. It cannot be combined with `--frozen`.
- `krs update` lists newer tags from the source directories and the GitHub cache. Run `krs fetch` first, or pass `--fetch`, to refresh the cache. Use `krs update surf` to install the latest or `krs update surf@v1.2.3` to select a release. Use `krs update --all` to move every package to its highest compatible tag.
- `krs fetch` with no argument refreshes the GitHub releases of the libraries in `libs`. `krs fetch dvrd/kessel` selects or refreshes one repository over HTTPS. Then run `krs install` or `krs update kessel`. `fetch` takes no `--root`, `--frozen` or `--yes`.
- `krs link surf` uses the checkout's live `src/`. `krs link ls` lists the links and flags broken ones. `krs unlink surf` removes the link from `shared/`. Add `--restore` to install the recorded release in its place. `ls` is reserved after `link`, so a package named `ls` cannot be linked.
- `krs recover` lists interrupted file publications. `krs recover abandon <id>` gives up on one.

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

## What gets installed

KRS installs the `.odin` files under the library's `src/`, or the repository's
own `.odin` files when there is no `src/`, except those under `tests`,
`examples` and `testdata`. It adds every file named by `#load`,
`#load_directory`, `#load_hash` or a relative `foreign import`, in all `when`
branches, and licence files (names starting with `license`, `licence`,
`notice` or `copying`, in any case). A file the code opens at run time without
naming it in one of these ways is not installed. `krs unlink --restore` warns
about files that no Odin file names.

## Non-interactive use

Commands that write ask first. Pass `--yes` in scripts. Use `--frozen` in CI to
fail instead of changing versions. Without a terminal and without `--yes`, KRS
fails with `confirmation is needed`.

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

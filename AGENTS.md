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
- `krs pin surf` holds surf at the release `.krs/packages.json` records; `krs unpin surf` lets it move again. A dependency cannot move a pinned package.
- `krs vendor` copies every dependency, at this project's versions, into `vendor/` and makes every later krs command for this project use it. Commit `vendor/` (if the project's `.gitignore` ignores `vendor/`, change it) and build with `odin build . -collection:shared=vendor`. Links are not available in vendor mode; delete `vendor/` to go back to the Odin root's `shared/`.
- `krs install --repair` reinstalls packages whose installed files were changed, at their recorded release. It cannot be combined with `--frozen`.
- `krs update` checks and lists newer tags from the source directories and the GitHub cache, like npm-check-updates; it changes nothing. It compares with the release `.krs/packages.json` records for this project and groups the upgrades by patch, minor, major version zero and major; pinned packages are shown as held. Run `krs fetch` first, or pass `--fetch`, to refresh the cache. Names filter what is checked (`krs update surf kessel`); `surf@v1.2.3` checks that release. `-t` chooses the target: `latest` or `greatest` (the highest tag, the default), `newest` (the most recent commit), `minor`, `patch` or `semver` (the highest compatible tag). `-f` and `-x` keep or skip names (`name`, `a,b`, `glob*`, `/regex/`, `!name`); `--filter-version` and `--reject-version` do the same for current versions. `--format` adds `time`, `repo`, `diff` or `installed-version` to each row, `no-group` removes the headers and `lines` prints only `name@tag`. `--json-upgraded`, `-j` (`--json-all`) and `--json-deps` print JSON. `-e 2` exits 1 when an upgrade is available, for CI. `-g` checks every package of the Odin root. `-s` and `-l <level>` quiet the output; `--color` forces colors. `krs update -u` writes the chosen versions to `.krs/packages.json` and installs them; pinned packages stay. `krs update -u -t semver` takes compatible versions only (it replaces the removed `--all`). `--install never` only writes the lockfile. With `--install=never`, a later `krs install` asks before moving the Odin root to a breaking version, as usual. `--pin` pins what it chose. When a pinned package differs from the Odin root, the project moves to `vendor/` after you confirm, and only when there is an upgrade to apply; `--yes` confirms.
- `krs update -i` lists the upgrades with check marks; type numbers to toggle them, `a` for all, Enter to apply, `q` to quit. `--interactive-select` picks what starts selected (auto: patch and minor).
- `krs update -u --doctor` runs the tests (`--doctor-test`, default `odin test .`, with `-collection:shared=vendor` in vendor mode) before and after upgrading; if they fail it reverts, tries each upgrade alone, keeps the passing ones and reports the rest. `odin test .` passes trivially in a package without tests. `--doctor-timeout` (`30s`, `10m`, `2h`; default `30m`) stops a test or install command that runs longer and counts it as a failure; it kills the command's whole process group (a child that calls `setsid` escapes); Ctrl-C during a test run stops the tests too. Outside vendor mode every trial install is visible to all projects on the Odin root until it finishes; if a run stops early, krs prints the `krs update -u --yes name@tag …` command that restores the versions from before the run. The recovery command is printed before the trials even at `--loglevel error`; only `--silent` hides it. That command does not remove packages a trial added. The doctor refuses to start when an unpinned package's installed release differs from the one `.krs/packages.json` records; run `krs install` first.
- `krs update --cooldown 7` (or `7d`, `12h`, `30m`) ignores releases whose tag commit is younger than that and falls back to the newest older release. `--format cooldown` shows what it held back.
- `krs update --deep` checks every project under the current directory (each directory with a `.krs/packages.json`, skipping hidden directories and `vendor/`); `--package-file <pattern>` picks projects by lockfile path (`*`, `**`). A nested project's imports belong to it, not to the parent.
- `krs fetch` with no argument refreshes the GitHub releases of the libraries in `libs`. `krs fetch dvrd/kessel` selects or refreshes one repository over HTTPS. Then run `krs install` or `krs update -u kessel`. `fetch` takes no `--root`, `--frozen` or `--yes`.
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

The version comes from Git tags. `task version` prints it for the checkout:
the release tag, or `git describe` output such as `v0.2.0-3-gabc1234`
between releases. Task embeds that value when it builds KRS, and
`krs --version` reports it.

Use [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
`fix:` bumps the patch. `feat:` bumps the minor from `v1.0.0` onward and the
patch on `v0.x`. A `!` after the type or scope, or a `BREAKING CHANGE:` or
`BREAKING-CHANGE:` footer, bumps the major from `v1.0.0` onward and the minor
on `v0.x`. Other commit types only trigger a bump if marked as breaking.

Run `task version:next` to see the version selected from the highest-impact
commit since the latest release tag. Fetch release tags and history if your
checkout is missing them.

Merging a pull request from `develop` into `main` publishes the release
automatically. The release workflow builds and tests KRS at the new version,
creates the tag and the GitHub release on the merge commit, with notes
generated from the commits since the previous release and a macOS arm64
binary (which needs `brew install libgit2`), and fast-forwards `develop` to
the released commit. No release commit is made.

Merge `develop` into `main` with "Create a merge commit". A squash merge
makes the pull request's single commit, not the individual commits, decide
the version bump and the release notes.

If the workflow warns that `develop` has moved, bring the tag into `develop`
by hand: `git fetch --tags && git switch develop && git merge origin/main && git push`.
Until then, `task version:next` on `develop` fails with "this branch must
contain the latest release".

`task release -- --dry-run` previews the release locally: the version, the
notes and the packaged binary. `task release` publishes from a clean local
`main` that is pushed, and needs `gh` to be logged in. It publishes only when
`HEAD` is the current `origin/main`.

When changing command behavior, check the CLI usage in
[`src/commands.odin`](src/commands.odin) and the package resolution tests in
[`tests/version_test.odin`](tests/version_test.odin).

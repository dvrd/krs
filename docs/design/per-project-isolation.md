# Per-project dependency isolation

Status: proposal from a design spike. Nothing here has shipped.

Baseline: KRS at `b1ad55e`. Compiler: `odin version` prints
`dev-2026-11:74d53468b` (branch `experimental` of the local Odin fork). The
spike plan was written against `8c3fa33d2`. The collection code in
`src/main.cpp` is the same at both commits (same line numbers), so the plan's
line references still hold.

In the transcripts below, `$tmp` stands for the spike's temporary directory.
All other text is copied verbatim.

## Problem

KRS installs into one global `<odin root>/shared/`. `AGENTS.md` says so:

> Choose the Odin root with `--root=<path>` or `ODIN_ROOT`. Otherwise KRS uses
> `odin root`. Every project using that root sees changes to its `shared/`.

The maintainer's real root (`/Users/kakurega/dev/oss/Odin/shared`, read-only
inspection) shows what that means in practice:

- All 8 packages in `shared/.krs/manifest.json` are links to checkouts:
  async, aws, kakunou, kessel, saba, surf, websocket, whatsapp, each pointing
  at `~/dev/projects/<name>/src`.
- Two of them, kessel and whatsapp, have an empty `tag`, `commit` and `hash`.
  `krs unlink --restore` has no release to put back for them.
- Four more directories are unmanaged: auth, google, metalized, tigerbeetle.
- `--frozen` refuses links (`plan_frozen_check`, `src/plan.odin:899-905`):
  `return fail(state.env, "--frozen: %s is linked to %s", name, record.linked)`.
  Every project importing one of those 8 libraries therefore cannot use
  `--frozen` on this root.
- `krs link` says it out loud (`src/commands.odin:400`):
  `"%s is linked to %s; every project on this Odin root now builds against it"`.

The project lockfile `.krs/packages.json` records versions, but a single
`shared/` cannot hold two tags of one library, and a `krs link` made for one
project changes every other project on the same root.

The projects already work around this by hand:

- metalized's `Taskfile.yml` passes `COLLECTION: -collection:shared=.task/shared`
  and its `collection` task runs `ln -sfn ../../src .task/shared/metalized`.
- saba's `Taskfile.yml` (`bench:mesa`) runs
  `krs install --frozen --root="$bench_root"` into a `mktemp -d` root, then
  `odin run ... -collection:shared="$bench_shared"`. Its `test` summary says
  the suites use "krs install --frozen in a private, temporary Odin root".
- surf's `Taskfile.yml` takes `SHARED` from `WEBTOOLS_SHARED` (default
  `$HOME/dev/oss/Odin/shared`) and stages `shared:surf` from the checkout.

So the maintainer already isolates per project, using `--root` and
`-collection:shared=`, but only in scripts and only for tests.

## Compiler facts

From `src/main.cpp` at `74d53468b` (identical lines at `8c3fa33d2`):

- `4309-4320`: `base` and `core` are added before any flag is parsed
  ("'core' cannot be (re)defined by the user"). A missing one is a hard error:
  "Cannot find the library collection '%.*s'. Is the ODIN_ROOT set up correctly?".
- `4545`: `parse_build_flags(args)` runs after that.
- `1214-1232`: `-collection:name=path` fails with "Library collection '%.*s'
  already exists with path '%.*s'" if the name exists, and requires the path
  to be an existing directory.
- `4670-4678`: `vendor` and `shared` are added from `odin_root_dir()` only if
  no flag set them. So `-collection:shared=<dir>` replaces the default
  `shared`, and `-collection:core=<dir>` is refused.

From `src/build_settings.cpp` at `74d53468b`, `1199-1219`: `odin_root_dir()`
is `ODIN_ROOT` when set, else the compiler's own directory.

Upstream: `upstream/master` (`f3089c42a`, 2026-11-24) has the same code at
shifted lines: the "already exists" check at `main.cpp:1214`, the `core`
note at `4295`, `parse_build_flags` at `4524`, and the `vendor`/`shared`
defaults at `4645-4652`. `odin_root_dir()` is at `build_settings.cpp:1183`.
The flag-parsing block (`main.cpp:1180-1240` at `74d53468b`, `1177-1237`
upstream) is byte-identical. Upstream behaves the same. This was read from
source, not run.

Experiment (Step 1). `lib_a/v1/shared/greet` and `lib_a/v2/shared/greet`
define `MESSAGE :: "v1"` and `"v2"`. `app/main.odin` imports `shared:greet`
and prints it.

```
$ odin run app -collection:shared=$tmp/lib_a/v1/shared
v1
exit 0
$ odin run app -collection:shared=$tmp/lib_a/v2/shared
v2
exit 0
$ odin run app
$tmp/app/main.odin(4:1) Syntax Error: Path does not exist: shared:greet 
	import "shared:greet" 
	^ 
exit 1
$ odin run app -collection:shared=.../v1/shared -collection:shared=.../v2/shared
Library collection 'shared' already exists with path '$tmp/lib_a/v1/shared'
exit 1
$ odin run app -collection:core=.../v1/shared
Library collection 'core' already exists with path '/Users/kakurega/dev/oss/Odin/core'
exit 1
```

(In the last two commands, `...` is shorthand in the echoed command line only.
The real arguments were full paths.)

Consequences:

- One flag replaces `shared` for a whole build. It cannot be layered: a second
  `-collection:shared=` is an error.
- A build without the flag silently falls back to `<odin root>/shared`. A
  forgotten flag builds against the global versions with no warning.
- `-collection:shared=` needs the directory to exist.

## Options

### (a) Project-local collection

**How it works.** Each project gets its own `shared/`, at
`<project>/.krs/root/shared`, and builds with
`-collection:shared=<project>/.krs/root/shared`. KRS treats `<project>/.krs/root`
as the Odin root. It holds only `shared/`, not `core/`, `base/` or `vendor/`.

**This already works with today's KRS**, with no code change, except that the
directory must exist first. First attempt, without creating it:

```
$ (in projA) $tmp/build/krs install --root=.krs/root --yes
krs: the Odin root $tmp/projA/.krs/root does not exist
exit 1
```

After `mkdir -p projA/.krs/root projB/.krs/root`, with `HOME=$tmp/home`, a
local library `greet` tagged `v1.0.0` (`"v1"`) and `v2.0.0` (`"v2"`), and an
uncommitted working tree printing `"live checkout"`:

```
$ (in projA) $tmp/build/krs install --root=.krs/root --yes
krs will change $tmp/projA/.krs/root/shared:
  install greet v2.0.0 (from $tmp/libs/greet)
krs: 1 installed, 0 already in place
exit 0
$ (in projB) $tmp/build/krs install --root=.krs/root --yes
krs will change $tmp/projB/.krs/root/shared:
  install greet v2.0.0 (from $tmp/libs/greet)
krs: 1 installed, 0 already in place
exit 0
$ (in projB) $tmp/build/krs update greet@v1.0.0 --root=.krs/root --yes
greet v2.0.0 -> v1.0.0 (breaking)
krs will change $tmp/projB/.krs/root/shared:
  replace greet v2.0.0 with v1.0.0 (from $tmp/libs/greet)
krs: 1 installed, 0 already in place
exit 0
$ (in krs021.QTDAbs) odin run projA -collection:shared=$tmp/projA/.krs/root/shared
v2
exit 0
$ (in krs021.QTDAbs) odin run projB -collection:shared=$tmp/projB/.krs/root/shared
v1
exit 0
$ (in projB) $tmp/build/krs link greet --root=.krs/root --yes
krs: greet is linked to $tmp/libs/greet/src; every project on this Odin root now builds against it
exit 0
$ (in krs021.QTDAbs) odin run projB -collection:shared=$tmp/projB/.krs/root/shared
live checkout
exit 0
$ (in krs021.QTDAbs) odin run projA -collection:shared=$tmp/projA/.krs/root/shared
v2
exit 0
$ (in projA) $tmp/build/krs install --frozen --root=.krs/root --yes
krs: 0 installed, 1 already in place
exit 0
$ (in projA) $tmp/build/krs status --root=.krs/root
krs: 1 package(s) in $tmp/projA/.krs/root/shared
  greet installed v2.0.0
krs: everything is in place
exit 0
$ (in projB) $tmp/build/krs install --frozen --root=.krs/root --yes
linked: greet -> $tmp/libs/greet/src
krs: --frozen: greet is linked to $tmp/libs/greet/src
exit 1
$ (in projB) $tmp/build/krs status --root=.krs/root
krs: 1 package(s) in $tmp/projB/.krs/root/shared
  greet linked -> $tmp/libs/greet/src
krs: everything is in place
exit 0
```

Two projects held two tags of one library at once. A link in projB did not
reach projA, and `--frozen` failed only in the project that linked.

A collection that is a symlink farm also works. With
`farm/shared/greet -> $tmp/lib_a/v2/shared/greet`:

```
$ odin run app -collection:shared=$tmp/farm/shared
v2
exit 0
```

**What the user types.** Today:
`mkdir -p .krs/root && krs install --root=.krs/root`, then
`odin build . -collection:shared=.krs/root/shared`. A small follow-up could
let KRS create the directory, and could keep a project-level default so plain
`krs install` picks `.krs/root` without `--root`. A `krs build/run/test`
passthrough that adds the flag was not tried. The Taskfile convention is
enough for the maintainer's projects: metalized and saba already pass
`-collection:shared=`. This repository's own `Taskfile.yml` (`odin` task, line
77) passes no collection and relies on `shared:kakunou` in the global root.

**`--frozen`.** Unchanged code. The refusal becomes per-project because links
are per-project. A project that never links can always use `--frozen`.

**Editors/OLS.** OLS supports collections. The local OLS checkout
(`/Users/kakurega/dev/oss/ols`, `3e757d7`) has a `collections` array of
`{name, path}` in `misc/ols.schema.json`. `src/server/requests.odin:476-518`
resolves a relative `path` against the workspace root. `requests.odin:599`
adds the root's `shared` only when `"shared" not_in config.collections`. The
checker passes every non-builtin collection as `-collection:` flags
(`src/server/check.odin:102-107`). So one line in `ols.json` is enough:
`"collections": [{"name": "shared", "path": ".krs/root/shared"}]`. This was
read from source. OLS was not run.

**Records.**
- Lockfile `.krs/packages.json`: unchanged. It never stores a machine path.
- Manifest: moves to `<project>/.krs/root/shared/.krs/manifest.json`, with
  the same shape. It holds absolute `path`/`linked` values, so it must not be
  committed. `.krs/root/` belongs in `.gitignore` while `.krs/packages.json`
  stays committed. KRS does not write that ignore rule today.
- Journal: unchanged. The scope is already `(project, root)`
  (`src/lock.odin:29`). With `root = <project>/.krs/root` both directories
  are locked and recovery stays per project.
- Scanner: the project walk skips dot directories (`src/select.odin:63`), so
  library sources under `.krs/root/shared` are not read as project imports.
  The second `install --frozen` in projA ("1 already in place") matches that.
- `krs status` (plan 018, landed) already reports one root's state. Given the
  project root it is a per-project report, as shown above. Plan 020
  (`fetch` with no arguments, `update --all`) is not implemented yet. It
  should take the same `--root` default.

**Migration.** Opt-in per project. The global root keeps working for projects
that have not moved, and its 8 links stay where they are. A project moves by
running `krs install --root=.krs/root` and adding the flag to its builds. For
kessel and whatsapp, whose global records have no tag, the project root needs
a tagged release or a fresh `krs link` there. That case was not tried.

**Disk cost.** Each project root holds full copies of its releases. In the
experiment: `16K home/.local/shared/krs`, `8.0K projA/.krs/root/shared`. The
GitHub cache under `~/.local/shared/krs/repos` is already shared between
projects. A content-addressed store with per-project symlinks would avoid the
copies, and the symlink-farm run above shows the compiler accepts it. KRS
hashing and the journal were not tried against such a store.

**Effort.** S for the opt-in (docs, create the root directory, ignore rule,
link message wording). M if KRS also picks the project root by default and
offers a build passthrough.

**Risk.** A build without the flag silently uses the global `shared/`
(Step 1, third command). Unlike option (b), this layout cannot hide the
global root.

### (b) One ODIN_ROOT per project

**How it works.** Each project gets a full Odin root whose `base`, `core` and
`vendor` are symlinks to the compiler's root, plus its own `shared/`.
`ODIN_ROOT` points at it. Built and run in the spike:

```
$ ls -l proot proot/shared
proot:
total 0
lrwxr-xr-x  1 kakurega  wheel  33 25 Nov 09:27 base -> /Users/kakurega/dev/oss/Odin/base
lrwxr-xr-x  1 kakurega  wheel  33 25 Nov 09:27 core -> /Users/kakurega/dev/oss/Odin/core
drwxr-xr-x  3 kakurega  wheel  96 25 Nov 09:27 shared
lrwxr-xr-x  1 kakurega  wheel  35 25 Nov 09:27 vendor -> /Users/kakurega/dev/oss/Odin/vendor

proot/shared:
total 0
lrwxr-xr-x  1 kakurega  wheel  140 25 Nov 09:27 greet -> $tmp/lib_a/v1/shared/greet
$ ODIN_ROOT=$tmp/proot odin root
$tmp/proot/
exit 0
$ ODIN_ROOT=$tmp/proot odin check app -no-entry-point
exit 0
$ ODIN_ROOT=$tmp/proot odin run app
v1
exit 0
$ ODIN_ROOT=$tmp/proot odin check app -no-entry-point -vet -strict-style
exit 0
```

The compiler accepts symlinked `base/` and `core/`, and it builds, links and
runs a program with them.

**What the user types.** `export ODIN_ROOT=$PWD/.krs/root` (for example from
direnv) after creating the symlinks once. Then plain `odin build .` and plain
`krs install` both follow it. KRS reads `ODIN_ROOT` as its default root
(`src/plan.odin:91`).

**`--frozen`.** Per-project, as in (a). The KRS mechanics are the same as
(a), since KRS only touches `<root>/shared`.

**Editors/OLS.** OLS runs `odin root` (`requests.odin:526-553`). That
follows `ODIN_ROOT` only if the editor started OLS with it set. Otherwise
`ols.json` needs `"odin_root_override"`, which the schema documents. Not run.

**Records.** Same as (a). The root just also contains three symlinks.

**Migration.** Same opt-in as (a), plus the symlinks. The symlinks name one
compiler checkout. Switching compilers (the maintainer runs a fork, and
`odin version` already moved from `8c3fa33d2` to `74d53468b` since the plan
was written) needs them re-pointed, or the project builds with a different
compiler's `core` than the binary on `PATH`. Tools that call `$(odin root)`
also follow `ODIN_ROOT`. metalized runs
`sh "$(odin root)/vendor/miniaudio/src/build_miniaudio.sh"` and so would go
through the `vendor` symlink into the real root.

**Effort.** S for docs and a helper that creates the root.

**Risk.** The isolation lives in an environment variable. A shell, CI job or
editor without it silently uses the global root, the same failure as a
forgotten flag in (a), but it is harder to see in a Taskfile. Stale symlinks
after a compiler change.

### (c) Per-project link overlay

**How it works.** Keep the global root for releases, and let a project
override single packages (usually links) for itself only.

Odin has one `shared` per build, and it cannot be layered (Step 1: a second
`-collection:shared=` is an error). So an overlay needs a second collection
name, or option (a)'s mechanism.

With a second collection name, it breaks when a library imports the
overridden package through `shared:`. In the experiment, `greet` (global)
imports `shared:dep`, and the app imports `project:dep` from an overlay:

```
$ odin check ovl/app -no-entry-point -collection:shared=$tmp/ovl/global/shared -collection:project=$tmp/ovl/project
$tmp/ovl/global/shared/dep/dep.odin(1:1) Error: Duplicate declaration of 'package dep' 
	package dep 
	^~~~~~~~~~^ 
	A package name must be unique 
	There is no relation between a package name and the directory that contains it, so they can be completely different 
	A package name is required for link name prefixing to have a consistent ABI 
$tmp/ovl/project/dep/dep.odin(1:1) found at previous location 
$tmp/ovl/app/main.odin(8:17) Error: Cannot assign value 'greet.get()' of type 'Thing (package dep)' to 'Thing (package dep)' in a variable declaration 
	t: dep.Thing = greet.get() 
	               ^~~~~~~~~~^ 
	Suggestion: The expression may be directly casted to type Thing 
exit 1
```

Both copies get compiled, the package names collide, and their types are
distinct. Every library would also need rewriting to import `project:`, so a
second collection name is not viable.

Through (a)'s mechanism, the overlay becomes a project-local symlink farm.
Each entry links either to a release in the global root or to a checkout. The
farm run above shows the compiler accepts it. That is (a) with links into the
global root instead of copies. It brings back the coupling (a) removes: a
`krs update` in another project changes a release this project reads through
its farm. KRS support for such a farm (manifest entries that point into
another root, hash checks across roots) was not tried.

**`--frozen`.** Undefined until the farm's records are designed. **Editors.**
As (a). **Migration.** As (a). **Effort.** M to L. **Risk.** High: two roots
whose records must agree.

## Comparison

| Option | Isolation | Editor support | Migration cost | Implementation effort | Risk |
|---|---|---|---|---|---|
| (a) project-local collection (`.krs/root/shared` + `-collection:shared=`) | Full; verified (v2/v1 side by side, link and `--frozen` per project) | `ols.json` `collections`, relative path (source-verified) | Opt-in per project; add a flag to builds (two of three sampled projects already do) | S (works today after `mkdir`); M with defaults and passthrough | Low; forgotten flag falls back to global root |
| (b) per-project `ODIN_ROOT` | Full; verified (`base`/`core`/`vendor` symlinks accepted) | `ODIN_ROOT` in the editor's environment or `odin_root_override` (source-verified) | Opt-in; env var in every shell, CI and editor; symlinks per compiler | S | Medium; implicit env, stale symlinks after compiler changes |
| (c) overlay over global root | Partial; second collection name fails to compile (verified); farm variant not tried in KRS | As (a) | As (a), plus cross-root records | M to L | High |

## Recommendation

Adopt option (a): a project-local root at `<project>/.krs/root`, used as
`--root` by KRS and as `-collection:shared=` by the compiler and OLS.

Reasons, from the experiments:

- It already works with today's KRS. Two projects ran two tags of one
  library, a link stayed in its project, and `--frozen` failed only where the
  link was. The only failure was the missing directory.
- It needs no compiler support beyond what `main.cpp:4675-4678` gives, and
  upstream has the same code.
- It matches how the maintainer already builds: metalized and saba pass
  `-collection:shared=`, and saba already runs `krs install --frozen --root=`
  into a private root.
- Records and the journal need no format change. The scope is already
  `(project, root)`.
- It keeps (b) open. The same `.krs/root` becomes a full `ODIN_ROOT` by adding
  three symlinks, for anyone who prefers an environment variable to a flag.

Keep the global root as the default for now. Make the project root an opt-in
and document it, so existing projects and their 8 global links keep working.

## Open questions

1. Should KRS use `<project>/.krs/root` by default when it exists, without
   `--root`? If so, what takes precedence: `--root`, `ODIN_ROOT`, the project
   root, or `odin root`?
2. Should `krs link` default to project scope once a project root exists?
   Its message ("every project on this Odin root now builds against it") is
   misleading for a project root and needs new wording either way.
3. Should KRS create the root directory itself, and write `.krs/root/` into
   the project's `.gitignore`, or leave both to the user?
4. Is a build passthrough (`krs build/run/test`) wanted, or is the
   Taskfile/`ols.json` convention enough? A passthrough is the only way to
   make a forgotten flag impossible.
5. Are per-project copies acceptable on disk, or should KRS add a
   content-addressed store with symlink farms (not tried)?
6. Does the spec's single-root assumption (`.cruft/spec.md`, Behaviour step 5
   and the Risks note on links in `shared/`) and its "Out of scope" list
   change to admit project roots?
7. What happens to kessel and whatsapp, which have no recorded tag? They need
   tagged releases before any project can pin them with `--frozen`.

## If accepted

- Document project-local roots in AGENTS.md and the spec
- Create a missing project root on first install and ignore `.krs/root/`
- Pick the project root by default when it exists
- Reword the `krs link` success message by root scope
- Teach `krs fetch`/`update --all` (plan 020) the project root default
- Show the root scope in `krs status`
- Add a `krs build/run/test` passthrough (optional)
- Evaluate a content-addressed store for project roots (optional)

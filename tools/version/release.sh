#!/bin/sh
set -eu

fail() {
    printf 'krs: %s\n' "$*" >&2
    exit 1
}

# Check the commit and index again after running the build and tests.
guard_checkout() {
    current_head=$(git rev-parse --verify HEAD)
    current_status=$(git status --porcelain --untracked-files=all)
    if [ "$current_head" != "$head" ] || [ "$current_status" != "$1" ]; then
        fail "$2"
    fi
}

cleanup() {
    if [ "$restore_version" = true ] &&
       [ "$(git rev-parse --verify HEAD)" = "$head" ] &&
       cmp -s "$scratch/VERSION" "$version_path"; then
        git restore --worktree --source="$head" -- "$version_path" ||
            printf 'krs: could not restore %s after the release failed\n' "$version_path" >&2
    fi
    if [ -n "$staged" ]; then
        rm -f "$staged"
    fi
    rm -rf "$scratch"
}

mode=$1
version_path=src/VERSION
version_tool="${KRS_CHECK_DIR:-${TMPDIR:-/tmp}/krs-check}/krs-version"
head=$(git rev-parse --verify HEAD)
if [ "$mode" = release ]; then
    git symbolic-ref --quiet HEAD >/dev/null || fail 'release from a branch'
    guard_checkout '' 'commit your changes before releasing'
fi

scratch=$(mktemp -d "${TMPDIR:-/tmp}/krs-release.XXXXXX")
staged=
restore_version=false
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

git tag --list 'v*' > "$scratch/tags"
base=$("$version_tool" latest "$scratch/tags")
[ -n "$base" ] || fail 'fetch the release tags before calculating the next version'
base_commit=$(git rev-parse --verify "refs/tags/$base^{commit}")
git merge-base --is-ancestor "$base_commit" "$head" ||
    fail "this branch must contain the latest release $base"

git log -z --format=%B "$base_commit..$head" > "$scratch/commits"
next=$("$version_tool" next "$base" "$scratch/commits")
if [ -z "$next" ]; then
    printf 'krs: no release-worthy commits since %s\n' "$base" >&2
    exit 0
fi

if [ "$mode" = next ]; then
    printf '%s\n' "$next"
    exit 0
fi

commit_message="chore(release): $next"
current=$(git show "$head:$version_path")
if [ "$current" = "$base" ]; then
    guard_checkout '' 'the checkout changed while calculating the next release'
    printf '%s\n' "$next" > "$scratch/VERSION"
    staged=$(mktemp src/.krs-version.XXXXXX)
    cp "$scratch/VERSION" "$staged"
    chmod 644 "$staged"
    restore_version=true
    mv -f "$staged" "$version_path"
    staged=

    task check
    guard_checkout " M $version_path" 'the checkout changed while verifying the release'
    cmp -s "$scratch/VERSION" "$version_path" || fail "$version_path changed during verification"
    git commit --only -m "$commit_message" -- "$version_path"
    head=$(git rev-parse --verify HEAD)
    restore_version=false
else
    # The release commit may already exist if creating its tag failed.
    [ "$current" = "$next" ] || fail "$version_path must match the latest release $base"
    task check
fi

guard_checkout '' 'the checkout changed before tagging the release'
[ "$(git log -1 --format=%s "$head")" = "$commit_message" ] &&
    [ "$(git diff-tree --no-commit-id --name-only -r "$head")" = "$version_path" ] &&
    [ "$(git show "$head:$version_path")" = "$next" ] ||
    fail "expected a release commit changing only $version_path to $next"

git tag --list 'v*' > "$scratch/tags"
[ "$("$version_tool" latest "$scratch/tags")" = "$base" ] ||
    fail 'release tags changed during verification'

git tag -a "$next" -m "KRS $next" "$head"
printf 'krs: tagged %s\n' "$next"

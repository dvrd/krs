#!/bin/sh
# Releases KRS from Conventional Commits.
#
#   release.sh next
#       Print the next release tag, or nothing when no commit since the latest
#       tag calls for a release.
#   release.sh prepare [--dry-run] <dir>
#       Build, test and package the next release from HEAD into <dir>, without
#       network access. <dir>/tag is written last, only when everything worked.
#       --dry-run allows a dirty tree and prints the result.
#   release.sh publish [--sync-develop] <dir>
#       Create the GitHub release prepared in <dir>. --sync-develop (CI only)
#       then fast-forwards develop to the released commit.
#
# A tag pushed by hand without a GitHub release is not detected here; publish
# it by hand with `gh release create <tag> --verify-tag`.
set -eu

fail() {
    printf 'krs: %s\n' "$*" >&2
    exit 1
}

usage() {
    fail 'usage: release.sh next | prepare [--dry-run] <dir> | publish [--sync-develop] <dir>'
}

cleanup() {
    rm -rf "$scratch"
}

out="${KRS_CHECK_DIR:-${TMPDIR:-/tmp}/krs-check}"
version_tool="$out/krs-version"

[ $# -ge 1 ] || usage
mode=$1
shift

scratch=$(mktemp -d "${TMPDIR:-/tmp}/krs-release.XXXXXX")
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Fails unless HEAD is still $head and the tree is clean.
guard_checkout() {
    current_head=$(git rev-parse --verify HEAD)
    current_status=$(git status --porcelain --untracked-files=all)
    if [ "$current_head" != "$head" ] || [ -n "$current_status" ]; then
        fail "$1"
    fi
}

# Sets base, base_commit and next from the release tags and the commits
# between the latest one and $head.
next_release() {
    git tag --list 'v*' > "$scratch/tags"
    base=$("$version_tool" latest "$scratch/tags")
    [ -n "$base" ] || fail 'fetch the release tags before calculating the next version'
    base_commit=$(git rev-parse --verify "refs/tags/$base^{commit}")
    git merge-base --is-ancestor "$base_commit" "$head" ||
        fail "this branch must contain the latest release $base"

    git log -z --format=%B "$base_commit..$head" > "$scratch/commits"
    next=$("$version_tool" next "$base" "$scratch/commits")
}

release_next() {
    [ $# -eq 0 ] || usage
    head=$(git rev-parse --verify HEAD)
    next_release
    if [ -z "$next" ]; then
        printf 'krs: no release-worthy commits since %s\n' "$base" >&2
        exit 0
    fi
    printf '%s\n' "$next"
}

release_prepare() {
    dry_run=false
    if [ "${1:-}" = --dry-run ]; then
        dry_run=true
        shift
    fi
    [ $# -eq 1 ] && [ -n "$1" ] && [ "$1" != / ] || usage
    dist=$1

    head=$(git rev-parse --verify HEAD)
    if [ "$dry_run" = false ]; then
        guard_checkout 'commit your changes before releasing'
    fi

    rm -rf "$dist"
    mkdir -p "$dist"
    next_release
    if [ -z "$next" ]; then
        printf 'krs: no release-worthy commits since %s\n' "$base"
        exit 0
    fi

    git log -z --no-merges --format='%h%n%B' "$base_commit..$head" > "$scratch/notes-log"
    "$version_tool" notes "$base" "$next" "$scratch/notes-log" > "$dist/notes.md"

    KRS_VERSION="$next" task check
    KRS_VERSION="$next" task build
    reported=$("$out/krs" --version)
    [ "$reported" = "krs $next" ] || fail "the release binary reports '$reported', not 'krs $next'"
    if [ "$dry_run" = false ]; then
        guard_checkout 'the checkout changed while building the release'
    fi

    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    arch=$(uname -m)
    if [ "$arch" = x86_64 ]; then
        arch=amd64
    fi
    asset="krs-$next-$os-$arch.tar.gz"
    tar -czf "$dist/$asset" -C "$out" krs
    (cd "$dist" && shasum -a 256 "$asset" > "$asset.sha256")

    printf '%s\n' "$head" > "$dist/target"
    printf '%s\n' "$next" > "$dist/tag"

    if [ "$dry_run" = true ]; then
        printf '\nkrs: release %s of %s (dry run, nothing published)\n\n' "$next" "$head"
        cat "$dist/notes.md"
        printf '\nkrs: assets\n%s\n%s\n' "$dist/$asset" "$dist/$asset.sha256"
    fi
}

release_publish() {
    sync_develop=false
    if [ "${1:-}" = --sync-develop ]; then
        sync_develop=true
        shift
    fi
    [ $# -eq 1 ] && [ -n "$1" ] || usage
    dist=$1

    [ -f "$dist/tag" ] || fail "$dist holds no prepared release"
    tag=$(cat "$dist/tag")
    target=$(cat "$dist/target")
    if [ "$sync_develop" = true ]; then
        [ -n "${GH_TOKEN:-}" ] || fail '--sync-develop needs GH_TOKEN'
        [ -n "${GITHUB_REPOSITORY:-}" ] || fail '--sync-develop needs GITHUB_REPOSITORY'
    fi

    if draft=$(gh release view "$tag" --json isDraft -q .isDraft 2> "$scratch/view-error"); then
        case $draft in
        true)
            fail "draft release $tag exists; publish or delete it"
            ;;
        false)
            printf 'krs: %s is already released\n' "$tag"
            exit 0
            ;;
        *)
            fail "gh release view $tag printed '$draft'"
            ;;
        esac
    fi
    grep -q 'release not found' "$scratch/view-error" || fail "$(cat "$scratch/view-error")"

    set --
    for asset in "$dist/krs-$tag-"*.tar.gz; do
        [ -f "$asset" ] && [ -f "$asset.sha256" ] || fail "$dist holds no package for $tag"
        set -- "$@" "$asset" "$asset.sha256"
    done
    gh release create "$tag" "$@" --target "$target" --title "krs $tag" \
        --notes-file "$dist/notes.md" --latest
    printf 'krs: released %s\n' "$tag"

    if [ "$sync_develop" = true ]; then
        # Fast-forward only: a rejected push means develop moved since the merge.
        if git push "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" "$target:refs/heads/develop"; then
            printf 'krs: develop now contains %s\n' "$tag"
        else
            printf '::warning::develop has moved since the merge; merge main into develop to bring in %s\n' "$tag"
        fi
    fi
}

case $mode in
next)
    release_next "$@"
    ;;
prepare)
    release_prepare "$@"
    ;;
publish)
    release_publish "$@"
    ;;
*)
    usage
    ;;
esac

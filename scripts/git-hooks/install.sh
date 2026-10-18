#!/bin/sh
# Installs this repo's guardrail hooks as self-contained copies in the local
# hooks directory, so they work on every checkout, including master, which has
# no scripts/git-hooks/. Run once per clone, and again after changing anything
# in scripts/git-hooks/. Safe to re-run; it changes nothing unless every
# target is absent, its own earlier copy, or Git LFS's stock hook.
# scripts/git-hooks/selftest.sh checks it end to end.
if [ -n "${ZSH_VERSION-}" ]; then exec /bin/sh "$0" "$@"; fi
set -eu
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY

files="KataGoCJK.pm pre-commit commit-msg pre-push"
self=$(perl -MCwd=abs_path -e 'print abs_path(shift)' "$0")
here=${self%/*}
cr=$(printf '\r')
for name in $files; do
    if [ ! -f "$here/$name" ]; then
        echo "install.sh: $here/$name is missing." >&2
        exit 1
    fi
    if grep -q "$cr" "$here/$name"; then
        echo "install.sh: $here/$name has CRLF line endings; run 'git add --renormalize scripts/git-hooks' and check it out again." >&2
        exit 1
    fi
done
cd "$here"

hooks_path_users=$(git worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r tree; do
    [ -d "$tree" ] || continue
    if [ -n "$(git -C "$tree" config --get core.hooksPath 2>/dev/null || true)" ]; then
        printf '  %s\n' "$tree"
    fi
done)
if [ -n "$(git config --get core.hooksPath || true)" ] || [ -n "$hooks_path_users" ]; then
    echo "install.sh: core.hooksPath is set (here or in a worktree), so git ignores the local hooks directory." >&2
    if [ -n "$hooks_path_users" ]; then printf '%s\n' "$hooks_path_users" >&2; fi
    echo "install.sh: unset it, or install these hooks there by hand." >&2
    exit 1
fi

hooks=$(git rev-parse --path-format=absolute --git-path hooks)
tag="# Managed by scripts/git-hooks/install.sh"

is_stock_lfs() { # file hook-name
    [ "$(wc -l < "$1" | tr -d ' ')" = 3 ] \
        && [ "$(sed -n 1p "$1")" = '#!/bin/sh' ] \
        && sed -n 2p "$1" | grep -q '^command -v git-lfs >/dev/null 2>&1 || {.*exit 2; }$' \
        && [ "$(sed -n 3p "$1")" = "git lfs $2 \"\$@\"" ]
}

# Check every target before touching anything, LFS included.
for name in $files; do
    target="$hooks/$name"
    if [ -L "$target" ]; then
        echo "install.sh: $target is a symlink; installing nothing." >&2
        exit 1
    fi
    if [ ! -e "$target" ]; then continue; fi
    if [ -f "$target" ] && grep -qF "$tag" "$target"; then continue; fi
    if [ "$name" = pre-push ] && [ -f "$target" ] && is_stock_lfs "$target" pre-push; then continue; fi
    echo "install.sh: $target exists and was not installed by this script; installing nothing." >&2
    exit 1
done

# Stage our copies before Git LFS runs, so a failure cannot leave LFS's stock
# pre-push in place of ours.
mkdir -p "$hooks"
stage=$(mktemp -d "$hooks/.katago.XXXXXX")
trap 'rm -rf "$stage"' EXIT
for name in $files; do
    cp "$here/$name" "$stage/$name"
    chmod 755 "$stage/$name"
done

# Let Git LFS lay down its own hooks; our pre-push replaces its stock pre-push
# and keeps calling it.
if git config --get-regexp '^filter\.lfs\.' >/dev/null 2>&1 && command -v git-lfs >/dev/null 2>&1; then
    need_lfs=no
    for name in post-checkout post-commit post-merge; do
        target="$hooks/$name"
        if [ ! -e "$target" ] && [ ! -L "$target" ]; then
            need_lfs=yes
        elif [ -L "$target" ] || ! is_stock_lfs "$target" "$name"; then
            echo "install.sh: $target is not Git LFS's hook; leaving Git LFS's hooks as they are." >&2
            need_lfs=foreign
            break
        fi
    done
    if [ "$need_lfs" = yes ]; then
        git lfs install --local --force >/dev/null 2>&1 \
            || echo "install.sh: 'git lfs install --local' failed; run it by hand, then re-run this script." >&2
    fi
fi

for name in $files; do
    mv -f "$stage/$name" "$hooks/$name"
done
for name in $files; do
    if [ ! -f "$hooks/$name" ] || [ -L "$hooks/$name" ]; then
        echo "install.sh: $hooks/$name did not install." >&2
        exit 1
    fi
done
echo "install.sh: installed pre-commit, commit-msg and pre-push in $hooks."
echo "install.sh: 'git lfs update --force' replaces pre-push and drops these checks; re-run this script after it."

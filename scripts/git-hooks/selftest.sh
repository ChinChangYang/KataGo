#!/bin/sh
# End-to-end check of the guardrail hooks: installs them into a throwaway repo
# and confirms each guard refuses what it should and lets clean work through.
# Run after changing anything in scripts/git-hooks/. Exits non-zero on failure.
if [ -n "${ZSH_VERSION-}" ]; then exec /bin/sh "$0" "$@"; fi
set -u
unset CDPATH GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY

self=$(perl -MCwd=abs_path -e 'print abs_path(shift)' "$0")
src=${self%/*}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/katago-hooks-selftest.XXXXXX")
cleanup() { if command -v trash >/dev/null 2>&1; then trash "$tmp"; else rm -rf "$tmp"; fi; }
trap cleanup EXIT

# Test input is built from bytes so this file itself stays English only.
cjk=$(printf '\344\270\255')       # a Han character
wavy=$(printf '\343\200\260')      # U+3030, an emoji that must pass

failures=0
check() { # description expected(0 pass, 1 refuse) command...
    desc=$1 want=$2
    shift 2
    if "$@" > "$tmp/out" 2>&1; then got=0; else got=1; fi
    if [ "$got" = "$want" ]; then
        echo "PASS  $desc"
    else
        echo "FAIL  $desc"
        sed 's/^/      /' "$tmp/out"
        failures=$((failures + 1))
    fi
}

# Isolate from the user's git configuration.
export HOME="$tmp/home" GIT_CONFIG_NOSYSTEM=1 GIT_EDITOR=: LC_ALL=C
mkdir -p "$HOME"
git init -q --bare "$tmp/remote.git"
git init -q -b master "$tmp/work"
cd "$tmp/work" || exit 1
git config user.name Selftest
git config user.email selftest@example.invalid
git remote add origin "$tmp/remote.git"
mkdir -p scripts
cp -R "$src" scripts/git-hooks
echo scripts/ >> .git/info/exclude

check "install.sh installs" 0 sh scripts/git-hooks/install.sh
check "install.sh re-runs" 0 sh scripts/git-hooks/install.sh

echo hello > a.txt
git add a.txt
check "an English commit passes" 0 git commit -q -m "Add a"
check "a clean master pushes" 0 git push -q origin master

echo "note $cjk" > b.txt
git add b.txt
check "pre-commit refuses an added CJK line" 1 git commit -q -m "Add b"
git reset -q b.txt

check "commit-msg refuses a CJK message" 1 git commit -q --allow-empty -m "Note $cjk"
check "an emoji message passes" 0 git commit -q --allow-empty -m "Ship it $wavy"

git switch -q -c topic
git add b.txt
git commit -q --no-verify -m "Add b"
check "pre-push refuses a CJK line committed with --no-verify" 1 git push -q origin topic
git reset -q --hard HEAD~1

git commit -q --no-verify --allow-empty -m "Note $cjk"
check "pre-push refuses a CJK message committed with --no-verify" 1 git push -q origin topic
git reset -q --hard HEAD~1
check "a clean branch pushes" 0 git push -q origin topic

mkdir ios
echo app > ios/app.txt
git add ios
git commit -q -m "Add the app"
check "pre-push refuses an ios/ tree on master" 1 git push -q origin topic:master
check "the same commit pushes to its own branch" 0 git push -q origin topic

git tag -a -m "Release $cjk" v1
check "pre-push refuses a CJK tag message" 1 git push -q origin v1

git switch -q -c upstream-text master
echo "keep $cjk (upstream)" > up.txt
git add up.txt
GIT_COMMITTER_EMAIL=upstream@example.invalid git commit -q --no-verify -m "Upstream text"
echo "keep $cjk (upstream), edited" > up.txt
git add up.txt
check "an English edit of an existing CJK line passes pre-commit" 0 git commit -q -m "Edit the upstream line"
check "upstream's own commit and that edit push" 0 git push -q origin upstream-text

git clone -q "$tmp/remote.git" "$tmp/agent"
git -C "$tmp/agent" config user.email selftest@example.invalid
git -C "$tmp/agent" config user.name Selftest
git -C "$tmp/agent" switch -q -c agentwork origin/topic
echo "agent $cjk" > "$tmp/agent/agent.txt"
git -C "$tmp/agent" add agent.txt
git -C "$tmp/agent" commit -q -m "Agent notes"
git remote add agent "$tmp/agent"
git fetch -q agent
git switch -q -c integrate agent/agentwork
check "pre-push refuses CJK fetched from a hookless clone" 1 git push -q origin integrate

git switch -q master
check "pre-push refuses a push to ios-dev" 1 git push -q origin master:ios-dev
check "a release push to ios-dev passes with KATAGO_RELEASE=1" 0 env KATAGO_RELEASE=1 git push -q origin master:ios-dev
check "pre-push refuses deleting ios-dev" 1 git push -q origin :ios-dev

if [ "$failures" -eq 0 ]; then
    echo "selftest: all checks passed."
else
    echo "selftest: $failures check(s) failed."
    exit 1
fi

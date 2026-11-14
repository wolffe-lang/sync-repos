#!/bin/sh
# check.sh: run sync-repos against repositories made on the spot, and compare
# what it prints, and what it leaves on disk, with what it should.
# Needs git. Touches nothing outside one new directory, which it removes.
set -u

here=$(cd "$(dirname "$0")" && pwd)
prog="$here/sync-repos"
[ -x "$prog" ] || { echo "check: build first: wolf build sync-repos.lu" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/sync-repos-check.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

fails=0
expect() {  # expect NAME WANT GOT
    if [ "$2" = "$3" ]; then
        echo "ok    $1"
    else
        echo "FAIL  $1"
        echo "--- want"; echo "$2"
        echo "--- got";  echo "$3"
        fails=$((fails + 1))
    fi
}

# Three repositories on a "remote", and no checkouts yet.
export GIT_AUTHOR_NAME=check GIT_AUTHOR_EMAIL=check@example.invalid
export GIT_COMMITTER_NAME=check GIT_COMMITTER_EMAIL=check@example.invalid
for r in alpha beta gamma; do
    git init -q "$work/src/$r"
    ( cd "$work/src/$r" && echo "$r" > README && git add README && git commit -qm "Add README" )
    mkdir -p "$work/remote/acme"
    git clone -q --bare "$work/src/$r" "$work/remote/acme/$r.git"
done
printf '# made by check.sh\nacme=acme:alpha,beta,gamma,missing\n' > "$work/orgs.conf"

export SYNC_REPOS_CONFIG="$work/orgs.conf"
export GITHUB_ORGS_DIR="$work/checkouts"
export SYNC_REPOS_REMOTE="file://$work/remote"
export NO_COLOR=1

# 1. A dry run says what it would do and makes nothing.
got=$("$prog" --dry-run | tail -1)
expect "dry run forecasts four clones" \
    "== a real run would give: Cloned: 4 | Updated: 0 | Skipped: 0 | Failed: 0" "$got"
expect "dry run makes no directory" "no" "$([ -e "$work/checkouts" ] && echo yes || echo no)"

# 2. The first real run clones three and fails one, with status 1.
got=$("$prog" | tail -2); code=$?
expect "first run: three cloned, one failed" \
    "== done: Cloned: 3 | Updated: 0 | Skipped: 0 | Failed: 1
  failed: acme/missing" "$got"
expect "the clones are checkouts" "alpha" "$(cat "$work/checkouts/acme/alpha/README")"
expect "a failed clone leaves nothing" "no" "$([ -e "$work/checkouts/acme/missing" ] && echo yes || echo no)"

# 3. The remote moves; one checkout is dirty; one is in the way.
( cd "$work/src/alpha" && echo more >> README && git commit -qam "More" && git push -q "file://$work/remote/acme/alpha.git" HEAD )
echo scribble >> "$work/checkouts/acme/beta/README"
rm -rf "$work/checkouts/acme/gamma" && mkdir "$work/checkouts/acme/gamma" && echo x > "$work/checkouts/acme/gamma/notes"
printf 'acme=acme:alpha,beta,gamma\n' > "$work/orgs.conf"
got=$("$prog"); code=$?
expect "second run, line by line" "
== acme <- acme
✓ alpha (updated)
⚠ beta (uncommitted changes, skipping)
⚠ gamma (exists but is not a git checkout, skipping)
  Cloned: 0 | Updated: 1 | Skipped: 2 | Failed: 0

== done: Cloned: 0 | Updated: 1 | Skipped: 2 | Failed: 0" "$got"
expect "nothing failed, so status 0" "0" "$code"
expect "the dirty checkout was left alone" "scribble" "$(tail -1 "$work/checkouts/acme/beta/README")"
expect "the pull arrived" "more" "$(tail -1 "$work/checkouts/acme/alpha/README")"

# 4. Calling it wrongly is status 2.
"$prog" --frobnicate >/dev/null 2>&1; code=$?
expect "an unknown option is status 2" "2" "$code"

if [ "$fails" -eq 0 ]; then echo "check: all passed"; else echo "check: $fails failed"; exit 1; fi
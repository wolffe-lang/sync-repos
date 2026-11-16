#!/bin/sh
# check.sh: run sync-repos against repositories made on the spot, and compare
# what it prints, and what it leaves on disk, with what it should.
# Needs git. Touches nothing outside one new directory, which it removes.
# Parts 5 to 7 are about identities, and use no network and no real key.
# Part 8 is about local names for clones.
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

# 5. A named identity's token is held to the same rule as the first one,
#    and so is the directory it lives in. Nothing is cloned or asked.
mkdir "$work/tokens" && chmod 700 "$work/tokens"
printf 'made-up-token\n' > "$work/tokens/work" && chmod 644 "$work/tokens/work"
printf 'acme=acme:alpha\n[work]\nlab=labs:beta\n' > "$work/orgs.conf"
got=$("$prog" --dry-run 2>&1); code=$?
expect "a named identity's exposed token is refused" \
    "sync-repos: $work/tokens/work can be ready by other users; run: chmod 600 $work/tokens/work" "$got"
expect "with status 1" "1" "$code"
chmod 600 "$work/tokens/work" && chmod 755 "$work/tokens"
got=$("$prog" --dry-run 2>&1)
expect "an open tokens directory is refused" \
    "sync-repos: $work/tokens is open to other users; run: chmod 700 $work/tokens" "$got"
got=$("$prog" --dry-run --only acme 2>&1 | tail -1)
expect "an entry that does not use the identity is not held up by it" \
    "== a real run would give: Cloned: 0 | Updated: 0 | Skipped: 0 | Failed: 0" "$got"
chmod 700 "$work/tokens"

# 6. --who with no tokens asks nobody, and says which entries are whose.
rm "$work/tokens/work"
got=$("$prog" --who); code=$?
expect "--who lists identities and their entries" \
    "⚠ [default] has no token at $work/token: public repositories only
    acme <- acme
⚠ [work] has no token at $work/tokens/work: public repositories only
    lab <- labs" "$got"
expect "and that is status 0" "0" "$code"

# 7. Over SSH, each identity clones through its own host. A stand-in for
#    ssh serves each host from a directory of its own: github.com has
#    alpha, and only github-work has beta.
mkdir -p "$work/bin" "$work/hosts/github.com/acme" "$work/hosts/github-work/acme"
git clone -q --bare "$work/src/alpha" "$work/hosts/github.com/acme/alpha.git"
git clone -q --bare "$work/src/beta" "$work/hosts/github-work/acme/beta.git"
cat > "$work/bin/ssh" <<EOF
#!/bin/sh
# Not ssh: note the host asked for, then run the git command that was
# given, in that host's directory.
while [ \$# -gt 0 ]; do
    case \$1 in
        -o|-p|-i|-F|-l) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
host=\${1#*@}; shift
echo "\$host" >> "$work/ssh.log"
cd "$work/hosts/\$host" 2>/dev/null || exit 255
eval "\$*"
EOF
chmod +x "$work/bin/ssh"
unset SYNC_REPOS_REMOTE
export SYNC_REPOS_PROTOCOL=ssh GITHUB_ORGS_DIR="$work/by-ssh"
printf 'acme=acme:alpha,beta\n[work]\nlab=acme:beta\n' > "$work/orgs.conf"
got=$(PATH="$work/bin:$PATH" "$prog"); code=$?
expect "each identity reaches only what its host serves" "
== acme <- acme
→ cloning alpha...
✓ alpha (cloned)
→ cloning beta...
✗ beta (clone failed after 3 attempts)
  Cloned: 1 | Updated: 0 | Skipped: 0 | Failed: 1

== lab <- acme [work]
→ cloning beta...
✓ beta (cloned)
  Cloned: 1 | Updated: 0 | Skipped: 0 | Failed: 0

== done: Cloned: 2 | Updated: 0 | Skipped: 0 | Failed: 1
  failed: acme/beta" "$got"
expect "one failure, so status 1" "1" "$code"
expect "the hosts that were asked" "github-work
github.com" "$(LC_ALL=C sort -u "$work/ssh.log")"
expect "the checkout remembers its identity's host" "git@github-work:acme/beta.git" \
    "$(cd "$work/by-ssh/lab/beta" && git config --get remote.origin.url)"
( cd "$work/src/beta" && echo later >> README && git commit -qam "Later" && git push -q "file://$work/hosts/github-work/acme/beta.git" HEAD )
got=$(PATH="$work/bin:$PATH" "$prog" --only lab | tail -1)
expect "a later run pulls through the same host" \
    "== done: Cloned: 0 | Updated: 1 | Skipped: 0 | Failed: 0" "$got"

# 8. A list can give a clone a directory of its own name. The rename holds
#    for the first clone and every pull after it; a bad one is refused by
#    line; a checkout already under the other name is left where it is.
unset SYNC_REPOS_PROTOCOL
export SYNC_REPOS_REMOTE="file://$work/remote" GITHUB_ORGS_DIR="$work/renamed"
printf 'acme=acme:alpha>a,beta\n' > "$work/orgs.conf"
got=$("$prog"); code=$?
expect "a renamed clone is reported with an arrow" "
== acme <- acme
→ cloning alpha → a...
✓ alpha → a (cloned)
→ cloning beta...
✓ beta (cloned)
  Cloned: 2 | Updated: 0 | Skipped: 0 | Failed: 0

== done: Cloned: 2 | Updated: 0 | Skipped: 0 | Failed: 0" "$got"
expect "it is in the directory the list named" "alpha" "$(head -1 "$work/renamed/acme/a/README")"
expect "and in no other" "no" "$([ -e "$work/renamed/acme/alpha" ] && echo yes || echo no)"
( cd "$work/src/alpha" && echo again >> README && git commit -qam "Again" && git push -q "file://$work/remote/acme/alpha.git" HEAD )
got=$("$prog" | grep alpha)
expect "a renamed checkout is pulled" "✓ alpha → a (updated)" "$got"
printf 'acme=acme:alpha>a\nmore=acme:beta>-x\n' > "$work/orgs.conf"
got=$("$prog" 2>&1); code=$?
expect "a local name git would read as an option is refused by line" \
    "sync-repos: $work/orgs.conf: line 2: the local name \`-x\` starts with \`-\`" "$got"
expect "with status 1" "1" "$code"
printf 'acme=acme:alpha,beta\n' > "$work/orgs.conf"
got=$("$prog" | grep alpha)
expect "a removed rename leaves the checkout where it is" \
    "⚠ alpha (already checked out as a; move it to alpha, or list it as alpha>a)" "$got"
printf 'acme=acme:alpha>a,beta>b\n' > "$work/orgs.conf"
got=$("$prog" | grep beta)
expect "an added rename leaves the checkout where it is" \
    "⚠ beta → b (already checked out as beta; move it to b, or remove the rename)" "$got"
expect "and neither made a second copy" "a beta" "$(echo $(ls "$work/renamed/acme"))"

if [ "$fails" -eq 0 ]; then echo "check: all passed"; else echo "check: $fails failed"; exit 1; fi
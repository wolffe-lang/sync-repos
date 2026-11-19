#!/bin/sh
# check.sh: run sync-repos against repositories made on the spot, and compare
# what it prints, and what it leaves on disk, with what it should.
# Needs git. Touches nothing outside one new directory, which it removes.
# Parts 5 to 7 are about identities, and use no network and no real key.
# Part 8 is about local names for clones; part 9 about a diff git cannot
# answer; parts 10 and 11 about saying what is being done while it is done.
# Part 11 needs python3, for a terminal, and is not run without it.
set -u

here=$(cd "$(dirname "$0")" && pwd)
prog="$here/sync-repos"
[ -x "$prog" ] || { echo "check: build first: wolf build sync-repos.lu" >&2; exit 2; }

work=$(mktemp -d "${TMPDIR:-/tmp}/sync-repos-check.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT

# Nothing here reads the caller's own files or runs the caller's shell.
mkdir "$work/home"
export HOME="$work/home" SHELL=/bin/sh

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

# 9. A diff git cannot answer is not taken for uncommitted changes. A
#    stand-in passes every command to git but `diff`, which refuses.
mkdir -p "$work/refusing"
real_git=$(command -v git)
cat > "$work/refusing/git" <<EOF
#!/bin/sh
[ "\$1" = diff ] && { echo 'not yet implemented: diff attributes' >&2; exit 2; }
exec "$real_git" "\$@"
EOF
chmod +x "$work/refusing/git"
printf 'acme=acme:alpha>a\n' > "$work/orgs.conf"
got=$(SYNC_REPOS_GIT="$work/refusing/git" "$prog" | grep alpha)
expect "a diff with no answer is not called uncommitted changes" \
    "⚠ alpha → a (git could not check it for changes, skipping)" "$got"

# 10. A step is named before it starts, not once it has ended. A slow
#     stand-in answers the quick questions at once; its pull writes
#     progress to standard error as git does, says it has started, and
#     waits to be let go (twenty seconds at most). What sync-repos has
#     printed is read while the pull is still held.
mkdir -p "$work/slow" "$work/held-up/acme/slow/.git"
cat > "$work/slow/git" <<EOF
#!/bin/sh
echo "\$*" >> "$work/slow/asked"
case \$1 in
    rev-parse) echo 0123456789abcdef0123456789abcdef01234567 ;;
    diff) exit 0 ;;
    clone)
        for last; do :; done
        echo 'Receiving objects: 100% (3/3), done.' >&2
        mkdir -p "\$last/.git" ;;
    pull)
        printf 'Receiving objects:  50%% (1/2)\\r' >&2
        : > "$work/slow/held"
        n=0
        while [ ! -e "$work/slow/go" ] && [ \$n -lt 20 ]; do sleep 1; n=\$((n + 1)); done
        echo 'Receiving objects: 100% (2/2), done.' >&2 ;;
    *) exit 1 ;;
esac
EOF
chmod +x "$work/slow/git"
held() {  # wait for the stand-in's pull to start, twenty seconds at most
    n=0
    while [ ! -e "$work/slow/held" ] && [ $n -lt 20 ]; do sleep 1; n=$((n + 1)); done
}
export GITHUB_ORGS_DIR="$work/held-up"
printf 'acme=acme:slow,fresh\n' > "$work/orgs.conf"
SYNC_REPOS_GIT="$work/slow/git" "$prog" > "$work/slow/out" 2> "$work/slow/err" &
pid=$!
held
during=$(tail -1 "$work/slow/out")
: > "$work/slow/go"
wait "$pid"; code=$?
expect "a pull is named while it is still running" "→ slow: pull --ff-only…" "$during"
expect "with standard error not a terminal, every step is named, in order" "
== acme <- acme
→ slow: rev-parse HEAD…
→ slow: diff --quiet…
→ slow: diff --cached --quiet…
→ slow: rev-parse HEAD…
→ slow: pull --ff-only…
→ slow: rev-parse HEAD…
✓ slow (up to date)
→ fresh: clone…
✓ fresh (cloned)
  Cloned: 1 | Updated: 0 | Skipped: 0 | Failed: 0

== done: Cloned: 1 | Updated: 0 | Skipped: 0 | Failed: 0" "$(cat "$work/slow/out")"
expect "and nothing the stand-in wrote to standard error is passed on" "" "$(cat "$work/slow/err")"
expect "and the clone is asked to be quiet" "clone --quiet file://$work/remote/acme/fresh.git fresh" \
    "$(grep '^clone' "$work/slow/asked")"
expect "and that is status 0" "0" "$code"

# 11. With standard error a terminal, what a slow step writes there
#     reaches the terminal while the step runs. Standard output is still a
#     file, so this is about standard error alone. Needs python3 for the
#     terminal; without it the row is not run, and says so.
skips=0
if command -v python3 >/dev/null 2>&1; then
    cat > "$work/slow/on-a-terminal.py" <<'EOF'
# on-a-terminal.py HELD GO OUT CMD...: run CMD with standard error on a new
# terminal and standard output in OUT. Print what reached the terminal by
# the time HELD exists (and two seconds after, at most), then make GO and
# print the rest after a line of dashes.
import os, pty, subprocess, sys, time

held, go, out = sys.argv[1:4]
master, slave = pty.openpty()
with open(out, "wb") as to:
    child = subprocess.Popen(sys.argv[4:], stdin=subprocess.DEVNULL, stdout=to, stderr=slave)
os.close(slave)
os.set_blocking(master, False)

def read():
    try:
        return os.read(master, 65536)
    except OSError:
        return b""

def shown(data):
    text = data.decode("utf-8", "replace").replace("\r", "\n")
    return [line for line in text.split("\n") if line]

seen = b""
limit = time.time() + 20
while time.time() < limit and not os.path.exists(held):
    seen += read()
    time.sleep(0.05)
limit = time.time() + 2
while time.time() < limit and b"50%" not in seen:
    seen += read()
    time.sleep(0.05)
print("\n".join(shown(seen)))
print("---")
open(go, "w").close()
rest = b""
while child.poll() is None:
    rest += read()
    time.sleep(0.05)
rest += read()
print("\n".join(shown(rest)))
sys.exit(child.returncode)
EOF
    rm -rf "$work/slow/held" "$work/slow/go" "$work/slow/asked" "$work/held-up/acme/fresh"
    got=$(SYNC_REPOS_GIT="$work/slow/git" python3 "$work/slow/on-a-terminal.py" \
        "$work/slow/held" "$work/slow/go" "$work/slow/out" "$prog"); code=$?
    expect "a terminal sees a slow step's progress while it runs, and the rest after" \
        "Receiving objects:  50% (1/2)
---
Receiving objects: 100% (2/2), done.
Receiving objects: 100% (3/3), done." "$got"
    expect "and the clone is not asked to be quiet" "clone file://$work/remote/acme/fresh.git fresh" \
        "$(grep '^clone' "$work/slow/asked")"
    expect "and standard output names the same steps" "→ fresh: clone…" "$(grep fresh: "$work/slow/out")"
    expect "and that is status 0" "0" "$code"
else
    echo "SKIP  a terminal sees a slow step's progress (no python3)"
    skips=$((skips + 1))
fi

if [ "$fails" -ne 0 ]; then echo "check: $fails failed"; exit 1; fi
if [ "$skips" -eq 0 ]; then echo "check: all passed"; else echo "check: passed, $skips not run"; fi

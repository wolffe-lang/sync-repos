# sync-repos

Clone every repository of the GitHub organizations you list, and fast-forward
the ones you already have. Written in wolf, for PAX first; it also builds on
Linux and macOS.

It needs no `gh`: the list of an organization's repositories comes from
GitHub's API over HTTPS, and the cloning and pulling is done by `git` (on PAX,
`den`).

## Configuration

`~/.config/sync-repos/orgs.conf`, one line per organization:

    # local directory = organization
    wolffe-lang=wolffe-lang
    # or name the repositories and skip the listing
    mine=someone:dotfiles,notes

Repositories land under `~/GithubOrgs/<local directory>/`. An item such as
`dotfiles>dots` gives its checkout the directory `dots`; the repository keeps
its own name on GitHub. See `orgs.conf.example`.

A `[work]` header makes the following entries use the token in
`~/.config/sync-repos/tokens/work`. Entries before any header use
`~/.config/sync-repos/token`; `[default]` goes back to that identity. Tokens
are optional for public repositories. Token files must have mode 600, and
the `tokens` directory mode 700. `./sync-repos --who` checks whose token each
identity has and lists its entries without syncing.

`SYNC_REPOS_CONFIG` overrides the config path; token files sit beside it.
`GITHUB_ORGS_DIR` overrides the checkout root. `SYNC_REPOS_PROTOCOL=ssh`
clones over SSH instead of HTTPS: the default identity uses `github.com`,
and a named identity uses the host alias `github-NAME`, which must be set up
with its key in `~/.ssh/config`. HTTPS clones use git's own authentication;
the tokens here are for the API listing.

## Build and run

The finished source is through chapter 19 of the guide.

```sh
wolf build sync-repos.lu
wolf test
sh ./check.sh
./sync-repos --dry-run
./sync-repos
```

`tools/fetch-toolchain` stages the wolf that `wolf-toolchain.toml` pins by
digest into `.wolf-bin/`; CI builds and tests with it (`.wolf-bin/wolf`) on
Linux and macOS.

`python3 -I tools/check-public-text` checks that the documents, comments and
CI files hold no internal work-item ids, machine names or planning paths
(`--self-test` holds the check to its own cases); `public-text.yml` runs both
on every pull request.

`--only NAME` selects one entry by its local directory or organization.
Dirty checkouts and checkouts that cannot fast-forward are left alone, as
are repositories already checked out under another name, and checkouts git
could not check for changes (a `diff --quiet` that exits with neither 0 nor
1). Submodules are updated after a successful clone or pull. A local git
question may take up to 10 minutes; one that takes longer ends the run,
naming the command and the checkout. Each clone attempt, pull or submodule
update may take up to 30 minutes; a pull or submodule update that takes
longer counts as that repository's failure, and the run goes on.

Each clone attempt, pull and submodule update is named on standard output
before it starts, as `→ REPO: STEP…`, so a step that takes minutes is never
silent. The quick local questions are not named. When standard error is a
terminal, a named step also writes its own progress there as it runs, and a
clone is not asked to be quiet. When it is not a terminal (a pipe, a file, a
job's log), nothing git writes to standard error is passed on, and the
output is the same from run to run.

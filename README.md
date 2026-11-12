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

Repositories land under `~/GithubOrgs/<local directory>/`. See
`orgs.conf.example`.

## Status

Nothing is built yet. The program is written by following a guide, one
chapter at a time.

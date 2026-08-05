# BranchPilot

A GitKraken-class git GUI for Linux desktop. BranchPilot wraps the system
`git` command-line tool directly — there is no libgit2, no native git
bindings, and no bundled git binary. Authentication stays exactly where it
already lives: your system's git credential helpers and `ssh-agent`. The app
never sees, stores, or asks for a password — it just shells out to `git` the
same way a terminal would.

Built with Flutter (Linux desktop target) and Riverpod for state management.

## Screenshots

None yet — this machine builds and tests BranchPilot headlessly (GNOME
Wayland here blocks the screenshot APIs a build agent would otherwise use),
so no real window capture exists to show honestly. Screenshots will be added
once the app has had a first real interactive run. In the meantime, `flutter
test integration_test/*.dart -d linux` is the actual proof the UI works —
every flow below is driven end-to-end against a real windowed build.

## Features

**Repository tabs & live status** — open several repositories at once in
tabs; each tracks its own working-tree status (`git status --porcelain=v2`)
and refreshes automatically when files change on disk, a commit lands, or a
ref moves, via a debounced filesystem watch on the worktree and `.git`.

**Commit graph** — a lane-based visual history (`git log --all
--date-order`), rendered with persistent per-branch lanes, curved merge/fork
edges, hollow rings for merge commits, and colour-coded ref chips for
branches, tags, remotes, and HEAD. Loads 500 commits at a time with
load-more on scroll.

**Hunk-level diff staging** — a unified-diff viewer with syntax
highlighting. Stage or unstage a whole file, or an individual hunk, straight
from the diff view; untracked files show as new-file diffs. Renamed files
are handled correctly on both the stage and unstage paths.

**Commit & amend** — a subject/body editor with a 72-column guide, an amend
toggle that prefills the previous commit message, and a commit button gated
on there being something to commit. The commit-detail pane shows any graph
node's full metadata, stat summary, and per-file diffs.

**Branches, merge & stash** — create/checkout/rename/delete branches
(unmerged deletes require a confirmed force), see ahead/behind counts
against upstream, merge one branch into another with in-app conflict
resolution (take-ours/take-theirs/mark-resolved, then continue or abort).
Stash push (with an optional message and include-untracked), list, preview
as a diff, apply, pop, or drop.

**Remotes** — fetch, pull, and push with real streaming progress in a task
strip (not a spinner — the actual `git` output as it arrives). Pushing a
branch with no upstream sets one automatically; force-push requires typing
the branch name to confirm, since it rewrites the remote.

**Interactive rebase** — pick a base commit from the graph and get a
drag-to-reorder todo list with a per-row action (pick / reword / squash /
fixup / drop). Runs as a real `git rebase -i` under the hood (via
`GIT_SEQUENCE_EDITOR`/`GIT_EDITOR` helper scripts, not a re-implementation of
rebase), so a conflict pause behaves exactly like the CLI: resolve, then
continue, skip, or abort from the same conflict UI merge uses. Reopening a
repository mid-rebase resumes the UI state correctly.

**Tags, cherry-pick, revert, reset, worktrees, file history** — create
annotated or lightweight tags (and push them individually); cherry-pick or
revert any commit with the same conflict flow as merge/rebase; reset
soft/mixed/hard from any graph node (hard reset requires typing the branch
name); list, add, and remove worktrees; view a file's full commit history
(following renames) with inline diffs.

## Keyboard shortcuts

| Shortcut     | Action                                                              |
|--------------|----------------------------------------------------------------------|
| `Space`      | Stage/unstage the file currently selected in the diff view           |
| `Ctrl+Enter` | Commit (or amend) — same as clicking the commit box's button, works even while the cursor is in the subject/body field |
| `F5`         | Fetch all remotes — same as clicking the header's Fetch button       |

`Space` is ignored while a text field (e.g. the commit subject/body) has
focus, so typing a literal space never gets hijacked into staging a file.

## Building from source

Requires the Flutter SDK with the Linux desktop target enabled.

```sh
flutter pub get
flutter build linux --release
```

The built app is at `build/linux/x64/release/bundle/branch_pilot`.

## Installing

### Snap

```sh
sudo snap install branchpilot
```

The snap is strictly confined, which has two consequences worth knowing
before you hit them:

```sh
sudo snap connect branchpilot:ssh-keys   # required for SSH remotes
```

A confined application cannot read hidden files at the top of your home
directory, so your `~/.gitconfig` is not visible to it. Set your identity
per repository (`git config user.name` / `user.email`) — the commit box
writes repository-local configuration, so committing from the app works
without any global setup. Repositories themselves are fully accessible;
only top-level dotfiles are not.

If you want the app to use your global git configuration, credential
helpers and `ssh-agent` exactly as your shell does, install the `.deb`
below instead — it is unconfined.

### `.deb` (Debian/Ubuntu)

```sh
sudo dpkg -i branchpilot_1.0.0_amd64.deb
```

This installs the app under `/usr/lib/branchpilot`, a thin launcher at
`/usr/bin/branchpilot`, a `.desktop` entry, and hicolor icons at the
standard sizes. Launch it as `branchpilot` from a terminal or from your
desktop environment's application menu.

To build the package yourself from a clean checkout:

```sh
flutter build linux --release
python3 tool/make_icon.py       # generates assets/icon/branchpilot_<size>.png
packaging/build_deb.sh          # writes dist/branchpilot_<version>_amd64.deb
```

## Architecture

Every git invocation goes through a single chokepoint, `lib/git/git_cli.dart`
(`GitCli`): `git --no-pager -c color.ui=false -C <repo> ...`, with a
sanitized environment and NUL-separated (`-z`) output wherever git supports
it. Nothing else in the app calls `Process` for git directly. Output
parsing (`git log`, `git status --porcelain=v2`, unified diffs, `for-each-ref`,
...) lives in `lib/git/parsers/` as pure functions with no `dart:io`
dependency, which is where most of the test suite's weight sits. State is
Riverpod: a per-repository status provider drives a filesystem watcher and
cascades to everything else (branches, tags, stashes, worktrees, remote
branches, the commit graph) automatically whenever it refreshes — there is
no separate cache-invalidation layer to keep in sync by hand.

There is no libgit2, no git2dart, and no vendored git binary: BranchPilot is
purely a UI and orchestration layer over whatever `git` is already installed
on the system.

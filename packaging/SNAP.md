# Publishing BranchPilot to the Snap Store

## Current state

**Published.** `branchpilot` 1.0.0 (revision 2, strict) is released to the
`stable` channel:

```sh
sudo snap install branchpilot
```

## A sequencing trap that cost an extra step here

Revision 1 was a *classic*-confinement build. Classic is never granted
automatically, so it went into the manual-review queue — and a revision
sitting in review **blocks every later release of that snap**, not just
itself. Revision 2 (the strict build that was always the one to ship)
uploaded fine but every release attempt failed with:

```
resource-not-ready: Snap cannot be published due to inconsistent state
```

Clearing it needs a manual click at
`https://dashboard.snapcraft.io/snaps/branchpilot/revisions/<n>/` →
**Available actions** → **Reject and remove from review queue**. This
resisted browser automation: the click does not submit and the renderer
stops responding, which looks like a JavaScript confirmation dialog the
automation cannot reach.

**So: do not upload a build whose confinement is not already approved.**
Check `snapcraft revisions branchpilot` before assuming an upload is
releasable, and verify with `snapcraft status branchpilot` — "This snap has
no released revisions" means nothing shipped.

## Confinement: why strict, and what it costs

This snap follows the SecureShell Go pattern — `plugin: flutter` plus the
`gnome` extension under **strict** confinement — because that passes
automated review and can be released immediately.

Strict confinement genuinely constrains this application, and the limits are
stated in the snap's description so users meet them before they bite:

* **`~/.gitconfig` is invisible.** The `home` interface exposes non-hidden
  files only. A repository's nested `.git/` is fine (its parent path is not
  hidden), but the user's top-level `~/.gitconfig` is not — so git inside the
  snap sees no `user.name`/`user.email` and no `credential.helper`. Identity
  must be set per repository.
* **`~/.ssh` needs a manual connection**: `sudo snap connect
  branchpilot:ssh-keys`. The interface is not auto-connected.
* **The ssh-agent socket is unreachable.** It lives under `/run/user/<uid>`
  and no interface exposes it, so agent-backed auth does not work; keys are
  read from `~/.ssh` directly via the `ssh-keys` interface.
* **git ships inside the snap** (`stage-packages: git, openssh-client,
  ca-certificates, less`), because a confined app cannot execute the host's
  binary. `GitCli` falls back from `/usr/bin/git` to the first `git` on
  `PATH`, which resolves to the bundled one.

Classic confinement would remove all four limits and is arguably the correct
model for a git GUI (`code` and the JetBrains snaps are classic for the same
reasons). It requires a manual request at
<https://forum.snapcraft.io/c/store-requests/classic-confinement/26>
justifying the technical need — the four points above are that
justification, if it is ever worth pursuing.

## Building

```bash
snapcraft --use-lxd
```

Produces `branchpilot_1.0.1_amd64.snap` in the repository root. Run on an
arm64 machine it produces `branchpilot_1.0.1_arm64.snap` instead: the
`architectures:` list in `snap/snapcraft.yaml` builds on each architecture it
runs on. CI builds both on every push, installs each one confined
(`snap install --dangerous`) and starts it under Xvfb on its own architecture,
then keeps them as workflow artifacts (`snap-amd64` and `snap-arm64`). It never
uploads them.

Two build failures hit on the original machine, recorded so they are not
rediscovered:

* **`Failed to refresh package list: failed to run apt update`** — a flaky
  Ubuntu mirror fetch inside the freshly launched build container, not a
  configuration problem. Prime the instance and retry:

  ```bash
  C=$(lxc --project snapcraft list -c n --format csv | grep branchpilot)
  lxc --project snapcraft start "$C"
  lxc --project snapcraft exec "$C" -- sh -c \
    'printf "Acquire::Retries \"6\";\nAcquire::ForceIPv4 \"true\";\n" \
     > /etc/apt/apt.conf.d/99retries'
  lxc --project snapcraft exec "$C" -- apt-get update
  ```

* **`Could NOT find PkgConfig`** — the `flutter` plugin fetches the SDK but
  not the GTK toolchain the Linux desktop target compiles against. The
  `build-packages` list in `snap/snapcraft.yaml` covers this.

## Uploading

```bash
snapcraft upload --release=stable branchpilot_1.0.1_amd64.snap
snapcraft upload --release=stable branchpilot_1.0.1_arm64.snap   # the arm64 build
```

Uploading a build whose confinement is not yet approved puts it in the review
queue and **blocks every later upload of the same snap** until that revision
is rejected or approved. Check `snapcraft revisions branchpilot` before
assuming an upload is releasable.

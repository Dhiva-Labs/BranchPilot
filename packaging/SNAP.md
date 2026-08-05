# Publishing BranchPilot to the Snap Store

## Current state

* The `branchpilot` name is **registered**.
* **Revision 1** is a *classic*-confinement build. Classic is not granted
  automatically, so it went into the manual-review queue.
* **Revision 2** is the *strict*-confinement build (the one to ship). It
  uploaded, but it **cannot be released while revision 1 sits in review** —
  the store reports `resource-not-ready: Snap cannot be published due to
  inconsistent state` for any release attempt.

### To finish publishing

1. Open <https://dashboard.snapcraft.io/snaps/branchpilot/revisions/1/>
2. Under **Available actions**, click **Reject and remove from review
   queue**. (Browser automation could not drive this button — the click does
   not submit and the renderer stops responding, which looks like a
   JavaScript confirmation dialog it cannot reach. It is a two-second manual
   click.)
3. Then release the strict build:

   ```bash
   snapcraft release branchpilot 2 stable
   ```

Verify with `snapcraft status branchpilot` — it should stop saying "This snap
has no released revisions".

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

Produces `branchpilot_1.0.0_amd64.snap` in the repository root.

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
snapcraft upload --release=stable branchpilot_1.0.0_amd64.snap
```

Uploading a build whose confinement is not yet approved puts it in the review
queue and **blocks every later upload of the same snap** until that revision
is rejected or approved. Check `snapcraft revisions branchpilot` before
assuming an upload is releasable.

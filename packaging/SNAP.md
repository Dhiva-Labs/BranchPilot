# Publishing BranchPilot to the Snap Store

## Status

The `branchpilot` name is registered and `1.0.0` has been uploaded. It is
**held in manual review** because the snap declares classic confinement,
which is not granted automatically. Until that request is approved the snap
cannot be released to a channel.

## Building

```bash
snapcraft --use-lxd
```

Produces `branchpilot_1.0.0_amd64.snap` in the repository root.

Two failure modes hit while building this on the original machine, both
recorded here so they are not rediscovered:

* **`Failed to refresh package list: failed to run apt update`** — a flaky
  Ubuntu mirror fetch inside the freshly launched build container, not a
  configuration problem. Forcing IPv4 and adding retries inside the
  instance clears it:

  ```bash
  C=$(lxc --project snapcraft list -c n --format csv | grep branchpilot)
  lxc --project snapcraft start "$C"
  lxc --project snapcraft exec "$C" -- sh -c \
    'printf "Acquire::Retries \"6\";\nAcquire::ForceIPv4 \"true\";\n" \
     > /etc/apt/apt.conf.d/99retries'
  lxc --project snapcraft exec "$C" -- apt-get update
  ```

* **`Could NOT find PkgConfig`** — the `flutter` plugin fetches the SDK but
  does not pull in the GTK toolchain the Linux desktop target compiles
  against. The `build-packages` list in `snap/snapcraft.yaml` covers this.

## Uploading

```bash
snapcraft upload branchpilot_1.0.0_amd64.snap
```

Once classic confinement is granted, release it:

```bash
snapcraft upload --release=stable branchpilot_1.0.0_amd64.snap
```

## The classic-confinement request

This has to be posted by a human to the Snap Store forum, under
<https://forum.snapcraft.io/c/store-requests/classic-confinement/26>. Paste
the following as the request body.

---

**Request: classic confinement for `branchpilot`**

BranchPilot is a graphical git client for the Linux desktop. It deliberately
implements no git logic of its own and stores no credentials: every operation
shells out to the user's own `git` binary, and all authentication is left to
git's existing credential helpers and `ssh-agent`.

That design is incompatible with strict confinement for four separate
reasons, none of which an interface can resolve:

1. **`~/.gitconfig` is unreachable.** The `home` interface grants access to
   non-hidden files only. A repository's nested `.git/` directory is
   reachable because its parent path is not hidden, but the user's top-level
   `~/.gitconfig` is not. Without it git has no `user.name`/`user.email`, so
   every commit fails, and no `credential.helper` configuration is visible.

2. **`~/.ssh` is unreachable.** Also a top-level hidden directory. The
   `ssh-keys` interface can grant it, but it is not auto-connected, so the
   default install is broken for any SSH remote.

3. **The ssh-agent socket is unreachable.** It lives under
   `/run/user/<uid>` and no interface exposes it, so agent-backed push and
   pull fail even with `ssh-keys` connected.

4. **The user's git and its credential helpers are outside the snap.** A
   credential helper is an arbitrary executable named in the user's git
   configuration and may live anywhere on `PATH`. Bundling a git binary in
   the snap would not help: it would be a different git than the one the
   user configured, and could not invoke their helpers.

This is the same category as the existing classic developer-tool snaps
(`code`, the JetBrains IDEs), which need equivalent access to the user's
toolchain and dotfiles.

Source: <https://github.com/Dhiva-Labs/BranchPilot>

---

## If classic is declined

The fallback is strict confinement with `ssh-keys` and `network` plugged and
a documented `snap connect` step, accepting that `~/.gitconfig` stays
invisible — which means the app must then write repository-local identity
config itself rather than relying on the user's global settings. That is a
behavioural change to the application, not just a packaging change, so it
should be a deliberate decision rather than a quick fallback.

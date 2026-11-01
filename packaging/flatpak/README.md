# Flatpak

`com.dhivalabs.branch_pilot.yml` builds the BranchPilot Flatpak bundle that CI
attaches to releases (`branchpilot-<version>-x86_64.flatpak` and
`-aarch64.flatpak`).

## How CI builds it

The `flatpak` job in `.github/workflows/ci.yml` unpacks the installed tree of
the `.deb` built earlier in the same run into `packaging/flatpak/tree/` and
runs flatpak-builder on the manifest in the
`ghcr.io/flathub-infra/flatpak-github-actions:gnome-51` image, natively on an
x64 and an arm64 runner. The bundle therefore ships the same Flutter build as
the `.deb`, `.rpm`, Arch package and AppImage.

The manifest has three modules:

- **git**, built from the upstream release tarball. BranchPilot does every
  operation by running git, and the GNOME runtime has none. `GitCli` runs
  `/usr/bin/git` when it exists and the first `git` on `PATH` otherwise, so
  inside the sandbox it gets `/app/bin/git`.
- **git-wrapper**, that `/app/bin/git`. Flatpak points `XDG_CONFIG_HOME` at
  `~/.var/app/com.dhivalabs.branch_pilot/config`; the wrapper points it back
  at `~/.config` before running git, so git reads `~/.config/git/config`,
  `ignore` and `attributes` as it does on the host.
- **branchpilot**, the installed tree, with the desktop file and icons renamed
  to the app ID and the AppStream metadata.

CI then installs the bundle and checks, inside the sandbox, that the runtime
has no `/usr/bin/git`, that `git` resolves to the bundled one, that it can
`ls-remote` an HTTPS remote and that it reads `~/.config/git/config`. Last, it
starts the app on a fresh repository under Xvfb with
`packaging/linux-distros/smoke.sh`, which waits for a painted Flutter UI and
for the app to record the repository as opened, which it does only after git
ran on it.

To install the bundle (the GNOME 51 runtime comes from Flathub):

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./branchpilot-1.0.0-x86_64.flatpak
flatpak run com.dhivalabs.branch_pilot
```

## Permissions

| Permission | Why |
|---|---|
| `--socket=wayland`, `--socket=fallback-x11`, `--share=ipc`, `--device=dri` | display and GPU for the Flutter UI |
| `--share=network` | fetch, pull, push and clone |
| `--filesystem=home` | open repositories by path anywhere in the home directory, and let git read `~/.gitconfig`, `~/.config/git` and `~/.ssh` |
| `--socket=ssh-auth` | SSH remotes authenticate through the user's ssh-agent |

What does not carry over from the host: git credential helpers installed on
the host (for example `git-credential-libsecret`) are not inside the sandbox,
so HTTPS remotes that need a password should use an SSH remote, a token in
`credential.helper=store`, or the `.deb`/`.rpm` instead. GPG commit signing is
not set up in the Flatpak. Repositories outside the home directory (for
example under `/mnt` or `/srv`) are not visible to it.

## Flathub

A Flathub submission would differ in two ways:

1. The `branchpilot` module's `tree` directory source becomes an `archive`
   source pointing at the release `.deb` (or a release tarball) with its
   sha256, or the app is built from source with the Flutter SDK and every pub
   package listed as sources, since Flathub builds offline.
2. Flathub reviews `--filesystem=home`; for a git GUI that opens repositories
   by path it is the usual choice, and the reason is the table above.

Each release also needs a `<release>` line in
`com.dhivalabs.branch_pilot.metainfo.xml`.

# Publishing BranchPilot to the Launchpad PPA

Target: `ppa:dhiva-labs/apps`.

## Why this is not a normal Debian package

Launchpad's build farm has **no outbound network access**. A Flutter build
normally downloads the SDK and every pub package mid-build, so a naive
`debian/rules` fails on the builders while succeeding locally — the failure
mode that cost several upload cycles on a sibling package.

Everything the build needs is therefore vendored into the source package:

* `packaging/vendor/flutter-3.44.6-linux-slim.tar.xz` — a Linux-only slice
  of the Flutter SDK.
* `packaging/vendor/pub-cache-3.44.6.tar.xz` — exactly the packages
  `pubspec.lock` resolves to.

Both are gitignored (they would add ~190 MB to the repository) but *are*
included in the `3.0 (native)` source package, which is what Launchpad
builds. See `packaging/vendor/README` for how they are produced.

**The pub cache is project-specific.** It must be regenerated whenever
dependencies change — a cache built for a different project resolves the
wrong package set and the builders fail on the first missing package.

## Architectures

The PPA package is amd64 only. `debian/control` says `Architecture: amd64`,
`debian/rules` copies `build/linux/x64/release/bundle`, and the vendored
Flutter SDK in `packaging/vendor/` is the Linux x64 one. The GitHub Actions
workflow already builds an arm64 `.deb` and an arm64 snap; the PPA is the
part left. To add arm64 here:

* vendor an arm64 Flutter SDK slice (the upstream tarball is x64 only, so
  clone the 3.44.6 tag on an arm64 machine, run `flutter precache --linux`
  and slim it as `packaging/vendor/README` describes);
* use `build/linux/$(DEB_HOST_ARCH_CPU)` style paths in `debian/rules`
  (`amd64` maps to Flutter's `x64`);
* set `Architecture: any` in `debian/control`;
* rehearse offline on an arm64 machine, then upload.

Until then the PPA stays amd64, and arm64 users install the `.deb` from the
release or the snap.

## Rehearse offline before every upload

This is the step that catches builder-only failures. It runs the real build
with the network namespace unshared, which is a faithful stand-in for the
builders' isolation:

```bash
dpkg-buildpackage -S -us -uc -d
mkdir -p /tmp/bp_rehearsal && tar -xJf ../branchpilot_*.tar.xz -C /tmp/bp_rehearsal
cd /tmp/bp_rehearsal/branch_pilot
unshare -rn -- env HOME=/tmp/bp_rehearsal/home sh -c \
  'ip link set lo up; make -f debian/rules override_dh_auto_build'
```

It should end with `✓ Built build/linux/x64/release/bundle/branch_pilot`.
If it fails, the Launchpad build would have failed the same way.

## Sign and upload

**Use key `3D8D857AAF4D50E6` (rsa4096, short id `AF4D50E6`).** This machine
holds two secret keys for `dhivakar1010@gmail.com`, but only the rsa4096 one
is registered on the `~dhivakar1010` Launchpad account:

```console
$ curl -s https://api.launchpad.net/1.0/~dhivakar1010/gpg_keys | grep keyid
  AF4D50E6
```

Signing with the ed25519 key (`32CC792311A6EF76`) produces a perfectly valid
signature, `dput` reports success — and Launchpad then discards the upload,
because it cannot match the signature to a registered key. Nothing appears
in the PPA and the only notice is an email. That is exactly how the first
`1.0.0~noble1` attempt was lost.

The signing key's address must also match the `debian/changelog` maintainer
address; both are `dhivakar1010@gmail.com`.

```bash
debuild -S -sa -k3D8D857AAF4D50E6
dput dhiva-apps ../branchpilot_1.0.0~noble1_source.changes
```

`debuild` needs the key's passphrase. gpg-agent caches it for a while after
the first use, but in a non-interactive shell with no pinentry available the
signing step fails with `clear-sign failed: Timeout` — run it from a terminal
where a passphrase prompt can appear.

### Two silent failures to guard against

Both of these report success and upload nothing. Neither prints a warning.

**1. `dput` skips packages it thinks it already sent.** After a successful
transfer it writes a receipt beside the package —
`branchpilot_<version>_source.dhiva-apps.upload`. On any later `dput` of the
same version it sees that file and does nothing at all. So if a first upload
was rejected by Launchpad (wrong key, bad signature) and you fix and re-sign,
a plain `dput` is a no-op and the corrected package never leaves the machine.
Always force a re-upload after a rejection:

```bash
rm -f ../branchpilot_*_source.dhiva-apps.upload
dput -f dhiva-apps ../branchpilot_1.0.0~noble1_source.changes
```

**2. Launchpad discards uploads signed by an unregistered key** (see above).
`dput` still says "Successfully uploaded packages" — that only describes the
FTP transfer, not acceptance.

### Confirm it actually landed

Never trust the upload message. Check the archive: 

```bash
curl -s "https://api.launchpad.net/1.0/~dhiva-labs/+archive/ubuntu/apps?ws.op=getPublishedSources&source_name=branchpilot" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["total_size"], "published")'
```

Watch progress at
<https://launchpad.net/~dhiva-labs/+archive/ubuntu/apps/+packages>.

## Version bumps

Bump `debian/changelog` (`1.0.1~noble1`, and a `~jammy1` copy if targeting
more series), regenerate the pub cache if dependencies moved, rehearse
offline, then sign and upload.

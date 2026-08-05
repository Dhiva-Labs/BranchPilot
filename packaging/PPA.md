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

The signing key must match the `debian/changelog` maintainer address, or
Launchpad rejects the upload. Both are `dhivakar1010@gmail.com`.

```bash
debuild -S -sa -k32CC792311A6EF76
dput dhiva-apps ../branchpilot_1.0.0~noble1_source.changes
```

`dput` reporting "Successfully uploaded packages" only means the files
reached the server. Launchpad then validates the signature asynchronously
and emails an acceptance or rejection. A rejection almost always means the
signing key is not registered on the Launchpad account, or the account has
not signed the Code of Conduct.

Watch progress at
<https://launchpad.net/~dhiva-labs/+archive/ubuntu/apps/+packages>.

## Version bumps

Bump `debian/changelog` (`1.0.1~noble1`, and a `~jammy1` copy if targeting
more series), regenerate the pub cache if dependencies moved, rehearse
offline, then sign and upload.

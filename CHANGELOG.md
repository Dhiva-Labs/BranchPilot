# Changelog

## 1.0.1 - 2026-10-16

### Added
- Linux arm64 builds: `branchpilot_1.0.1_arm64.deb` and an arm64 snap, next to the existing x64 ones.
- Snap Store and Launchpad PPA packaging. The snap is strictly confined and bundles git, ssh and ca-certificates.
- CI builds, tests and packages the app on x64 and arm64 runners, runs the UI integration tests and a smoke run of the installed package, and installs and starts each built snap under confinement.

### Changed
- The release job attaches the `.deb` of both architectures to a published release and leaves any file the release already has untouched.

No application code changed since 1.0.0.

## 1.0.0 - 2026-08-05

First release: commit graph, hunk-level staging, branch, stash and remote operations, interactive rebase and power operations, packaged as an x64 `.deb`.

#!/usr/bin/env bash
# Builds branchpilot_<version>_<arch>.deb from the Linux release bundle, where
# <arch> is the architecture of the machine it runs on (amd64 or arm64).
#
# Run from the repo root after `flutter build linux --release`:
#
#     packaging/build_deb.sh [output-dir]        # default output-dir: dist/
#
# Needs the app icons already generated (python3 tool/make_icon.py —
# assets/icon/branchpilot_<size>.png) and dpkg-deb. Mirrors the layout used by
# other Dhiva Labs Linux .debs (see ~/dhiva-labs/droid_deck/packaging/build_deb.sh):
# an /usr/lib/<pkg> install prefix, a thin /usr/bin wrapper, and standard
# hicolor icon + .desktop registration.
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="${1:-dist}"
# The package architecture follows the build machine, and so does Flutter's
# output directory (build/linux/x64 or build/linux/arm64).
DEB_ARCH="$(dpkg --print-architecture)"
case "$DEB_ARCH" in
  amd64) FLUTTER_ARCH=x64 ;;
  arm64) FLUTTER_ARCH=arm64 ;;
  *)
    echo "error: unsupported architecture '$DEB_ARCH' (amd64 or arm64)" >&2
    exit 1
    ;;
esac
BUNDLE="build/linux/$FLUTTER_ARCH/release/bundle"
ICON_DIR=assets/icon
ICON_SIZES="16 32 48 64 128 256 512"
VERSION="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"

[ -x "$BUNDLE/branch_pilot" ] || {
  echo "error: $BUNDLE/branch_pilot not found — run 'flutter build linux --release' first" >&2
  exit 1
}

for size in $ICON_SIZES; do
  [ -f "$ICON_DIR/branchpilot_${size}.png" ] || {
    echo "error: $ICON_DIR/branchpilot_${size}.png missing — run 'python3 tool/make_icon.py' first" >&2
    exit 1
  }
done

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
PKG="$STAGE/branchpilot"

mkdir -p \
  "$PKG/DEBIAN" \
  "$PKG/usr/lib/branchpilot" \
  "$PKG/usr/bin" \
  "$PKG/usr/share/applications" \
  "$PKG/usr/share/doc/branchpilot"
for size in $ICON_SIZES; do
  mkdir -p "$PKG/usr/share/icons/hicolor/${size}x${size}/apps"
done

cp -r "$BUNDLE/." "$PKG/usr/lib/branchpilot/"

cat > "$PKG/usr/bin/branchpilot" <<'EOF'
#!/bin/sh
exec /usr/lib/branchpilot/branch_pilot "$@"
EOF
chmod 0755 "$PKG/usr/bin/branchpilot"

cat > "$PKG/usr/share/applications/branchpilot.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=BranchPilot
Comment=Git client for Linux
Exec=branchpilot
Icon=branchpilot
Terminal=false
Categories=Development;RevisionControl;
StartupWMClass=branch_pilot
EOF

for size in $ICON_SIZES; do
  cp "$ICON_DIR/branchpilot_${size}.png" \
     "$PKG/usr/share/icons/hicolor/${size}x${size}/apps/branchpilot.png"
done

cat > "$PKG/usr/share/doc/branchpilot/copyright" <<EOF
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: branchpilot
Source: https://github.com/Dhiva-Labs/BranchPilot

Files: *
Copyright: $(date +%Y) Dhiva Labs
License: MIT
 See the LICENSE file at the project root (or
 https://opensource.org/license/mit) for the full license text.
EOF

INSTALLED_SIZE="$(du -sk "$PKG/usr" | cut -f1)"
cat > "$PKG/DEBIAN/control" <<EOF
Package: branchpilot
Version: ${VERSION}
Section: devel
Priority: optional
Architecture: ${DEB_ARCH}
Maintainer: Dhiva Labs <dhivakar101010@gmail.com>
Installed-Size: ${INSTALLED_SIZE}
Depends: libgtk-3-0t64 | libgtk-3-0
Homepage: https://github.com/Dhiva-Labs/BranchPilot
Description: GitKraken-class git GUI for Linux, wrapping the system git CLI
 BranchPilot is a desktop git client for Linux built around the system git
 command-line tool — no libgit2, no native git bindings, and authentication
 stays entirely with your existing git credential helpers / ssh-agent. It
 shows a lane-based commit graph with merge/fork edges and colour-coded
 branch/tag/remote decorations, hunk-level diff staging with syntax
 highlighting, a commit/amend box, full branch and stash management, merge
 conflict resolution, fetch/pull/push with live streaming progress, a visual
 interactive rebase (reorder/reword/squash/fixup/drop, with conflict
 pause/resume), tags, cherry-pick, revert, a typed-confirmation gated hard
 reset, worktrees, and per-file history.
EOF

# Normalize permissions — mkdir -p/cp inherit the caller's umask, which
# otherwise leaves group-writable dirs/files (lintian: non-standard-*-perm).
# Only the wrapper and the real binary need the executable bit back; every
# .so in the bundle ships non-executable already (dlopen'd, not exec'd).
find "$PKG" -type d -exec chmod 0755 {} +
find "$PKG" -type f -exec chmod 0644 {} +
chmod 0755 "$PKG/usr/bin/branchpilot" "$PKG/usr/lib/branchpilot/branch_pilot"

mkdir -p "$OUT_DIR"
DEB="$OUT_DIR/branchpilot_${VERSION}_${DEB_ARCH}.deb"
dpkg-deb --build --root-owner-group "$PKG" "$DEB" >/dev/null
echo "built $DEB"

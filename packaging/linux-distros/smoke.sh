#!/usr/bin/env bash
# Smoke run of an installed BranchPilot, shared by every Linux format CI
# builds besides the .deb: the .rpm on Fedora and openSUSE, the Arch package,
# the AppImage and the Flatpak.
#
# usage: smoke.sh <command that starts BranchPilot...>
#
# Run it on a virtual display whose framebuffer Xvfb mirrors into a file:
#
#   xvfb-run -a -s "-screen 0 1280x800x24 -fbdir $SMOKE_FB" \
#     dbus-run-session -- bash smoke.sh branchpilot
#
# It makes a one-commit git repository, starts BranchPilot on it and passes
# once both of these hold:
#
#   - The screen shows a painted Flutter UI. The native GTK runner opens its
#     window before any Dart code runs, so a window alone proves nothing. A
#     Flutter UI paints hundreds of distinct colours; a runner whose Dart
#     snapshot did not start shows a handful. This is the colour count of
#     the .deb smoke run in ci.yml, read from Xvfb's framebuffer file because
#     the Flatpak builder image has no ImageMagick or xdotool.
#   - The repository is in BranchPilot's recent list. openRepository() only
#     records a path after `git rev-parse --show-toplevel` succeeded on it,
#     so this proves the app found and ran git in this environment.
#
# Environment: SMOKE_FB (the -fbdir directory), HOME (a fresh directory),
# GIT (how to run git here, default `git`; the Flatpak passes the git inside
# its sandbox), SMOKE_SECONDS (how long to wait, default 120).
set -euo pipefail
: "${SMOKE_FB:?set SMOKE_FB to the directory given to Xvfb -fbdir}"
[ $# -ge 1 ] || { echo "usage: $0 <command...>" >&2; exit 2; }
read -r -a git <<< "${GIT:-git}"
secs="${SMOKE_SECONDS:-120}"
min_colours=200
log="$HOME/branchpilot-smoke.log"

repo="$HOME/smoke-repo"
rm -rf "$repo"
mkdir -p "$repo"
repo="$(cd "$repo" && pwd -P)"
"${git[@]}" -C "$repo" init -q -b main
printf 'BranchPilot smoke test\n' > "$repo/README.md"
"${git[@]}" -C "$repo" add README.md
"${git[@]}" -C "$repo" -c user.name=Smoke -c user.email=smoke@example.invalid \
  commit -q -m 'first commit'
"${git[@]}" -C "$repo" log --oneline

# Distinct pixel values on the screen, from the XWD file Xvfb keeps up to
# date (big-endian header, then the colour map, then the pixels).
colours() {
  python3 - "$SMOKE_FB/Xvfb_screen0" <<'EOF'
import struct, sys
data = open(sys.argv[1], 'rb').read()
h = struct.unpack('>25I', data[:100])
header_size, width, height, bpp, bpl, ncolours = h[0], h[4], h[5], h[11], h[12], h[19]
start = header_size + ncolours * 12
step = bpp // 8
seen = set()
for y in range(height):
    row = data[start + y * bpl:start + y * bpl + width * step]
    if step == 4:
        seen.update(memoryview(row).cast('I'))
    else:
        seen.update(row[i:i + step] for i in range(0, len(row), step))
print(len(seen))
EOF
}

recorded() {
  local f
  while IFS= read -r -d '' f; do
    grep -qF "\"$repo\"" "$f" && { echo "$f: $(cat "$f")"; return 0; }
  done < <(find "$HOME" -name shared_preferences.json -print0)
  return 1
}

"$@" "$repo" > "$log" 2>&1 &
pid=$!
painted=0
opened=0
n=0
for i in $(seq 1 "$secs"); do
  kill -0 "$pid" 2> /dev/null || { echo "BranchPilot exited early"; cat "$log"; exit 1; }
  if [ "$painted" = 0 ]; then
    n="$(colours)"
    echo "screenshot ${i}: $n distinct colours"
    if [ "$n" -ge "$min_colours" ]; then painted=1; fi
  fi
  if [ "$opened" = 0 ] && recorded; then
    echo "BranchPilot opened $repo with git after ${i}s"
    opened=1
  fi
  if [ "$painted" = 1 ] && [ "$opened" = 1 ]; then break; fi
  sleep 1
done
kill -0 "$pid" 2> /dev/null || { echo "BranchPilot died"; cat "$log"; exit 1; }
kill "$pid"
cat "$log"
ok=1
if [ "$painted" = 0 ]; then
  echo "the window never painted a Flutter UI ($n colours, need $min_colours)"
  ok=0
fi
if [ "$opened" = 0 ]; then
  echo "BranchPilot never recorded $repo as opened: it could not run git on it"
  ok=0
fi
if grep -E 'error while loading shared libraries|cannot open shared object|undefined symbol' "$log"; then
  ok=0
fi
[ "$ok" = 1 ]
echo "Flutter UI painted ($n distinct colours) and the repository was opened with git"

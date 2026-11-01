#!/usr/bin/env bash
# Runs inside a distribution container started by verify.sh.
# MODE: rpm (Fedora) | rpm-suse (openSUSE) | pacman (Arch) | appimage (Fedora)
# FILE: the package to install, under /pkgs.
set -euo pipefail
# shellcheck source=/dev/null
. /linux-distros/distro.conf

# Display and GL stack for the GUI smoke test, per distribution, plus what
# smoke.sh needs: python3 (reads the Xvfb framebuffer) and a font, as any
# desktop has. git itself is not installed here: the packages must pull it
# in. The AppImage uses the host's git, so its host gets git.
case "$MODE" in
  rpm|appimage)
    dnf -y -q install file findutils which procps-ng \
      xorg-x11-server-Xvfb xorg-x11-xauth mesa-dri-drivers dbus-daemon \
      python3 dejavu-sans-fonts
    ;;
  rpm-suse)
    zypper -n -q --gpg-auto-import-keys refresh
    zypper -n -q install file findutils which procps \
      xvfb-run Mesa-dri dbus-1 python3 dejavu-fonts
    ;;
  pacman)
    pacman -Syu --noconfirm --needed -q file findutils which procps-ng \
      xorg-server-xvfb xorg-xauth mesa dbus python ttf-dejavu
    ;;
esac
if command -v git > /dev/null; then
  echo "git is already installed before the package; the dependency check below would prove nothing" >&2
  exit 1
fi

case "$MODE" in
  rpm)      dnf -y install "$FILE"; files() { rpm -ql "$NAME"; } ;;
  rpm-suse) zypper -n install --allow-unsigned-rpm "$FILE"; files() { rpm -ql "$NAME"; } ;;
  pacman)   pacman -U --noconfirm "$FILE"; files() { pacman -Qlq "$NAME"; } ;;
  appimage)
    # The libraries an AppImage expects from the host: GTK 3 and friends.
    dnf -y -q install gtk3 git
    cp "$FILE" /tmp/app.AppImage
    chmod +x /tmp/app.AppImage
    (cd /tmp && /tmp/app.AppImage --appimage-extract > /dev/null)
    files() { find /tmp/squashfs-root -type f; }
    ;;
  *) echo "unknown MODE $MODE" >&2; exit 2 ;;
esac

# The package's own dependency on git (RPM_REQUIRES / ARCH_DEPENDS) must
# have installed it.
git --version

# Every ELF file the package installed must find all of its libraries. The
# package's own library directories go on LD_LIBRARY_PATH, as the app's
# RPATH/$ORIGIN would supply them at run time, so only libraries missing
# from the distribution are reported.
mapfile -t elfs < <(files | while IFS= read -r f; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] && echo "$f"
done)
libdirs="$(for f in "${elfs[@]}"; do case "$f" in *.so|*.so.*) dirname "$f" ;; esac; done | sort -u | paste -sd:)"
missing=0
for f in "${elfs[@]}"; do
  if LD_LIBRARY_PATH="$libdirs" ldd "$f" 2>&1 | grep 'not found' > /dev/null; then
    echo "missing libraries for $f:"
    LD_LIBRARY_PATH="$libdirs" ldd "$f" | grep 'not found'
    missing=1
  fi
done
echo "${#elfs[@]} ELF files checked with ldd"
[ "$missing" = 0 ] || exit 1

# Smoke test. CLI tools: SMOKE_CMD must exit 0. GUI apps: smoke.sh starts
# GUI_CMD under Xvfb on a fresh repository and needs a painted Flutter UI and
# the repository opened with git within SMOKE_SECONDS, with no loader errors.
if [ "$MODE" = appimage ]; then
  export APPIMAGE_EXTRACT_AND_RUN=1
  cmd_prefix=/tmp/app.AppImage
else
  cmd_prefix=
fi
if [ -n "${SMOKE_CMD:-}" ]; then
  if [ -n "$cmd_prefix" ]; then
    # SMOKE_CMD's first word is the installed command; the AppImage replaces it.
    read -r -a words <<< "$SMOKE_CMD"
    "$cmd_prefix" "${words[@]:1}"
  else
    bash -c "$SMOKE_CMD"
  fi
fi
if [ -n "${GUI_CMD:-}" ]; then
  if [ -n "$cmd_prefix" ]; then gui=("$cmd_prefix"); else read -r -a gui <<< "$GUI_CMD"; fi
  export HOME=/tmp/smoke-home SMOKE_FB=/tmp/smoke-fb SMOKE_SECONDS
  mkdir -p "$HOME" "$SMOKE_FB"
  xvfb-run -a -s "-screen 0 1280x800x24 -fbdir $SMOKE_FB" \
    dbus-run-session -- bash /linux-distros/smoke.sh "${gui[@]}"
fi
echo "$MODE: OK"

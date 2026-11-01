# Runs inside the Flatpak sandbox, from CI:
#
#   flatpak run --command=sh <app-id> -s < packaging/flatpak/ldd-check.sh
#
# Every ELF file under /app must find all of its libraries in the bundle or
# in the runtime. The bundle's own library directories go on
# LD_LIBRARY_PATH, as the executables' RUNPATH ($ORIGIN/lib) supplies them at
# run time, so only libraries missing from the runtime are reported.
set -eu
libdirs="$(find /app -type f -name '*.so*' -exec dirname {} + | sort -u | paste -sd: -)"
find /app -type f | while IFS= read -r f; do
  [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] || continue
  echo "ELF $f"
  LD_LIBRARY_PATH="$libdirs" ldd "$f" | sed -n "s|.*not found.*|MISSING $f: &|p"
done > /tmp/ldd-check.out
grep '^MISSING' /tmp/ldd-check.out && exit 1
n="$(grep -c '^ELF' /tmp/ldd-check.out)"
echo "$n ELF files under /app checked with ldd, all libraries found"
[ "$n" -gt 0 ]

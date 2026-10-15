#!/usr/bin/env bash
# Fails unless every ELF file under DIR is built for the expected machine.
#
#     packaging/assert_arch.sh DIR MACHINE [MIN_FILES]
#
# MACHINE is the text `file` prints for the architecture: "x86-64" or
# "ARM aarch64". MIN_FILES (default 1) is the least number of ELF files DIR
# must hold, which stops an empty or wrong directory from passing.
set -euo pipefail

dir="${1:?usage: assert_arch.sh DIR MACHINE [MIN_FILES]}"
machine="${2:?usage: assert_arch.sh DIR MACHINE [MIN_FILES]}"
min="${3:-1}"

[ -d "$dir" ] || { echo "error: $dir is not a directory" >&2; exit 1; }

elf="$(find "$dir" -type f -print0 | xargs -0 -r file | grep -aE ':[[:space:]]+ELF ' || true)"
checked="$(printf '%s' "$elf" | grep -c . || true)"
wrong="$(printf '%s' "$elf" | grep -a -v -F "$machine" || true)"

if [ "$checked" -le 20 ]; then
  printf '%s\n' "$elf"
fi
echo "$dir: $checked ELF files, expected '$machine'"

if [ -n "$wrong" ]; then
  echo "::error::ELF files that are not '$machine':"
  printf '%s\n' "$wrong"
  exit 1
fi
if [ "$checked" -lt "$min" ]; then
  echo "::error::only $checked ELF files under $dir, expected at least $min"
  exit 1
fi

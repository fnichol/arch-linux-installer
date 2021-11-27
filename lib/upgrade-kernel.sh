#!/usr/bin/env sh
set -eu
if [ -n "${DEBUG:-}" ]; then
  set -x
fi

kernel="$(
  sed 's|.*linux|linux|' /proc/cmdline \
    | sed 's|.img||g' \
    | awk '{ print $1 }'
)"

exec pacman -Sy --needed --noconfirm "$@" \
  "$kernel" \
  "$kernel-headers" \
  "zfs-$kernel" \
  zfs-utils

#!/usr/bin/env sh
# shellcheck disable=SC3043

main() {
  set -eu
  if [ -n "${DEBUG:-}" ]; then
    set -x
  fi

  local running_kernel
  running_kernel="$(
    sed 's|.*linux|linux|' /proc/cmdline \
      | sed 's|.img||g' \
      | awk '{ print $1 }'
  )"

  local compat_kernel_version
  compat_kernel_version="$(
    pacman -Si "zfs-$running_kernel" \
      | grep '^Depends On' \
      | sed 's,.*linux=,,' \
      | awk '{ print $1 }'
  )"
  local current_kernel_version
  current_kernel_version="$(
    pacman -Si "$running_kernel" | grep ^Version | awk '{ print $3 }'
  )"

  section "Upgrading kernel"

  if [ "$current_kernel_version" = "$compat_kernel_version" ]; then
    info "Compatible versions of $running_kernel and zfs-$running_kernel"
    indent pacman -Sy --needed --noconfirm "$@" \
      "$running_kernel" \
      "$running_kernel-headers" \
      "zfs-$running_kernel" \
      zfs-utils
  else
    info "Incompatible versions of $running_kernel and zfs-$running_kernel"
    printf "        %-20s : %s\n" "$running_kernel" "$current_kernel_version"
    printf "        %-20s : %s\n" "zfs-$running_kernel" "$compat_kernel_version"
    info "Skipping kernel package upgrade"
  fi
}

#!/usr/bin/env bash

main() {
  set -eu
  if [ -n "${DEBUG:-}" ]; then set -x; fi

  version='0.1.0'
  author='Fletcher Nichol <fnichol@nichol.ca>'
  program="$(basename "$0")"

  # shellcheck source=_common.sh
  . "${0%/*}/_common.sh"

  parse_cli_args "$@"

  install_x_hardware_specific_pkgs
  setup_x
}

print_help() {
  echo "$program $version

$author

Arch Linux Postinstall.

USAGE:
        $program [FLAGS] [OPTIONS]

COMMON FLAGS:
    -h  Prints this message
    -V  Prints version information
"
}

parse_cli_args() {
  OPTIND=1
  # Parse command line flags and options.
  while getopts "Vh" opt; do
    case $opt in
      V)
        echo "$program $version"
        exit 0
        ;;
      h)
        print_help
        exit 0
        ;;
      \?)
        print_help
        exit_with "Invalid option: -$OPTARG" 1
        ;;
    esac
  done
  # Shift off all parsed token in `$*` so that the subcommand is now `$1`.
  shift "$((OPTIND - 1))"
}

install_x_hardware_specific_pkgs() {
  if is_in_vmware; then
    info "Installing VMware-specific software"
    pacman -S --noconfirm \
      gtkmm3 \
      libxtst \
      mesa-libgl \
      xf86-input-vmmouse \
      xf86-video-vmware

    info "Starting & enabling vmware-vmblock-fuse service"
    systemctl start vmware-vmblock-fuse.service
    systemctl enable vmware-vmblock-fuse.service
  fi
}

setup_x() {
  info "Installing X, a window manager, and utilities"
  pacman -S --noconfirm \
    dmenu \
    i3 \
    termite \
    xf86-input-evdev \
    xorg-server \
    xorg-xinit

  info "Creating default xinitrc for startx"
  local xi=/etc/X11/xinit/xinitrc
  rm -f "$xi"
  touch "$xi"
  if is_in_vmware; then
    echo "/usr/sbin/vmware-user-suid-wrapper" >> "$xi"
  fi
  echo "xset r rate 200 30" >> "$xi"
  echo "exec i3" >> "$xi"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit 99
fi

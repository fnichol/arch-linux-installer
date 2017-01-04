#!/usr/bin/env bash
set -eu

if [ -n "${DEBUG:-}" ]; then
  set -x
fi

print_help() {
  printf -- "$program $version

$author

Arch Linux Postinstall.

USAGE:
        $program [FLAGS] [OPTIONS]

COMMON FLAGS:
    -h  Prints this message
    -V  Prints version information

"
}

info() {
  case "${TERM:-}" in
    *term | xterm-* | rxvt | screen | screen-*)
      printf -- "   \033[1;36m${program:-unknown}: \033[1;37m${1:-}\033[0m\n"
      ;;
    *)
      printf -- "   ${program:-unknown}: ${1:-}\n"
      ;;
  esac
  return 0
}

exit_with() {
  if [ -n "${DEBUG:-}" ]; then set -x; fi

  case "${TERM:-}" in
    *term | xterm-* | rxvt | screen | screen-*)
      echo -e "\033[1;31mERROR: \033[1;37m$1\033[0m"
      ;;
    *)
      echo "ERROR: $1"
      ;;
  esac
  exit ${2:-99}
}

is_in_vmware() {
  if [ "$(cat /sys/class/dmi/id/sys_vendor)" = "VMware, Inc." ]; then
    return 0
  else
    return 1
  fi
}

main() {
  if is_in_vmware; then
    info "Installing VMware-specific software"
    pacman -S --noconfirm \
      gtkmm \
      libxtst \
      mesa-libgl \
      open-vm-tools \
      xf86-input-vmmouse \
      xf86-video-vmware

    systemctl start vmware-vmblock-fuse.service
    systemctl enable vmware-vmblock-fuse.service
  fi

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
  echo "exec i3" >> "$xi"

  if ! grep -q infinality-bundle /etc/pacman.conf > /dev/null; then
    info "Adding infinality-bundle repositories"
    cat <<'EOF' >> /etc/pacman.conf

[infinality-bundle]
Server = http://bohoomil.com/repo/$arch

[infinality-bundle-fonts]
Server = http://bohoomil.com/repo/fonts
EOF
    pacman-key -r 962DDE58
    pacman-key --lsign-key 962DDE58

    info "Refreshing package list and upgrading"
    pacman -Syyu
  fi

  info "Installing much better font rendering"
  pacman -S --noconfirm \
    infinality-bundle \
    ibfonts-meta-base \
    ttf-overpass-fonts-ibx \
    otf-inconsolatazi4-ibx

  # lxappearance
  # rofi
  # compton
}


# # Main Flow

# The current version of this program
version='0.1.0'
# The author of this program
author='Fletcher Nichol <fnichol@nichol.ca>'
# The short version of the program name which is used in logging output
program="$(basename $0)"


# ## CLI Argument Parsing

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

main
exit 0

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
        $program [FLAGS] [OPTIONS] <HOSTNAME>

COMMON FLAGS:
    -h  Prints this message
    -V  Prints version information

ARGS:
    <HOSTNAME>    Hostname (ex: \`fuzzy')

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
  # * https://wiki.archlinux.org/index.php/Time
  # * https://wiki.archlinux.org/index.php/Systemd-timesyncd
  tz="America/Edmonton"
  info "Setting up timezone to $tz"
  timedatectl set-timezone "$tz"
  timedatectl set-ntp true

  # If hardware clock is set to local time, like in VMware Fusion
  #
  # * http://www.linuxfromscratch.org/lfs/view/stable-systemd/chapter07/clock.html
  if is_in_vmware; then
    info "Setting time adjustment due to local time in hardware clock"
    timedatectl set-local-rtc 1
  fi

  locales=(en_CA.UTF-8 en_US.UTF-8 en_US)
  default_locale="en_US.UTF-8"
  for l in ${locales[@]}; do
    sed -i "s|^#\(${l}\)|\1|" /etc/locale.gen
  done; unset l
  info "Generating locales for ${locales[@]}"
  locale-gen
  info "Setting default locale to $default_locale"
  echo "LANG=$default_locale" > /etc/locale.conf

  info "Setting hostname to $hostname"
  echo "$hostname" > /etc/hostname
  hostnamectl set-hostname "$hostname"
  hostname "$hostname"

  info "Updating system"
  pacman -Syu

  # * https://wiki.archlinux.org/index.php/Mirrors
  info "Calculating fastest mirrors"
  cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.dist
  curl 'https://www.archlinux.org/mirrorlist/?country=CA&country=US&protocol=http&ip_version=4' -o /etc/pacman.d/mirrorlist.new
  sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist.new
  rankmirrors -n 6 /etc/pacman.d/mirrorlist.new > /etc/pacman.d/mirrorlist
  rm -f /etc/pacman.d/mirrorlist.new
  pacman -Syyu

  info "Installing software"
  pacman -S --noconfirm \
    ack \
    base-devel \
    git \
    htop \
    mosh \
    tmux \
    tree \
    vim \
    wget

  info "Installing fnichol/bashrc"
  curl https://raw.githubusercontent.com/fnichol/bashrc/master/contrib/install-system-wide -o /tmp/install.sh
  bash /tmp/install.sh
  rm -f /tmp/install.sh
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

if [ -z "${1:-}" ]; then
  print_help
  exit_with "Required argument: <HOSTNAME>" 2
fi
hostname="$1"
shift

main
exit 0

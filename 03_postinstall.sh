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

  install_hardware_specific_pkgs
  set_timezone
  setup_clock
  generate_locales
  update_system
  find_fastest_mirrors
  add_yaourt_repo

  info "Finished."
}

print_help() {
  echo "$program $version

$author

Arch Linux Postinstall.

USAGE:
        $program [FLAGS] [OPTIONS] <TZ>

COMMON FLAGS:
    -h  Prints this message
    -V  Prints version information

ARGS:
    <TZ>  Timezone (ex: \`America/Edmonton', \`UTC')
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

  if [ -z "${1:-}" ]; then
    print_help
    exit_with "Required argument: <TZ>" 2
  fi
  TZ="$1"
  shift
}

install_hardware_specific_pkgs() {
  if is_in_vmware; then
    info "Installing VMware-specific software"
    pacman -S --noconfirm open-vm-tools
  fi
}

set_timezone() {
  # * https://wiki.archlinux.org/index.php/Time
  # * https://wiki.archlinux.org/index.php/Systemd-timesyncd
  info "Setting up timezone to $TZ"
  timedatectl set-timezone "$TZ"
}

setup_clock() {
  # If hardware clock is set to local time, like in VMware Fusion
  #
  # * http://www.linuxfromscratch.org/lfs/view/stable-systemd/chapter07/clock.html
  if is_in_vmware; then
    info "Starting & enabling vmtoolsd service"
    systemctl start vmtoolsd.service
    systemctl enable vmtoolsd.service

    info "Setting time adjustment due to local time in hardware clock"
    timedatectl set-local-rtc 1

    info "Enabling timesync"
    vmware-toolbox-cmd timesync enable

    info "Creating hwclock-resume service unit to update clock after sleep"
    cat <<'EOF' > /etc/systemd/system/hwclock-resume.service
[Unit]
Description=Update hardware clock after resuming from sleep
After=suspend.target

[Service]
Type=oneshot
ExecStart=/usr/bin/hwclock --hctosys --utc

[Install]
WantedBy=suspend.target
EOF
    systemctl daemon-reload

    info "Starting & enabling hwclock-resume service"
    systemctl start hwclock-resume.service
    systemctl enable hwclock-resume.service
  else
    info "Enabling ntp"
    timedatectl set-ntp true
  fi
}

generate_locales() {
  local locales=(en_CA.UTF-8 en_US.UTF-8 en_US)
  local default_locale="en_US.UTF-8"

  for l in "${locales[@]}"; do
    # shellcheck disable=SC1117
    sed -i "s|^#\(${l}\)|\1|" /etc/locale.gen
  done; unset l
  info "Generating locales for ${locales[*]}"
  locale-gen
  info "Setting default locale to $default_locale"
  echo "LANG=$default_locale" > /etc/locale.conf
}

update_system() {
  info "Updating system"
  pacman -Syu --noconfirm
}

find_fastest_mirrors() {
  # * https://wiki.archlinux.org/index.php/Mirrors
  info "Calculating fastest mirrors"
  cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.dist
  curl 'https://www.archlinux.org/mirrorlist/?country=CA&country=US&protocol=http&ip_version=4' -o /etc/pacman.d/mirrorlist.new
  sed -i 's/^#Server/Server/' /etc/pacman.d/mirrorlist.new
  rankmirrors -n 6 /etc/pacman.d/mirrorlist.new > /etc/pacman.d/mirrorlist
  rm -f /etc/pacman.d/mirrorlist.new
  pacman -Syyu
}

add_yaourt_repo() {
  info "Adding repository for Yaourt"
  cat <<'EOF' >> /etc/pacman.conf

[archlinuxfr]
SigLevel = Never
Server = http://repo.archlinux.fr/$arch
EOF
  pacman -Sy --noconfirm

  info "Installing yaourt"
  pacman -S --noconfirm yaourt
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit 99
fi

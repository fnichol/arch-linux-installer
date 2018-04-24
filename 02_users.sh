#!/usr/bin/env bash

main() {
  set -eu
  if [ -n "${DEBUG:-}" ]; then set -x; fi

  version='0.1.0'
  author='Fletcher Nichol <fnichol@nichol.ca>'
  program="$(basename "$0")"

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
    exit_with "Required argument: <USERNAME>" 2
  fi
  admin="$1"
  shift

  if [ -z "${1:-}" ]; then
    print_help
    exit_with "Required argument: <FULLNAME>" 2
  fi
  admin_comment="$1"
  shift

  info "Installing OpenSSH and sudo"
  pacman -S --noconfirm openssh sudo

  info "Setting sudoers policy"
  echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/01_wheel

  rm -f /etc/skel/.bashrc

  info "Creating $admin user"
  zfs create "tank/home/$admin"
  sleep 2
  useradd -m -G wheel -s /bin/bash -b /tmp -c "$admin_comment" "$admin"
  chown -R "${admin}:${admin}" "/home/$admin"
  chmod 0750  "/home/$admin"
  (cd "/tmp/$admin"; tar cpf - . | tar xpf - -C "/home/$admin")
  usermod -d "/home/$admin" "$admin"
  rm -rf "/tmp/$admin"

  info "Set root password"
  passwd

  info "Set $admin password"
  passwd "$admin"

  info "Starting OpenSSH service"
  systemctl start sshd.socket
  systemctl enable sshd.socket
}

print_help() {
  echo "$program $version

$author

Arch Linux Base Postinstall.

USAGE:
        $program [FLAGS] [OPTIONS] <USERNAME> <FULLNAME>

COMMON FLAGS:
    -h  Prints this message
    -V  Prints version information

ARGS:
    <USERNAME>    Admin username (ex: \`jdoe')
    <FULLNAME>    Admin name (ex: \`Jane Doe')
"
}

info() {
  case "${TERM:-}" in
    *term | xterm-* | rxvt | screen | screen-*)
      printf -- "   \\033[1;36m%s: \\033[1;37m%s\\033[0m\\n" "${program}" "${1:-}"
      ;;
    *)
      printf -- "   %s: %s\\n" "${program}" "${1:-}"
      ;;
  esac
  return 0
}

exit_with() {
  case "${TERM:-}" in
    *term | xterm-* | rxvt | screen | screen-*)
      printf -- "\\033[1;31mERROR: \\033[1;37m%s\\033[0m\\n" "${1:-}"
      ;;
    *)
      printf -- "ERROR: %s" "${1:-}"
      ;;
  esac
  exit "${2:-99}"
}

main "$@" || exit 99

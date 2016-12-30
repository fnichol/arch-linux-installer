#!/usr/bin/env bash
set -eu

if [ -n "${DEBUG:-}" ]; then
  set -x
fi

print_help() {
  printf -- "$program $version

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

main() {
  info "Installing OpenSSH and sudo"
  pacman -S --noconfirm openssh sudo

  info "Setting sudoers policy"
  echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/01_wheel

  # rm -f /etc/skel/.bashrc

  info "Creating $admin user"
  zfs create "tank/home/$admin"
  sleep 2
  useradd -m -G wheel -s /bin/bash -b /tmp -c "$admin_comment" "$admin"
  chown -R "${admin}:${admin}" "/home/$admin"
  chmod 0750  "/home/$admin"
  (cd "/tmp/$admin"; tar cpf - . | tar xpf - -C /home/$admin)
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

main
exit 0

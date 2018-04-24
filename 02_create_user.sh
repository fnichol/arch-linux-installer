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
  USER="$1"
  shift

  if [ -z "${1:-}" ]; then
    print_help
    exit_with "Required argument: <FULLNAME>" 2
  fi
  COMMENT="$1"
  shift

  read_passwd
  create_user "$USER" "$COMMENT" "$PASSWD"
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

read_passwd() {
  local user="$1"

  while true; do
    echo -n "Enter password for $user: "
    read -s PASSWD
    echo

    echo -n "Retype password: "
    read -s retype
    echo

    if [ "$PASSWD" = "$retype" ]; then
      unset retype
      break
    else
      echo ">>> Passwords do not match, please try again"
      echo
    fi
  done
}

create_user() {
  local user="$1"
  local comment="$2"
  local passwd="$3"

  info "Creating $user user"
  zfs create "tank/home/$user"
  sleep 2
  useradd -m -G wheel -s /bin/bash -b /tmp -c "$comment" "$user"
  chown -R "${user}:${user}" "/home/$user"
  chmod 0750  "/home/$user"
  (cd "/tmp/$user"; tar cpf - . | tar xpf - -C "/home/$user")
  usermod -d "/home/$user" "$user"
  rm -rf "/tmp/$user"

  info "Set $user password"
  chpasswd <<< "$user:$passwd"
}

main "$@" || exit 99

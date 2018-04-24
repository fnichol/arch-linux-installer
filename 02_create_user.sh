#!/usr/bin/env bash

main() {
  set -eu
  if [ -n "${DEBUG:-}" ]; then set -x; fi

  version='0.1.0'
  author='Fletcher Nichol <fnichol@nichol.ca>'
  program="$(basename "$0")"

  # shellcheck source=_common.sh
  . "${0%/*}/_common.sh"

  # The name of the zpool
  pool=tank

  parse_cli_args "$@"

  read_passwd "$USER"
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

parse_cli_args() {
  OPTIND=1
  # Parse command line flags and options
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
}

create_user() {
  local user="$1"
  local comment="$2"
  local passwd="$3"

  info "Creating $user user"
  zfs create "$pool/home/$user"
  sleep 2
  useradd \
    --create-home \
    --user-group \
    --groups wheel \
    --shell /bin/bash \
    --base-dir /tmp \
    --comment "$comment" \
    "$user"
  chown -R "${user}:${user}" "/home/$user"
  chmod 0750  "/home/$user"
  (cd "/tmp/$user"; tar cpf - . | tar xpf - -C "/home/$user")
  usermod -d "/home/$user" "$user"
  rm -rf "/tmp/$user"

  info "Set $user password"
  chpasswd <<< "$user:$passwd"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit 99
fi

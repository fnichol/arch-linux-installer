#!/usr/bin/env bash

main() {
  set -eu
  if [ -n "${DEBUG:-}" ]; then set -x; fi

  version='0.1.0'
  author='Fletcher Nichol <fnichol@nichol.ca>'
  program="$(basename "$0")"

  # The name of the root zpool
  pool=rpool

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
  local dataset="$pool/home/$user"

  info "Creating ZFS dataset for '$user'"
  zfs create "$dataset"

  sleep 2

  info "Creating user '$user'"
  useradd \
    --create-home \
    --user-group \
    --groups wheel \
    --shell /bin/bash \
    --base-dir /tmp \
    --comment "$comment" \
    "$user"

  info "Migrating user home to $dataset ZFS dataset"
  chown -R "${user}:${user}" "/home/$user"
  chmod 0750 "/home/$user"
  (
    cd "/tmp/$user"
    tar cpf - . | tar xpf - -C "/home/$user"
  )
  usermod -d "/home/$user" "$user"
  rm -rf "/tmp/$user"

  info "Delegating ZFS datasets under $dataset to '$user'"
  zfs allow "$user" create,mount,mountpoint,snapshot "$dataset"

  info "Setting password for '$user'"
  chpasswd <<<"$user:$passwd"
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
      printf -- "ERROR: %s\\n" "${1:-}"
      ;;
  esac
  exit "${2:-99}"
}

read_passwd() {
  local user="$1"

  while true; do
    echo -n "Enter password for $user: "
    read -r -s PASSWD
    echo

    echo -n "Retype password: "
    read -r -s retype
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit 99
fi

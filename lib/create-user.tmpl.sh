#!/usr/bin/env bash

print_usage() {
  local program="$1"
  local version="$2"
  local author="$3"

  echo "$program $version

    Creates an Arch Linux user.

    USAGE:
        $program [FLAGS] <USERNAME> <FULLNAME>

    FLAGS:
        -h, --help      Prints this message
        -V, --version   Prints version information

    ARGS:
        <USERNAME>    Admin username (ex: \`jdoe')
        <FULLNAME>    Admin name (ex: \`Jane Doe')

    AUTHOR:
        $author
    " | sed 's/^ \{1,4\}//g'
}

main() {
  set -eu
  if [[ -n "${DEBUG:-}" ]]; then set -x; fi
  if [[ -n "${TRACE:-}" ]]; then set -xv; fi

  local program version author
  program="$(basename "$0")"
  version="@@version@@"
  author="Fletcher Nichol <fnichol@nichol.ca>"

  # The name of the base root dataset
  local base_dataset="@@base_dataset@@"

  parse_cli_args "$program" "$version" "$author" "$@"
  local user="$USER"
  local comment="$COMMENT"
  unset USER COMMENT

  need_cmd basename
  need_cmd chmod
  need_cmd chown
  need_cmd chpasswd
  need_cmd rm
  need_cmd tar
  need_cmd useradd
  need_cmd zfs

  section "Creating '$user' with dedicated ZFS dataset"

  read_passwd "$user"
  # shellcheck disable=SC2153
  local passwd="$PASSWD"
  unset PASSWD

  create_user "$user" "$comment" "$passwd" "$base_dataset"
}

parse_cli_args() {
  local program version author
  program="$1"
  shift
  version="$1"
  shift
  author="$1"
  shift

  OPTIND=1
  # Parse command line flags and options
  while getopts "hV-:" opt; do
    case $opt in
      h)
        print_usage "$program" "$version" "$author"
        exit 0
        ;;
      V)
        print_version "$program" "$version"
        exit 0
        ;;
      -)
        case "$OPTARG" in
          help)
            print_usage "$program" "$version" "$author"
            exit 0
            ;;
          version)
            print_version "$program" "$version" "true"
            exit 0
            ;;
          '')
            # "--" terminates argument processing
            break
            ;;
          *)
            print_usage "$program" "$version" "$author" >&2
            die "invalid argument --$OPTARG"
            ;;
        esac
        ;;
      \?)
        print_usage "$program" "$version" "$author" >&2
        die "invalid option: -$OPTARG"
        ;;
    esac
  done
  # Shift off all parsed token in `$*` so that the subcommand is now `$1`.
  shift "$((OPTIND - 1))"

  if [[ -z "${1:-}" ]]; then
    print_usage "$program" "$version" "$author" >&2
    die "required argument: <USERNAME>"
  fi
  USER="$1"
  shift

  if [[ -z "${1:-}" ]]; then
    print_usage "$program" "$version" "$author" >&2
    die "required argument: <FULLNAME>"
  fi
  COMMENT="$1"
  shift
}

create_user() {
  local user="$1"
  local comment="$2"
  local passwd="$3"
  local base="$4"
  local dataset="$base/home/$user"

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

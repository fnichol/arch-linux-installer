#!/usr/bin/env bash

print_usage() {
  local program="$1"
  local version="$2"
  local author="$3"

  echo "$program $version

    Arch Linux remote installer.

    USAGE:
        $program [FLAGS] <HOST> <ARGS>...

    FLAGS:
        -h, --help      Prints this message
        -v, --verbose   Prints verbose output of the \`install.sh' program
        -V, --version   Prints version information

    ARGS:
        <ARGS>      Arguments are passed to the \`install.sh' program.
        <HOST>      Host running the ArchISO live image.

    AUTHOR:
        $author
    " | sed 's/^ \{1,4\}//g'
}

main() {
  set -eu
  if [[ -n "${DEBUG:-}" ]]; then set -x; fi
  if [[ -n "${TRACE:-}" ]]; then set -xv; fi

  # shellcheck source=vendor/lib/libsh.sh
  . "${0%/*}/vendor/lib/libsh.sh"

  need_cmd basename
  need_cmd scp
  need_cmd ssh
  need_cmd ssh-copy-id

  local program version author
  program="$(basename "$0")"
  version="0.1.0"
  author="Fletcher Nichol <fnichol@nichol.ca>"

  # Parse CLI arguments and set local variables
  parse_cli_args "$program" "$version" "$author" "$@"
  local host="$HOST"
  local args=("${ARGS[@]}")
  local verbose="$VERBOSE"
  unset HOST ARGS VERBOSE

  authenticate "$host"
  copy_installation_files "$host"
  run_install "$verbose" "$host" "${args[@]}"
}

parse_cli_args() {
  local program version author
  program="$1"
  shift
  version="$1"
  shift
  author="$1"
  shift

  VERBOSE=""

  OPTIND=1
  # Parse command line flags and options
  while getopts ":hvV-:" opt; do
    case $opt in
      h)
        print_usage "$program" "$version" "$author"
        exit 0
        ;;
      v)
        VERBOSE=true
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
          verbose)
            VERBOSE=true
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
    die "required argument: <HOST>"
  fi
  HOST="$1"
  shift

  ARGS=("$@")
}

authenticate() {
  local host="$1"

  section "Authenticating 'root@$host'"
  ssh-copy-id \
    -f \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    "root@$host"
}

copy_installation_files() {
  local host="$1"

  section "Uploading installation files"
  scp \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    -r \
    ./override* \
    ./*.sh \
    ./vendor \
    "root@$host:"
}

run_install() {
  local verbose="$1"
  shift
  local host="$1"
  shift

  section "Running installer on 'root@$host'"
  ssh \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    -t \
    "root@$host" \
    env DEBUG="$verbose" ./install.sh "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit 99
fi

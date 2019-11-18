#!/usr/bin/env bash

main() {
  set -eu
  if [[ -n "${DEBUG:-}" ]]; then set -x; fi

  version='0.1.0'
  author='Fletcher Nichol <fnichol@nichol.ca>'
  PROGRAM="$(basename "$0")"

  # Parse CLI arguments and set local variables
  parse_cli_args "$@"
  local host="$HOST"
  local args=("${ARGS[@]}")
  local verbose="$VERBOSE"
  unset HOST ARGS VERBOSE

  authenticate "$host"
  copy_installation_files "$host"
  run_install "$verbose" "$host" "${args[@]}"
}

print_help() {
  echo "$PROGRAM $version

$author

Arch Linux remote installer.

USAGE:
        $PROGRAM [FLAGS] <HOST> <ARGS>...

FLAGS:
    -h  Prints this message
    -v  Prints verbose output of the \`install.sh' program
    -V  Prints version information

ARGS:
    <ARGS>      Arguments are passed to the \`install.sh' program.
    <HOST>      Host running the ArchISO live image.
"
}

parse_cli_args() {
  VERBOSE=""

  OPTIND=1
  # Parse command line flags and options
  while getopts ":vVh" opt; do
    case $opt in
      v)
        VERBOSE=true
        ;;
      V)
        echo "$PROGRAM $version"
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

  if [[ -z "${1:-}" ]]; then
    print_help
    exit_with "Required argument: <HOST>" 2
  fi
  HOST="$1"
  shift

  ARGS=("$@")
}

authenticate() {
  local host="$1"

  ssh-copy-id \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    "root@$host"
}

copy_installation_files() {
  local host="$1"

  scp \
    -o UserKnownHostsFile=/dev/null \
    -o StrictHostKeyChecking=no \
    -r \
    ./override* \
    ./*.sh \
    "root@$host:"
}

run_install() {
  local verbose="$1"
  shift
  local host="$1"
  shift

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

#!/usr/bin/env bash

main() {
  set -euo pipefail
  if [[ -n "${DEBUG:-}" ]]; then set -x; fi
  if [[ -n "${TRACE:-}" ]]; then set -xv; fi

  # shellcheck source=vendor/lib/libsh.sh
  . "${0%/*}/../vendor/lib/libsh.sh"

  need_cmd docker

  local cwd mount_dir default_program
  cwd="$(pwd)"
  mount_dir="/mnt"
  default_program="bash"
  local args=(
    --rm
    --tty
    --interactive
    --privileged
    --volume
    "$cwd:$mount_dir"
    --workdir
    "$mount_dir"
  )
  if [[ -n "${DEBUG:-}" ]]; then
    args+=(--env)
    args+=("DEBUG=$DEBUG")
  fi
  args+=("${DOCKER_IMAGE:-archlinux}")
  if [[ -n "${*:-}" ]]; then
    args+=("$@")
    section "Running custom command '$*' in a Docker container"
  else
    args+=("$default_program")
    section "Running '$default_program' in a Docker container"
  fi

  info "Running: 'docker run ${args[*]}'"
  docker run "${args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit 99
fi
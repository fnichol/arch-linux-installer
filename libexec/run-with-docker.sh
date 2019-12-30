#!/usr/bin/env bash

main() {
  set -euo pipefail
  if [[ -n "${DEBUG:-}" ]]; then set -x; fi
  if [[ -n "${TRACE:-}" ]]; then set -xv; fi

  # shellcheck source=vendor/lib/libsh.sh
  . "${0%/*}/../vendor/lib/libsh.sh"

  need_cmd docker
  need_cmd wc

  local image="${DOCKER_IMAGE:-arch-linux-installer-base}"
  local debug="${DEBUG:-}"

  if ! image_exists "$image"; then
    pushd "${0%/*}/../libexec/docker" >/dev/null
    docker build -t "$image" .
    popd >/dev/null
  fi

  run "$image" "$debug" "$@"
}

image_exists() {
  local image="$1"

  if [[ $(docker images -q "$image" | wc -l) -gt 0 ]]; then
    return 0
  else
    return 1
  fi
}

run() {
  local image debug cwd mount_dir default_program
  image="$1"
  shift
  debug="$1"
  shift

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
  if [[ -n "$debug" ]]; then
    args+=(--env)
    args+=("DEBUG=$debug")
  fi
  args+=("$image")
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

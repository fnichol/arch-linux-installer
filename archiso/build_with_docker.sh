#!/usr/bin/env bash

main() {
  set -euo pipefail
  if [[ -n "${DEBUG:-}" ]]; then set -x; fi
  if [[ -n "${TRACE:-}" ]]; then set -xv; fi

  need_cmd docker

  local cwd default_program
  cwd="$(pwd)"
  default_program="/mnt/$(dirname "$0")/build_archiso.sh"
  local args=(
    --rm
    --privileged
    --volume
    "$cwd:/mnt"
  )
  if [[ -n "${DEBUG:-}" ]]; then
    args+=(--env)
    args+=("DEBUG=$DEBUG")
  fi
  if [[ -n "${*:-}" ]]; then
    args+=(--tty)
    args+=(--interactive)
  fi
  args+=("${DOCKER_IMAGE:-greyltc/archlinux}")
  if [[ -n "${*:-}" ]]; then
    args+=("$@")
  else
    args+=("$default_program")
  fi

  set -x
  time docker run "${args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit 99
fi

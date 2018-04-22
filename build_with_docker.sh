#!/usr/bin/env bash

main() {
  set -eu
  if [ -n "${DEBUG:-}" ]; then set -x; fi

  time docker run \
    --rm \
    --privileged \
    --volume "$(pwd)":/mnt \
    greyltc/archlinux \
    /mnt/build_archiso.sh
}

main "$@" || exit 99

#!/usr/bin/env bash
set -eu

if [ -n "${DEBUG:-}" ]; then
  set -x
fi

time docker run -ti --rm -v $(pwd):/mnt --privileged greyltc/archlinux \
  /mnt/build_archiso.sh

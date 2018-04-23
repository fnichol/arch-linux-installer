#!/usr/bin/env bash

main() {
  set -eu
  if [ -n "${DEBUG:-}" ]; then set -x; fi

  program="$(basename "$0")"
  workdir="$(mktemp -d -p /home -t "$(basename "$0")".XXXXXXXX)" || exit 12
  trap 'cleanup' INT TERM EXIT

  prepare
  add_custom_repo
  add_zfs_repo
  add_zfs_package
  add_openssh
  build_image

  info "All done, image is in $(dirname "$0")/out"
}

cleanup() {
  e=$?
  info "Cleanup up $workdir"
  rm -rf $workdir
  if [ -n "${web_pid:-}" ]; then
    info "Stopping web server"
    kill $web_pid
  fi
  exit $e
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

prepare() {
  info "Preparing system and $workdir"

  mkdir -pv "$workdir"
  # Freshen package database and upgrade
  pacman -Syyu --noconfirm
  # Install the `archiso` package
  pacman -S --noconfirm archiso
  cp -rv /usr/share/archiso/configs/releng/* "$workdir"
}

add_custom_repo() {
  if [ -d "$(dirname "$0")/custom" ]; then
    info "Adding custom repository to the image"

    pacman -S --noconfirm ruby

    ruby -rwebrick -e"
      WEBrick::HTTPServer.new(
        :Port => 8000,
        :DocumentRoot => %{$(dirname "$0")/custom}
      ).start
    " &
    sleep 1
    web_pid=$!

    cat "$workdir/pacman.conf" | while read -r line; do
      if [ "$line" = '[core]' ]; then
        echo '[custom]'
        echo 'SigLevel = Optional TrustAll'
        echo 'Server = http://127.0.0.1:8000'
        echo ''
      fi
      echo "$line"
    done > "$workdir/pacman.conf.new"
    mv -v "$workdir/pacman.conf.new" "$workdir/pacman.conf"
  fi
}

add_zfs_repo() {
  info "Adding archzfs repository to the image"

  cat "$workdir/pacman.conf" | while read -r line; do
    if [ "$line" = '[core]' ]; then
      echo '[archzfs]'
      echo 'SigLevel = Optional TrustAll'
      echo 'Server = http://archzfs.com/$repo/x86_64'
      echo ''
    fi
    echo "$line"
  done > "$workdir/pacman.conf.new"
  mv -v "$workdir/pacman.conf.new" "$workdir/pacman.conf"
}

add_zfs_package() {
  info "Adding the archzfs-linux package to the image"

  echo "archzfs-linux" >> "$workdir/packages.x86_64"
}

add_openssh() {
  info "Adding the OpenSSH to the image"

  cat <<'EOF' >> "$workdir/airootfs/root/customize_airootfs.sh"

# Add user arch with no home directory, in group 'wheel' and using 'zsh'
useradd -M -G wheel -s /usr/bin/zsh arch

# Set passwords
echo "arch:install" | chpasswd
echo "root:install" | chpasswd

# Enable sshd service
systemctl enable sshd.service
EOF
}

build_image() {
  info "Building image"

  cd "$workdir"
  mkdir -pv out
  ./build.sh -v
  mkdir -v -p "$(dirname "$0")/out"
  cp -v out/*.iso "$(dirname "$0")/out/"
}

main "$@" || exit 99

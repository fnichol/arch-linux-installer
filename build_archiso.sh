#!/usr/bin/env bash
set -eu

if [ -n "${DEBUG:-}" ]; then
  set -x
fi

info() {
  case "${TERM:-}" in
    *term | xterm-* | rxvt | screen | screen-*)
      printf -- "   \033[1;36m${program:-unknown}: \033[1;37m${1:-}\033[0m\n"
      ;;
    *)
      printf -- "   ${program:-unknown}: ${1:-}\n"
      ;;
  esac
  return 0
}

prepare() {
  info "Preparing system and $workdir"

  mkdir -pv "$workdir"
  # Freshen package database and upgrade
  pacman -Syyu
  # Install the `archiso` package
  pacman -S --noconfirm archiso
  cp -rv /usr/share/archiso/configs/releng/* "$workdir"
}

add_zfs_repo() {
  info "Adding archzfs repository to the image"

  cat "$workdir/pacman.conf" | while read line; do
    if [ "$line" = '[core]' ]; then
      echo '[archzfs]'
      echo 'SigLevel = Optional TrustAll'
      echo 'Server = http://archzfs.com/$repo/x86_64'
      echo ''
    fi
    echo $line
  done > "$workdir/pacman.conf.new"
  mv -v "$workdir/pacman.conf.new" "$workdir/pacman.conf"
}

add_zfs_package() {
  info "Adding the archzfs-linux package to the image"

  echo "archzfs-linux" >> "$workdir/packages.x86_64"
}

add_openssh() {
  info "Adding the OpenSSH to the image"

  echo "openssh" >> "$workdir/packages.both"
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
  cp -v out/*.iso "$(dirname $0)/"
}

main() {
  prepare
  add_zfs_repo
  add_zfs_package
  add_openssh
  build_image
}


# # Main Flow

# The short version of the program name which is used in logging output
program="$(basename $0)"

workdir="$(mktemp -d -p /home -t "$(basename $0)".XXXXXXXX)" || exit 12
# trap 'info "Cleanup up $workdir"; rm -rf $workdir; exit $?' INT TERM EXIT

main
exit 0

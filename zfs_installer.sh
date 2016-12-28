#!/usr/bin/env bash
set -eu

if [ -n "${DEBUG:-}" ]; then
  set -x
fi

print_help() {
  printf -- "$program $version

$author

Arch Linux with ZFS installer.

USAGE:
        $program [FLAGS] [OPTIONS] <DISK>

COMMON FLAGS:
    -h  Prints this message
    -V  Prints version information

ARGS:
    <DISK>      The disk to use for installation (ex: \`sda')

"
}

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

exit_with() {
  if [ -n "${DEBUG:-}" ]; then set -x; fi

  case "${TERM:-}" in
    *term | xterm-* | rxvt | screen | screen-*)
      echo -e "\033[1;31mERROR: \033[1;37m$1\033[0m"
      ;;
    *)
      echo "ERROR: $1"
      ;;
  esac
  exit ${2:-99}
}

in_chroot() {
  arch-chroot /mnt /bin/bash -c "$*"
}

partition_disk() {
  parted --script "/dev/$disk" \
    mklabel gpt \
    mkpart non-fs 0% 2 \
    mkpart primary 2 100% \
    set 1 bios_grub on \
    set 2 boot on
}

find_partid() {
  local retries=0

  while [ $retries -lt 5 ]; do
    for diskid in $(ls -1 /dev/disk/by-id/*); do
      if [ "$(readlink -f $diskid)" = "/dev/${disk}2" ]; then
        partid="$diskid"
        info "Found partition ID for /dev/${disk}2: $partid"
        return
      fi
    done

    retries=$(($retries + 1))
    info "Partition ID not found, sleeping and retrying ($retries/5)"
    sleep 3
  done

  exit_with "Could not find partition ID for /dev/${disk}2" 10
}

create_zpool() {
  modprobe zfs

  zpool create -f "$pool" "$partid"
  zfs set compression=on "$pool"
  zfs set atime=on "$pool"
  zfs set relatime=on "$pool"
}

create_datasets() {
  zfs create -o mountpoint=none "$pool/ROOT"
  zfs create -o mountpoint=/ "$pool/ROOT/default" || true
  zfs create -o mountpoint=/home "$pool/home"
}

prepare_pool() {
  zfs umount -a
  cat <<EOF > /etc/fstab
$pool/ROOT/default	/	zfs	rw,relatime,xattr,noacl	0 0
EOF
  zpool set bootfs="$pool/ROOT/default" "$pool"
  zpool export "$pool"
}

mount_pool_for_install() {
  zpool import -d /dev/disk/by-id -R /mnt "$pool"
}

gen_fstab() {
  mkdir -pv /mnt/etc
  genfstab -p /mnt | egrep ROOT/default > /mnt/etc/fstab
}

install_base() {
  pacstrap /mnt base

  info "Copying zpool.cache"
  mkdir -pv /mnt/etc/zfs
  cp -v /etc/zfs/zpool.cache /mnt/etc/zfs/

  info "Adding the archzfs repository to pacman.conf"
  awk -i inplace '/\[core\]/ {\
print "[archzfs]\n\
SigLevel = Optional TrustAll\n\
Server = http://archzfs.com/$repo/x86_64\n\
"}1' /mnt/etc/pacman.conf

  info "Modifying HOOKS in mkinitcpio.conf"
  sed -i 's|^HOOKS=.*|HOOKS="base udev autodetect modconf block keyboard zfs filesystems shutdown"|g' /mnt/etc/mkinitcpio.conf

  info "Adding archzfs repository key"
  in_chroot \
    "pacman-key -r 5E1ABF240EE7A126; pacman-key --lsign-key 5E1ABF240EE7A126"

  info "Installing ZFS, Intel microcode update, and GRUB"
  in_chroot \
    "pacman -Sy; pacman -S --noconfirm zfs-linux intel-ucode grub os-prober"

  info "Adding ZFS entry to GRUB menu"
  awk -i inplace '/BEGIN .*10_linux/ {print;
print "menuentry \"Arch Linux ZFS\" {\n\
\tlinux /ROOT/default/@/boot/vmlinuz-linux zfs=@@pool@@/ROOT/default rw\n\
\tinitrd /ROOT/default/@/boot/initramfs-linux.img\n\
}";
next}1' /mnt/boot/grub/grub.cfg
  sed -i "s|@@pool@@|$pool|g" /mnt/boot/grub/grub.cfg

  info "Update initial ramdisk (initrd) with ZFS support"
  in_chroot "mkinitcpio -p linux"

  info "Enable systemd ZFS service"
  in_chroot "systemctl enable zfs.target"
}

install_grub() {
  info "Installing GRUB"
  in_chroot \
    "ln -snf ${disk}2 /dev/$(basename $partid); grub-install /dev/${disk}"
}

finalize_pool() {
  zfs umount -a
  zpool export "$pool"
}

main() {
  partition_disk
  find_partid
  create_zpool
  create_datasets
  prepare_pool
  mount_pool_for_install
  gen_fstab
  install_base
  install_grub
  finalize_pool
}


# # Main Flow

# The current version of this program
version='0.1.0'
# The author of this program
author='Fletcher Nichol <fnichol@nichol.ca>'
# The short version of the program name which is used in logging output
program="$(basename $0)"
# The name of the zpool
pool=tank


# ## CLI Argument Parsing

# Parse command line flags and options.
while getopts "Vh" opt; do
  case $opt in
    V)
      echo "$program $version"
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

if [ -z "${1:-}" ]; then
  print_help
  exit_with "Required argument: <DISK>" 2
fi
disk="$1"
shift

main
exit 0

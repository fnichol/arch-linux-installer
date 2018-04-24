#!/usr/bin/env bash

main() {
  set -eu
  if [ -n "${DEBUG:-}" ]; then set -x; fi

  version='0.1.0'
  author='Fletcher Nichol <fnichol@nichol.ca>'
  program="$(basename "$0")"

  # shellcheck source=_common.sh
  . "${0%/*}/_common.sh"

  # The name of the zpool
  pool=tank

  parse_cli_args "$@"

  partition_disk
  find_partid
  find_esp_dev
  create_esp
  create_zpool
  create_datasets
  prepare_pool
  mount_pool_for_install
  gen_fstab
  install_base
  install_grub
  finalize_pool
}

print_help() {
  echo "$program $version

$author

Arch Linux with ZFS installer.

USAGE:
        $program [FLAGS] [OPTIONS] <DISK> <NETIF>

FLAGS:
    -e  Encrypt the partition for the zpool (default: no)
    -h  Prints this message
    -V  Prints version information

OPTIONS:
    -p <PARTITION_TYPE>   Choose a partitioning type (default: whole)
    -P <ROOT_PASSWD_FILE> Read initial root password from file (default: prompt)

ARGS:
    <DISK>      The disk to use for installation (ex: \`nvme0n1')
                This can be found by using the \`lsblk' program.
    <NETIF>     The network interface to setup for DHCP (ex: \`ens33')
                This can be found by using the \`ip addr' program.
"
}

parse_cli_args() {
  OPTIND=1
  # Parse command line flags and options
  while getopts ":ep:P:Vh" opt; do
    case $opt in
      e)
        ENCRYPT=true
        ;;
      p)
        case "$OPTARG" in
          whole)
            # skip
            ;;
          *)
            print_help
            exit_with "Invalid partition type: $OPTARG" 2
            ;;
        esac
        PART_TYPE="$OPTARG"
        ;;
      P)
        if [ ! -f "$OPTARG" ]; then
          print_help
          exit_with "Password file does not exist: $OPTARG" 3
        fi
        ROOT_PASSWD="$(cat "$OPTARG")"
        ;;
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
  DISK="$1"
  shift

  if [ -z "${1:-}" ]; then
    print_help
    exit_with "Required argument: <NETIF>" 2
  fi
  NETIF="$1"
  shift

  if [ -z "${PART_TYPE:-}" ]; then
    PART_TYPE=whole
  fi

  if [ -z "${ROOT_PASSWD:-}" ]; then
    read_passwd "root"
    ROOT_PASSWD="$PASSWD"
    unset PASSWD
  fi
}

in_chroot() {
  arch-chroot /mnt /bin/bash -c "$*"
}

partition_disk() {
  case "$PART_TYPE" in
    whole)
      parted --script "/dev/$DISK" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 551MiB \
        mkpart primary 551MiB 100% \
        set 1 boot on
      ;;
    *)
      print_help
      exit_with "Invalid partition type: $PART_TYPE" 2
      ;;
  esac
}

find_partid() {
  local retries=0

  while [ $retries -lt 5 ]; do
    for diskid in /dev/disk/by-id/*; do
      if [ "$(readlink -f "$diskid")" = "/dev/${DISK}p2" ]; then
        partid="$diskid"
        info "Found partition ID for /dev/${DISK}2: $partid"
        return
      fi
    done

    retries=$((retries + 1))
    info "Partition ID not found, sleeping and retrying ($retries/5)"
    sleep 3
  done

  exit_with "Could not find partition ID for /dev/${DISK}2" 10
}

find_esp_dev() {
  esp_dev="$(fdisk -l "/dev/$DISK" \
    | grep 'EFI System$' \
    | head -n 1 \
    | cut -d ' ' -f 1)"
  if [ -z "$esp_dev" ]; then
    exit_with "Could not find an EFI System Partition (ESP) on /dev/$DISK" 5
  fi
}

create_esp() {
  info "Creating EFI System Partition (ESP) filesystem on $esp_dev"
  mkfs.fat -F32 "$esp_dev"
}

create_zpool() {
  # Load the ZFS kernel module
  modprobe zfs

  # Create the root pool
  zpool create -f "$pool" "$partid"

  # Set default tunings for pool
  #
  # See: https://wiki.archlinux.org/index.php/ZFS#General_2
  zfs set compression=on "$pool"
  zfs set atime=on "$pool"
  zfs set relatime=on "$pool"
}

create_datasets() {
  # Setup to support ZFS boot environments
  #
  # See: https://wiki.archlinux.org/index.php/Installing_Arch_Linux_on_ZFS#Create_your_datasets
  zfs create -o mountpoint=none "$pool/ROOT"
  zfs create -o mountpoint=/ -o compression=lz4 "$pool/ROOT/default" || true

  # Create dataset for home
  zfs create -o mountpoint=/home -o compression=lz4 "$pool/home"
}

prepare_pool() {
  # Unmoiunt datasets
  zfs umount -a

  # Set mountpoints for datasets
  zfs set mountpoint=/ "$pool/ROOT/default"
  zfs set mountpoint=/home "$pool/home"

  cat <<EOF > /etc/fstab
$pool/ROOT/default	/	zfs	defaults,noatime	0 0
EOF

  # Set the bootfs property on the descendant root filesystem so the boot
  # loader knows where to find the operating system.
  zpool set bootfs="$pool/ROOT/default" "$pool"

  # Export the pool
  zpool export "$pool"
}

mount_pool_for_install() {
  # Re-import the pool
  zpool import -d /dev/disk/by-id -R /mnt "$pool"

  # Mount ESP
  mkdir -pv /mnt/boot/efi
  mount "$esp_dev" /mnt/boot/efi
}

gen_fstab() {
  mkdir -pv /mnt/etc
  genfstab -U -p /mnt | grep -E ROOT/default > /mnt/etc/fstab
}

# shellcheck disable=SC1004
install_base() {
  local extra_pkgs=(
    zfs-linux
    intel-ucode grub efibootmgr os-prober
    openssh sudo
  )

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

  info "Adding archzfs repository key"
  in_chroot \
    "pacman-key -r 5E1ABF240EE7A126 && pacman-key --lsign-key 5E1ABF240EE7A126"

  info "Installing extra packages"
  # shellcheck disable=SC2145
  in_chroot "pacman -Sy; pacman -S --noconfirm ${extra_pkgs[@]}"

  info "Modifying HOOKS in mkinitcpio.conf"
  sed -i 's|^HOOKS=.*|HOOKS="base udev autodetect modconf block keyboard zfs filesystems shutdown"|g' /mnt/etc/mkinitcpio.conf

  info "Enable systemd ZFS service"
  in_chroot "systemctl enable zfs.target"
  in_chroot "systemctl enable zfs-mount"

  info "Enabling DHCP networking on $NETIF"
  in_chroot "systemctl enable dhcpcd@${NETIF}.service"

  info "Enabling OpenSSH service"
  in_chroot "systemctl enable sshd.socket"

  info "Set initial root password"
  in_chroot "chpasswd <<< 'root:$ROOT_PASSWD'"

  info "Setting sudoers policy"
  in_chroot "echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/01_wheel"

  info "Remove default .bashrc in /etc/skell"
  in_chroot "rm -f /etc/skel/.bashrc"
}

install_grub() {
  info "Installing GRUB"
  in_chroot \
    "ZPOOL_VDEV_NAME_PATH=1 grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB"

  info "Regenerate grub.cfg"
  in_chroot \
    "ZPOOL_VDEV_NAME_PATH=1 grub-mkconfig -o /boot/grub/grub.cfg"

  info "Update initial ramdisk (initrd) with ZFS support"
  in_chroot "mkinitcpio -p linux"
}

finalize_pool() {
  umount /mnt/boot/efi
  zfs umount -a
  zpool export "$pool"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit 99
fi

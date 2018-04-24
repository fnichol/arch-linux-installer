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
  set_root_passwd
  enable_services
  install_grub

  install_hardware_specific_pkgs
  set_timezone
  setup_clock
  generate_locales
  find_fastest_mirrors
  add_yaourt_repo

  copy_create_user_script

  if [ -n "${INSTALL_X:-}" ]; then
    install_x_hardware_specific_pkgs
    setup_x
  fi

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
    -X  Skip installation and setup of GUI/X environment (default: install)

OPTIONS:
    -p <PARTITION_TYPE>   Choose a partitioning type (default: whole)
    -P <ROOT_PASSWD_FILE> Read initial root password from file (default: prompt)
    -t <TZ>               Timezone (ex: \`America/Edmonton') (default: \`UTC')

ARGS:
    <DISK>      The disk to use for installation (ex: \`nvme0n1')
                This can be found by using the \`lsblk' program.
    <NETIF>     The network interface to setup for DHCP (ex: \`ens33')
                This can be found by using the \`ip addr' program.
"
}

parse_cli_args() {
  # Default partition type to whole
  PART_TYPE=whole
  # Default timezone to UTC
  TZ=UTC
  # Default installation of X to true
  INSTALL_X=true

  OPTIND=1
  # Parse command line flags and options
  while getopts ":ep:P:t:XVh" opt; do
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
      t)
        TZ="$OPTARG"
        ;;
      X)
        unset INSTALL_X
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

  info "Installing extra base packages"
  in_chroot "pacman -Sy; pacman -S --noconfirm ${extra_pkgs[*]}"

  info "Setting sudoers policy"
  in_chroot "echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/01_wheel"

  info "Remove default .bashrc in /etc/skell"
  in_chroot "rm -f /etc/skel/.bashrc"
}

set_root_passwd() {
  info "Set initial root password"
  in_chroot "chpasswd <<< 'root:$ROOT_PASSWD'"
}

enable_services() {
  info "Enable zfs.target service"
  in_chroot "systemctl enable zfs.target"
  info "Enable zfs-mount service"
  in_chroot "systemctl enable zfs-mount"

  info "Enabling dhcpd@${NETIF} networking service"
  in_chroot "systemctl enable dhcpcd@${NETIF}.service"

  info "Enabling sshd service"
  in_chroot "systemctl enable sshd.socket"
}

install_grub() {
  info "Installing GRUB"
  in_chroot \
    "ZPOOL_VDEV_NAME_PATH=1 grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB"

  info "Regenerate grub.cfg"
  in_chroot \
    "ZPOOL_VDEV_NAME_PATH=1 grub-mkconfig -o /boot/grub/grub.cfg"

  info "Modifying HOOKS in mkinitcpio.conf"
  sed -i 's|^HOOKS=.*|HOOKS="base udev autodetect modconf block keyboard zfs filesystems shutdown"|g' /mnt/etc/mkinitcpio.conf

  info "Update initial ramdisk (initrd) with ZFS support"
  in_chroot "mkinitcpio -p linux"
}

install_hardware_specific_pkgs() {
  if is_in_vmware; then
    info "Installing VMware-specific software"
    in_chroot "pacman -S --noconfirm open-vm-tools"
  fi
}

set_timezone() {
  # * https://wiki.archlinux.org/index.php/Time
  # * https://wiki.archlinux.org/index.php/Systemd-timesyncd
  info "Setting up timezone to $TZ"
  in_chroot "timedatectl set-timezone '$TZ'"
}

setup_clock() {
  # If hardware clock is set to local time, like in VMware Fusion
  #
  # * http://www.linuxfromscratch.org/lfs/view/stable-systemd/chapter07/clock.html
  if is_in_vmware; then
    info "Enabling vmtoolsd service"
    in_chroot "systemctl enable vmtoolsd.service"

    # TODO fn: this doesn't appear to get set--is it needed?
    info "Setting time adjustment due to local time in hardware clock"
    in_chroot "timedatectl set-local-rtc 1"

    info "Enabling timesync"
    in_chroot "vmware-toolbox-cmd timesync enable"

    info "Creating hwclock-resume service unit to update clock after sleep"
    cat <<'EOF' > /mnt/etc/systemd/system/hwclock-resume.service
[Unit]
Description=Update hardware clock after resuming from sleep
After=suspend.target

[Service]
Type=oneshot
ExecStart=/usr/bin/hwclock --hctosys --utc

[Install]
WantedBy=suspend.target
EOF
    # TODO fn: does this work?
    in_chroot "systemctl daemon-reload"

    info "Enabling hwclock-resume service"
    in_chroot "systemctl enable hwclock-resume.service"
  else
    info "Enabling ntp"
    in_chroot "timedatectl set-ntp true"
  fi
}

generate_locales() {
  local locales=(en_CA.UTF-8 en_US.UTF-8 en_US)
  local default_locale="en_US.UTF-8"

  for l in "${locales[@]}"; do
    # shellcheck disable=SC1117
    sed -i "s|^#\(${l}\)|\1|" /mnt/etc/locale.gen
  done; unset l
  info "Generating locales for ${locales[*]}"
  in_chroot "locale-gen"
  info "Setting default locale to $default_locale"
  echo "LANG=$default_locale" > /mnt/etc/locale.conf
}

find_fastest_mirrors() {
  # * https://wiki.archlinux.org/index.php/Mirrors
  info "Calculating fastest mirrors"
  cp /mnt/etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist.dist
  curl 'https://www.archlinux.org/mirrorlist/?country=CA&country=US&protocol=http&ip_version=4' -o /mnt/etc/pacman.d/mirrorlist.new
  sed -i 's/^#Server/Server/' /mnt/etc/pacman.d/mirrorlist.new
  in_chroot \
    "rankmirrors -n 6 /etc/pacman.d/mirrorlist.new > /etc/pacman.d/mirrorlist"
  rm -f /mnt/etc/pacman.d/mirrorlist.new
  in_chroot "pacman -Syyu"
}

add_yaourt_repo() {
  info "Adding repository for Yaourt"
  cat <<'EOF' >> /mnt/etc/pacman.conf

[archlinuxfr]
SigLevel = Never
Server = http://repo.archlinux.fr/$arch
EOF
  in_chroot "pacman -Sy --noconfirm"

  info "Installing yaourt"
  in_chroot "pacman -S --noconfirm yaourt"
}

copy_create_user_script() {
  info "Copying create_user script"
  cp -p -v "${0%/*}/create_user.sh" /mnt/root/
}

install_x_hardware_specific_pkgs() {
  if is_in_vmware; then
    local vmware_pkgs=(
      gtkmm3
      libxtst
      mesa-libgl
      xf86-input-vmmouse
      xf86-video-vmware
    )

    info "Installing VMware-specific software"
    in_chroot "pacman -S --noconfirm ${vmware_pkgs[*]}"

    info "Enabling vmware-vmblock-fuse service"
    in_chroot "systemctl enable vmware-vmblock-fuse.service"
  fi
}

setup_x() {
  local x_pkgs=(
    dmenu
    i3
    termite
    xf86-input-evdev
    xorg-server
    xorg-xinit
  )

  info "Installing X, a window manager, and utilities"
  in_chroot "pacman -S --noconfirm ${x_pkgs[*]}"

  info "Creating default xinitrc for startx"
  local xi=/mnt/etc/X11/xinit/xinitrc
  rm -f "$xi"
  touch "$xi"
  if is_in_vmware; then
    echo "/usr/sbin/vmware-user-suid-wrapper" >> "$xi"
  fi
  echo "xset r rate 200 30" >> "$xi"
  echo "exec i3" >> "$xi"
}

finalize_pool() {
  umount /mnt/boot/efi
  zfs umount -a
  zpool export "$pool"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit 99
fi

#!/usr/bin/env bash

main() {
  set -eu
  if [[ -n "${DEBUG:-}" ]]; then set -x; fi

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
  encrypt_partition
  set_zpool_dev
  create_zpool
  create_datasets
  prepare_pool
  mount_pool_for_install

  gen_fstab
  add_custom_repo
  install_base
  setup_zpool_cache
  set_root_passwd
  enable_services
  install_grub

  install_hardware_specific_pkgs
  set_timezone
  setup_clock
  generate_locales
  find_fastest_mirrors

  copy_create_user_script

  if [[ -n "${INSTALL_X:-}" ]]; then
    install_x_hardware_specific_pkgs
    setup_x
  fi

  finalize_pool
  finish
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
    -a <PARTITION>            Choose a partition for type partition
                              (ex: nvme0n1p5)
    -p <PARTITION_TYPE>       Choose a partitioning type (default: whole)
                              (values: existing, remaining, whole)
    -P <ROOT_PASSWD_FILE>     Read initial root password from file
                              (default: prompt)
    -t <TZ>                   Timezone (ex: \`America/Edmonton')
                              (default: \`UTC')

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
  while getopts ":a:ep:P:t:XVh" opt; do
    case $opt in
      a)
        PARTITION="$OPTARG"
        ;;
      e)
        ENCRYPT=true
        ;;
      p)
        case "$OPTARG" in
          existing | remaining | whole)
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

  if [[ -z "${1:-}" ]]; then
    print_help
    exit_with "Required argument: <DISK>" 2
  fi
  DISK="$1"
  shift

  if [[ -z "${1:-}" ]]; then
    print_help
    exit_with "Required argument: <NETIF>" 2
  fi
  NETIF="$1"
  shift

  if [[ "$PART_TYPE" == "existing" && -z "${PARTITION:-}" ]]; then
    print_help
    exit_with "Partition (-a) required when partition type is 'existing'" 2
  fi

  if [[ -z "${ROOT_PASSWD:-}" ]]; then
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
    existing)
      partition="$PARTITION"
      info "Using existing partition $partition on disk $DISK"
      ;;
    remaining)
      info "Partitioning remaining space on disk $DISK"
      local start num

      # Find last free space block on the disk
      start="$(parted "/dev/$DISK" unit MiB print free \
        | grep 'Free Space' \
        | tail -n 1 \
        | awk '{print $1}')"
      # Create a partition filling the remaining part of the disk
      parted --script "/dev/$DISK" \
        mkpart primary "$start" 100%
      # Determine the partition number for the newly created partition
      num="$(parted "/dev/$DISK" unit MiB print \
        | awk "\$2 == \"$start\" {print \$1}")"

      partition="${DISK}p${num}"
      ;;
    whole)
      info "Partitioning whole disk $DISK"
      parted --script "/dev/$DISK" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 551MiB \
        mkpart primary 551MiB 100% \
        set 1 boot on

      partition="${DISK}p2"
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
      if [[ "$(readlink -f "$diskid")" == "/dev/$partition" ]]; then
        partid="$diskid"
        info "Found partition ID for /dev/$partition: $partid"
        return
      fi
    done

    retries=$((retries + 1))
    info "Partition ID not found, sleeping and retrying ($retries/5)"
    sleep 3
  done

  exit_with "Could not find partition ID for /dev/$partition" 10
}

find_esp_dev() {
  esp_dev="$(fdisk -l "/dev/$DISK" \
    | grep 'EFI System$' \
    | head -n 1 \
    | cut -d ' ' -f 1)"
  if [[ -z "$esp_dev" ]]; then
    exit_with "Could not find an EFI System Partition (ESP) on /dev/$DISK" 5
  else
    info "Found EFI System Partition (ESP) $esp_dev on /dev/$DISK"
  fi
}

create_esp() {
  case "$PART_TYPE" in
    whole)
      info "Creating EFI System Partition (ESP) filesystem on $esp_dev"
      mkfs.fat -F32 "$esp_dev"
      ;;
    *)
      # Partition already exists
      ;;
  esac
}

encrypt_partition() {
  if [[ -n "${ENCRYPT:-}" ]]; then
    info "Encrypting $partid partition"
    cryptsetup luksFormat \
      --cipher aes-xts-plain64 \
      --hash sha512 \
      "$partid"
    cryptsetup open --type luks "$partid" cryptroot
  fi
}

set_zpool_dev() {
  if [[ -n "${ENCRYPT:-}" ]]; then
    zpool_dev="/dev/mapper/cryptroot"
  else
    # If no encryption is used, then set the zpool device to the partid
    zpool_dev="$partid"
  fi

  info "Using the $zpool_dev for the zpool device"
}

create_zpool() {
  info "Loading the ZFS kernel module"
  modprobe zfs

  info "Creating the root zpool '$pool' on $zpool_dev"
  zpool create -f "$pool" "$zpool_dev"

  info "Setting default ZFS tunings for $pool"
  # See: https://wiki.archlinux.org/index.php/ZFS#General_2
  zfs set compression=on "$pool"
  zfs set atime=on "$pool"
  zfs set relatime=on "$pool"
}

create_datasets() {
  info "Creating ZFS datasets to support ZFS boot environments"
  # See: https://wiki.archlinux.org/index.php/Installing_Arch_Linux_on_ZFS#Create_your_datasets
  zfs create -o mountpoint=none "$pool/ROOT"
  zfs create -o mountpoint=/ -o compression=lz4 "$pool/ROOT/default" || true

  info "Creating ZFS dataset for /home"
  zfs create -o mountpoint=/home -o compression=lz4 "$pool/home"
}

prepare_pool() {
  info "Unmounting all ZFS datasets"
  zfs umount -a

  info "Setting mountpoints for ZFS datasets"
  zfs set mountpoint=/ "$pool/ROOT/default"
  zfs set mountpoint=/home "$pool/home"

  info "Writing out initial /etc/fstab"
  cat <<EOF >/etc/fstab
$pool/ROOT/default	/	zfs	defaults,noatime	0 0
EOF

  info "Setting bootfs property on $pool/ROOT/default"
  # Set the bootfs property on the descendant root filesystem so the boot
  # loader knows where to find the operating system.
  zpool set bootfs="$pool/ROOT/default" "$pool"

  info "Exporting the pool $pool"
  zpool export "$pool"
}

mount_pool_for_install() {
  info "Re-importing the pool $pool"
  zpool import -d /dev/disk/by-id -R /mnt "$pool"

  info "Mounting the EFI System Partition (ESP) device $esp_dev"
  mkdir -pv /mnt/boot/efi
  mount "$esp_dev" /mnt/boot/efi
}

gen_fstab() {
  info "Using genfstab to generate system /etc/fstab"
  mkdir -pv /mnt/etc
  genfstab -U -p /mnt | grep -E ROOT/default >/mnt/etc/fstab
}

add_custom_repo() {
  local repo_path

  if [ -d "$(dirname "$0")/custom" ]; then
    info "Detected and adding a custom repository to pacman.conf"
    repo_path="$(readlink -f "$(dirname "$0")/custom")"

    mkdir -p /var/local/pacman
    ln -snvf "$repo_path" /var/local/pacman/custom

    # shellcheck disable=SC1004
    awk -i inplace '/\[core\]/ {\
print "[custom]\n\
SigLevel = Optional TrustAll\n\
Server = file:///var/local/pacman/custom\n\
"}1' /etc/pacman.conf

    pacman -Sy
  fi
}

install_base() {
  local extra_pkgs=(
    zfs-linux
    intel-ucode grub efibootmgr os-prober
    openssh sudo pacman-contrib
    terminus-font
  )

  info "Bootstrapping base installation with pacstrap"
  pacstrap /mnt base

  if [ -d "$(dirname "$0")/custom" ]; then
    info "Adding the custom repository to pacman.conf"
    mkdir -pv /mnt/var/local/pacman
    cp -rv "$(dirname "$0")/custom" /mnt/var/local/pacman/

    # shellcheck disable=SC1004
    awk -i inplace '/\[core\]/ {\
print "[custom]\n\
SigLevel = Optional TrustAll\n\
Server = file:///var/local/pacman/custom\n\
"}1' /mnt/etc/pacman.conf

  fi

  info "Adding the archzfs repository to pacman.conf"
  # shellcheck disable=SC1004
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

setup_zpool_cache() {
  info "Clearing zpool cachefile property for $pool"
  in_chroot "zpool set cachefile=none $pool"

  info "Copying zpool.cache"
  mkdir -pv /mnt/etc/zfs
  cp -v /etc/zfs/zpool.cache /mnt/etc/zfs/

  info "Setting zpool cachefile property for $pool"
  in_chroot "zpool set cachefile=/etc/zfs/zpool.cache $pool"
}

set_root_passwd() {
  info "Set initial root password"
  in_chroot "chpasswd <<< 'root:$ROOT_PASSWD'"
}

enable_services() {
  local service
  local services=(
    zfs.target
    zfs-import-cache
    zfs-mount
    zfs-import.target
    "dhcpd@${NETIF}.service"
    sshd.socket
  )

  for service in "${services[@]}"; do
    info "Enabling '$service' service"
    in_chroot "systemctl enable $service"
  done
}

install_grub() {
  if [[ -n "${ENCRYPT:-}" ]]; then
    local grub_val
    grub_val="cryptdevice=${partid}:cryptroot"

    info "Adding disk encryption support for GRUB"
    sed -i \
      -e 's,^#\(GRUB_ENABLE_CRYPTODISK=y\)$,\1,' \
      -e "s,^\\(GRUB_CMDLINE_LINUX\\)=\"\\(.*\\)\"$,\\1=\"\\2 $grub_val\"," \
      /mnt/etc/default/grub
  fi

  if is_in_dell_xps_13; then
    info "Adding deep sleep support for Dell XPS"
    sed -i \
      -e 's,^\(GRUB_CMDLINE_LINUX_DEFAULT\)="\(.*\)"$,\1="\2 mem_sleep_default=deep",' \
      /mnt/etc/default/grub
  fi

  info "Installing GRUB"
  in_chroot \
    "ZPOOL_VDEV_NAME_PATH=1 grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB"

  info "Regenerate grub.cfg"
  in_chroot \
    "ZPOOL_VDEV_NAME_PATH=1 grub-mkconfig -o /boot/grub/grub.cfg"

  info "Creating vconsole.conf for larger console font"
  echo "FONT=ter-132n" >/mnt/etc/vconsole.conf

  info "Modifying HOOKS in mkinitcpio.conf"
  sed -i 's|^HOOKS=.*|HOOKS="base udev autodetect modconf block consolefont keyboard encrypt zfs filesystems shutdown"|g' /mnt/etc/mkinitcpio.conf

  info "Update initial ramdisk (initrd) with ZFS support"
  in_chroot "mkinitcpio -p linux"
}

install_hardware_specific_pkgs() {
  if is_in_vmware; then
    info "Installing VMware-specific software"
    in_chroot "pacman -S --noconfirm open-vm-tools"
  fi

  if is_in_dell_xps_13; then
    # Thanks to: http://www.saminiir.com/configuring-arch-linux-on-dell-xps-15/
    info "Enabling 'laptop-mode' in Kernel for Dell XPS 13"
    mkdir -p /mnt/etc/sysctl.d
    echo "vm.laptop_mode = 5" >/mnt/etc/sysctl.d/laptop.conf
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
    cat <<'EOF' >/mnt/etc/systemd/system/hwclock-resume.service
[Unit]
Description=Update hardware clock after resuming from sleep
After=suspend.target

[Service]
Type=oneshot
ExecStart=/usr/bin/hwclock --hctosys --utc

[Install]
WantedBy=suspend.target
EOF

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
  done
  unset l
  info "Generating locales for ${locales[*]}"
  in_chroot "locale-gen"
  info "Setting default locale to $default_locale"
  echo "LANG=$default_locale" >/mnt/etc/locale.conf
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
  in_chroot "pacman -Syyu --noconfirm"
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
    i3
    xf86-input-evdev
    xorg-server
    xorg-xinit
  )

  info "Installing X, a window manager, and utilities"
  in_chroot "pacman -S --noconfirm ${x_pkgs[*]}"

  if is_in_vmware; then
    local f=/mnt/etc/X11/xinit/xinitrc.d/10-vmware.sh
    info "Adding vmware-user-suid-wrapper to xinitirc.d"
    echo "/usr/sbin/vmware-user-suid-wrapper" >"$f"
    chmod -v 755 "$f"
  fi

  # TODO fn: is the deafult xinitrc reasonable or shoud we append `exec i3`?
}

finalize_pool() {
  info "Unmounting /mnt/boot/efi"
  umount /mnt/boot/efi
  info "Unmounting ZFS datasets"
  zfs umount -a
  info "Exporting ZFS zpool $pool"
  zpool export "$pool"

  if [[ -n "${ENCRYPT:-}" ]]; then
    info "Closing cryptoroot"
    cryptsetup close cryptroot
  fi
}

finish() {
  info "Arch Linux with ZFS installer complete, enjoy."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit 99
fi

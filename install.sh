#!/usr/bin/env bash

main() {
  set -eu
  if [[ -n "${DEBUG:-}" ]]; then set -x; fi

  version='0.1.0'
  author='Fletcher Nichol <fnichol@nichol.ca>'
  PROGRAM="$(basename "$0")"

  # shellcheck source=_common.sh
  . "${0%/*}/_common.sh"

  local arch
  arch="$(uname -m)"

  # The name of the root zpool
  POOL=tank
  # The name of the override repo
  OVERRIDE_REPO=override
  # The parent path of all local repos
  REPO_PATH_PREFIX=/var/local/pacman
  # The parent path of the override repo
  REPO_PATH="$REPO_PATH_PREFIX/$OVERRIDE_REPO/$arch"

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
  add_bootstrap_repo_keys
  add_bootstrap_override_repo
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
  echo "$PROGRAM $version

$author

Arch Linux with ZFS installer.

USAGE:
        $PROGRAM [FLAGS] [OPTIONS] <DISK> <NETIF>

FLAGS:
    -e  Encrypt the partition for the zpool (default: no)
    -h  Prints this message
    -V  Prints version information
    -x  Installs GUI/X (default: no)
    -X  Skips installation and setup of GUI/X (default: yes)
    -w  Installs GUI/Wayland (default: no)
    -W  Skips installation and setup of GUI/Wayland (default: yes)

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

  OPTIND=1
  # Parse command line flags and options
  while getopts ":a:ep:P:t:xXVwWh" opt; do
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
      x)
        INSTALL_X=true
        ;;
      X)
        unset INSTALL_X
        ;;
      V)
        echo "$PROGRAM $version"
        exit 0
        ;;
      w)
        # TODO: remove this
        # shellcheck disable=SC2034
        INSTALL_WAYLAND=true
        ;;
      W)
        unset INSTALL_WAYLAND
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

  while [[ $retries -lt 5 ]]; do
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

  info "Creating the root zpool '$POOL' on $zpool_dev"
  zpool create -m none -f "$POOL" "$zpool_dev"

  info "Setting default ZFS tunings for $POOL"
  # See: https://wiki.archlinux.org/index.php/ZFS#General_2
  zfs set compression=on "$POOL"
  zfs set atime=on "$POOL"
  zfs set relatime=on "$POOL"
}

create_datasets() {
  info "Creating ZFS datasets to support ZFS boot environments"
  # See: https://wiki.archlinux.org/index.php/Installing_Arch_Linux_on_ZFS#Create_your_datasets
  zfs create -o mountpoint=none "$POOL/ROOT"
  zfs create -o mountpoint=/ -o compression=lz4 "$POOL/ROOT/default" || true

  info "Creating ZFS dataset for /home"
  zfs create -o mountpoint=/home -o compression=lz4 "$POOL/home"

  info "Creating ZFS dataset for /root"
  zfs create -o mountpoint=/root -o compression=lz4 "$POOL/home/root"
}

prepare_pool() {
  info "Unmounting all ZFS datasets"
  zfs umount -a

  info "Setting mountpoints for ZFS datasets"
  zfs set mountpoint=/ "$POOL/ROOT/default"
  zfs set mountpoint=/home "$POOL/home"
  zfs set mountpoint=/root "$POOL/home/root"

  info "Writing out initial /etc/fstab"
  cat <<-EOF >/etc/fstab
	$POOL/ROOT/default	/	zfs	defaults,noatime	0 0
	EOF

  info "Setting bootfs property on $POOL/ROOT/default"
  # Set the bootfs property on the descendant root filesystem so the boot
  # loader knows where to find the operating system.
  zpool set bootfs="$POOL/ROOT/default" "$POOL"

  info "Exporting the pool $POOL"
  zpool export "$POOL"
}

mount_pool_for_install() {
  info "Re-importing the pool $POOL"
  zpool import -d /dev/disk/by-id -R /mnt "$POOL"

  info "Mounting the EFI System Partition (ESP) device $esp_dev"
  mkdir -pv /mnt/boot/efi
  mount "$esp_dev" /mnt/boot/efi
}

gen_fstab() {
  info "Using genfstab to generate system /etc/fstab"
  mkdir -pv /mnt/etc
  genfstab -U -p /mnt | grep -E ROOT/default >/mnt/etc/fstab
}

add_bootstrap_repo_keys() {
  info "Adding [archzfs] repository key to archiso"
  pacman-key -r F75D9D76
  pacman-key --lsign-key F75D9D76
}

add_bootstrap_override_repo() {
  if has_local_override_repo; then
    local local_repo_path
    local_repo_path="$(readlink -f "$(dirname "$0")/$OVERRIDE_REPO")"

    info "Detected [$OVERRIDE_REPO] repository to use for bootstrapping"

    mkdir -pv "$REPO_PATH"
    cp -rv "$local_repo_path"/*.pkg.tar.xz* "$REPO_PATH"

    find "$REPO_PATH" -name '*.pkg.tar.xz' -print0 \
      | xargs -0 repo-add "$REPO_PATH/$OVERRIDE_REPO.db.tar.xz"

    info "Adding [$OVERRIDE_REPO] repository to /etc/pacman.conf"
    insert_into_pacman_conf "$(override_repo_block)" /etc/pacman.conf

    pacman -Sy --noconfirm
  fi
}

install_base() {
  local extra_pkgs=(
    zfs-linux
    intel-ucode grub efibootmgr os-prober
    dhcpcd openssh sudo pacman-contrib
    terminus-font
  )

  info "Bootstrapping base installation with pacstrap"
  pacstrap /mnt base

  add_override_repo
  add_archzfs_repo

  info "Installing extra base packages"
  in_chroot "pacman -Sy --noconfirm; pacman -S --noconfirm ${extra_pkgs[*]}"

  # The exit code of the previous failed pacman install with be `0` regardless
  # of whether the installation was successful. Any version mismatching of
  # ZFS-related packages and the current Linux kernel will result in a detected
  # "unable to satisfy dependency" which is considered a successful termination
  # of the program. Instead of relying on the exit code of the previous
  # command, we'll check if one of the packages has been installed and assume
  # that if it is not, then the entire set has failed and terminate the
  # program.
  if ! in_chroot "pacman -Qi zfs-linux" >/dev/null 2>&1; then
    exit_with \
      "Installation of zfs-linux failed, check kernel version support" 21
  fi

  info "Setting sudoers policy"
  in_chroot "echo '%wheel ALL=(ALL) ALL' > /etc/sudoers.d/01_wheel"

  info "Remove default .bashrc in /etc/skell"
  in_chroot "rm -f /etc/skel/.bashrc"
}

add_override_repo() {
  local mounted_repo_path
  mounted_repo_path="/mnt$REPO_PATH"

  info "Creating [$OVERRIDE_REPO] repository root $mounted_repo_path"
  mkdir -pv "$mounted_repo_path"

  if has_local_override_repo; then
    info "Copying local [$OVERRIDE_REPO] repository packages to system"
    cp -rv "$(dirname "$0")/$OVERRIDE_REPO"/*.pkg.tar.xz* "$mounted_repo_path"
  fi

  info "Preparing [$OVERRIDE_REPO] repository locally"
  in_chroot "find $REPO_PATH -name '*.pkg.tar.xz' -print0 \
      | xargs -0 repo-add $REPO_PATH/$OVERRIDE_REPO.db.tar.xz"

  info "Adding [$OVERRIDE_REPO] repository to /mnt/etc/pacman.conf"
  insert_into_pacman_conf "$(override_repo_block)" /mnt/etc/pacman.conf
}

add_archzfs_repo() {
  info "Adding [archzfs] repository to /mnt/etc/pacman.conf"
  insert_into_pacman_conf "$(archzfs_repo_block)" /mnt/etc/pacman.conf

  info "Adding [archzfs] repository key"
  in_chroot "pacman-key -r F75D9D76 && pacman-key --lsign-key F75D9D76"
}

setup_zpool_cache() {
  info "Clearing zpool cachefile property for $POOL"
  in_chroot "zpool set cachefile=none $POOL"

  info "Copying zpool.cache"
  mkdir -pv /mnt/etc/zfs
  cp -v /etc/zfs/zpool.cache /mnt/etc/zfs/

  info "Setting zpool cachefile property for $POOL"
  in_chroot "zpool set cachefile=/etc/zfs/zpool.cache $POOL"
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
    "dhcpcd@${NETIF}.service"
    sshd.service
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
    cat <<-'EOF' >/mnt/etc/systemd/system/hwclock-resume.service
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
  info "Exporting ZFS zpool $POOL"
  zpool export "$POOL"

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

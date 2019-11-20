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

  # The name of the override repo
  OVERRIDE_REPO=override
  # The parent path of all local repos
  REPO_PATH_PREFIX=/var/local/pacman
  # The parent path of the override repo
  REPO_PATH="$REPO_PATH_PREFIX/$OVERRIDE_REPO/$arch"

  # Parse CLI arguments and set local variables
  parse_cli_args "$@"
  local boot_pool="$BOOT_POOL"
  local root_pool="$ROOT_POOL"
  local part_type="$PART_TYPE"
  local exist_boot_part="${BOOT_PARTITION:-}"
  local exist_root_part="${ROOT_PARTITION:-}"
  local encrypt="${ENCRYPT:-}"
  local root_pool_passwd="${ROOT_POOL_PASSWD:-}"
  unset BOOT_POOL ROOT_POOL PART_TYPE BOOT_PARTITION ROOT_PARTITION \
    ENCRYPT ROOT_POOL_PASSWD

  find_dev "$DISK"
  local disk_dev="$FIND_DEV"
  unset FIND_DEV

  # Partition disk and determine partition devices
  partition_disk "$part_type" "$disk_dev" "$exist_boot_part" "$exist_root_part"
  local esp_dev="$ESP_DEV"
  local boot_pool_dev="$BOOT_POOL_DEV"
  local root_pool_dev="$ROOT_POOL_DEV"
  unset ESP_DEV BOOT_POOL_DEV ROOT_POOL_DEV

  # Format partitions, create ZFS zpools, and prepare the pools
  load_zfs
  format_esp "$part_type" "$esp_dev"
  create_boot_zpool "$boot_pool" "$boot_pool_dev"
  create_root_zpool "$root_pool" "$root_pool_dev" "$encrypt" "$root_pool_passwd"
  create_root_datasets "$root_pool"
  create_boot_datasets "$boot_pool"
  prepare_pools "$boot_pool" "$root_pool"
  mount_pools_for_install \
    "$esp_dev" "$boot_pool" "$root_pool" "$encrypt" "$root_pool_passwd"

  # Install base system
  gen_fstab "$root_pool"
  add_bootstrap_repo_keys
  add_bootstrap_override_repo
  install_base
  install_hardware_specific_pkgs
  setup_zpool_cache "$root_pool"
  setup_boot_pool_mounting "$boot_pool"
  set_root_passwd
  enable_services "$boot_pool"
  install_grub "$root_pool"

  # Initially configure base system
  set_timezone
  setup_clock
  generate_locales
  find_fastest_mirrors

  # Prepare user creation script for `root`
  copy_create_user_script

  # Finalize pools and end installer
  finalize_pools "$boot_pool" "$root_pool"
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

OPTIONS:
    -b <PARTITION>            Choose a boot partition for type partition
                              (ex: nvme0n1p3)
    -E <ROOT_POOL_PASSWD_FILE> Read the root pool password from file
                              (default: prompt)
    -p <PARTITION_TYPE>       Choose a partitioning type (default: whole)
                              (values: existing, remaining, whole)
    -P <ROOT_PASSWD_FILE>     Read initial root password from file
                              (default: prompt)
    -r <PARTITION>            Choose a root partition for type partition
                              (ex: nvme0n1p4)
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
  # The name of the boot zpool
  BOOT_POOL="bpool"
  # The name of the root zpool
  ROOT_POOL="rpool"
  # Default partition type to whole
  PART_TYPE=whole
  # Default timezone to UTC
  TZ=UTC

  OPTIND=1
  # Parse command line flags and options
  while getopts ":b:eE:p:P:r:t:Vh" opt; do
    case $opt in
      b)
        BOOT_PARTITION="$OPTARG"
        ;;
      e)
        ENCRYPT=true
        ;;
      E)
        if [ ! -f "$OPTARG" ]; then
          print_help
          exit_with "Pool encrypt password file does not exist: $OPTARG" 3
        fi
        ROOT_POOL_PASSWD="$(cat "$OPTARG")"
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
      r)
        ROOT_PARTITION="$OPTARG"
        ;;
      t)
        TZ="$OPTARG"
        ;;
      V)
        echo "$PROGRAM $version"
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

  if [[ "$PART_TYPE" == "existing" && -z "${BOOT_PARTITION:-}" ]]; then
    print_help
    exit_with "Boot partition (-b) required when partition type is 'existing'" 2
  fi
  if [[ "$PART_TYPE" == "existing" && -z "${ROOT_PARTITION:-}" ]]; then
    print_help
    exit_with "Root partition (-r) required when partition type is 'existing'" 2
  fi

  if [[ -n "${ENCRYPT:-}" ]]; then
    if [[ -z "${ROOT_POOL_PASSWD:-}" ]]; then
      read_passwd "$ROOT_POOL encryption"
      ROOT_POOL_PASSWD="$PASSWD"
      unset PASSWD
    fi
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

load_zfs() {
  info "Loading the ZFS kernel module"
  modprobe zfs
}

partition_disk() {
  local part_type="$1"
  shift
  local disk_dev="$1"
  shift

  case "$part_type" in
    existing)
      local boot_pool_dev="$1"
      local root_pool_dev="$2"

      partition_existing_disk "$disk_dev" "$boot_pool_dev" "$root_pool_dev"
      ;;
    remaining)
      partition_remaining_disk "$disk_dev"
      ;;
    whole)
      partition_whole_disk "$disk_dev"
      ;;
    *)
      print_help
      exit_with "Invalid partition type: $part_type" 2
      ;;
  esac
}

# Partitions an existing disk and sets variables for partition devices.
#
# # Side Effects
#
# This function sets the following global variables:
#
# * `ESP_DEV`: ESP partition device
# * `BOOT_POOL_DEV`: boot pool partition device
# * `ROOT_POOL_DEV`: root pool partition device
partition_existing_disk() {
  local disk_dev="$1"
  local boot_pool_dev_name="$2"
  local root_pool_dev_name="$3"

  find_esp_dev "$disk_dev"
  ESP_DEV="$FIND_ESP_DEV"
  unset FIND_ESP_DEV

  find_dev "$boot_pool_dev_name"
  BOOT_POOL_DEV="$FIND_DEV"
  unset FIND_DEV
  info "Using existing boot pool partition '$BOOT_POOL_DEV'"

  find_dev "$root_pool_dev_name"
  ROOT_POOL_DEV="$FIND_DEV"
  unset FIND_DEV
  info "Using existing root pool partition '$ROOT_POOL_DEV'"
}

# Partitions remaining space on an existing disk and sets variables for
# partition devices.
#
# # Side Effects
#
# This function sets the following global variables:
#
# * `ESP_DEV`: ESP partition device
# * `BOOT_POOL_DEV`: boot pool partition device
# * `ROOT_POOL_DEV`: root pool partition device
partition_remaining_disk() {
  local disk_dev="$1"

  info "Partitioning remaining space on disk '$disk_dev'"

  find_esp_dev "$disk_dev"
  ESP_DEV="$FIND_ESP_DEV"
  unset FIND_ESP_DEV

  local part boot_pool_part root_pool_part
  part="$(sgdisk --print "$disk_dev" | tail -n 1 | awk '{ print $1 }')"
  boot_pool_part=$((part + 1))
  root_pool_part=$((part + 1))

  partition_boot_pool "$disk_dev" "$boot_pool_part"
  partition_root_pool "$disk_dev" "$root_pool_part"
}

# Partitions entire disk and sets variables for partition devices.
#
# # Side Effects
#
# This function sets the following global variables:
#
# * `ESP_DEV`: ESP partition device
# * `BOOT_POOL_DEV`: boot pool partition device
# * `ROOT_POOL_DEV`: root pool partition device
partition_whole_disk() {
  local disk_dev="$1"
  local esp_part=1
  local boot_pool_part=2
  local root_pool_part=3

  info "Partitioning whole disk '$disk_dev'"

  info "Clearing partition table on '$disk_dev'"
  sgdisk --zap-all "$disk_dev"

  partition_esp "$disk_dev" "$esp_part"
  partition_boot_pool "$disk_dev" "$boot_pool_part"
  partition_root_pool "$disk_dev" "$root_pool_part"
}

# Creates a partition for the ESP on a given disk and sets a global
# variable.
#
# # Side Effects
#
# This function sets the following global variables:
#
# * `ESP_DEV`: boot pool partition device
partition_esp() {
  local disk_dev="$1"
  local part="$2"

  ESP_DEV="${disk_dev}-part${part}"
  info "Creating ESP partition for UEFI booting '$ESP_DEV'"
  sgdisk \
    --new="$part:1M:+512M" \
    --typecode="$part:EF00" \
    "$disk_dev"
  wait_on_part_dev "$ESP_DEV"
}

# Creates a partition for the boot pool on a given disk and sets a global
# variable.
#
# # Side Effects
#
# This function sets the following global variables:
#
# * `BOOT_POOL_DEV`: boot pool partition device
partition_boot_pool() {
  local disk_dev="$1"
  local part="$2"

  BOOT_POOL_DEV="${disk_dev}-part${part}"
  info "Creating boot pool partition '$BOOT_POOL_DEV'"
  sgdisk \
    --new="$part:0:+1G" \
    --typecode="$part:BF01" \
    "$disk_dev"
  wait_on_part_dev "$BOOT_POOL_DEV"
}

# Creates a partition for the root pool on a given disk and sets a global
# variable.
#
# # Side Effects
#
# This function sets the following global variables:
#
# * `ROOT_POOL_DEV`: root pool partition device
partition_root_pool() {
  local disk_dev="$1"
  local part="$2"

  ROOT_POOL_DEV="${disk_dev}-part${part}"
  info "Creating root pool partition '$ROOT_POOL_DEV'"
  sgdisk \
    --new="$part:0:0" \
    --typecode="$part:BF01" \
    "$disk_dev"
  wait_on_part_dev "$ROOT_POOL_DEV"
}

# Finds the given device name under the `/dev/disk/by-id` tree and sets a
# global variable.
#
# # Side Effects
#
# This function sets the following global variable:
#
# * `FIND_DEV`: found device
find_dev() {
  local device_name="$1"
  local retries=0

  udevadm trigger
  udevadm settle

  while [[ $retries -lt 5 ]]; do
    while read -r device_id; do
      if [[ "$(readlink -f "$device_id")" == "/dev/$device_name" ]]; then
        FIND_DEV="$device_id"
        info "Found partition ID for /dev/$device_name: $FIND_DEV"
        return
      fi
    done < <(find /dev/disk/by-id -not -type d | sort --ignore-case)

    retries=$((retries + 1))
    info "Partition ID not found, sleeping and retrying ($retries/5)"
    sleep 3
  done

  exit_with "Could not find partition ID for /dev/$device_name" 10
}

# Finds the EFI System Partition (EFI) on a given disk device.
#
# # Side Effects
#
# This function sets the following global variable:
#
# * `FIND_ESP_DEV`: found ESP partition device
find_esp_dev() {
  local disk_dev="$1"
  local esp_part

  esp_part="$(sgdisk --print "$disk_dev" | awk '$6 == "EF00" { print $1 }')"
  if [[ -z "$esp_dev" ]]; then
    exit_with "Cannot find EFI System Partition (ESP) on '$disk_dev'" 5
  fi

  FIND_ESP_DEV="${disk_dev}-part${esp_part}"
  info "Found EFI System Partition (ESP) '$FIND_ESP_DEV'"
  wait_on_part_dev "$FIND_ESP_DEV"
}

wait_on_part_dev() {
  local part_dev="$1"
  local retries=0

  udevadm settle

  while [[ $retries -lt 5 ]]; do
    if [[ -e "$part_dev" ]]; then
      return
    fi

    retries=$((retries + 1))
    sleep 3
  done

  exit_with "Could not find partition device '$part_dev'" 10
}

format_esp() {
  local part_type="$1"
  local esp_dev="$2"

  if [[ "$part_type" == "whole" ]]; then
    info "Formatting EFI System Partition (ESP) filesystem on '$esp_dev'"
    mkfs.fat -F32 "$esp_dev"
  fi
}

create_boot_zpool() {
  local boot_pool="$1"
  local boot_pool_dev="$2"

  info "Creating the boot zpool '$boot_pool' on '$boot_pool_dev'"
  # GRUB does not support all of the zpool features. See spa_feature_names in
  # grub-core/fs/zfs/zfs.c. This step creates a separate boot pool for /boot
  # with the features limited to only those that GRUB supports, allowing the
  # root pool to use any/all features. Note that GRUB opens the pool read-only,
  # so all read-only compatible features are "supported" by GRUB.
  #
  # References:
  # * http://git.savannah.gnu.org/cgit/grub.git/tree/grub-core/fs/zfs/zfs.c#n276
  # * https://github.com/zfsonlinux/zfs/wiki/Debian-Buster-Root-on-ZFS
  # * https://wiki.archlinux.org/index.php/ZFS#GRUB-compatible_pool_creation
  zpool create \
    -m none \
    -R /mnt \
    -o ashift=12 \
    -d \
    -o feature@allocation_classes=enabled \
    -o feature@async_destroy=enabled \
    -o feature@bookmarks=enabled \
    -o feature@embedded_data=enabled \
    -o feature@empty_bpobj=enabled \
    -o feature@enabled_txg=enabled \
    -o feature@extensible_dataset=enabled \
    -o feature@filesystem_limits=enabled \
    -o feature@hole_birth=enabled \
    -o feature@large_blocks=enabled \
    -o feature@lz4_compress=enabled \
    -o feature@project_quota=enabled \
    -o feature@resilver_defer=enabled \
    -o feature@spacemap_histogram=enabled \
    -o feature@spacemap_v2=enabled \
    -o feature@userobj_accounting=enabled \
    -o feature@zpool_checkpoint=enabled \
    -O acltype=posixacl \
    -O canmount=off \
    -O compression=lz4 \
    -O devices=off \
    -O mountpoint=none \
    -O normalization=formD \
    -O relatime=on \
    -O xattr=sa \
    "$boot_pool" \
    "$boot_pool_dev"
}

create_root_zpool() {
  local root_pool="$1"
  local root_pool_dev="$2"
  local encrypted="$3"

  if [[ -n "$encrypted" ]]; then
    local root_pool_passwd="$4"

    info "Creating the encrypted root zpool '$root_pool' on '$root_pool_dev'"
    zpool create \
      -m none \
      -R /mnt \
      -o ashift=12 \
      -O acltype=posixacl \
      -O canmount=off \
      -O compression=lz4 \
      -O dnodesize=auto \
      -O encryption=aes-256-gcm \
      -O keyformat=passphrase \
      -O keylocation=prompt \
      -O mountpoint=/ \
      -O normalization=formD \
      -O relatime=on \
      -O xattr=sa \
      "$root_pool" \
      "$root_pool_dev" \
      <<<"$root_pool_passwd"
  else
    info "Creating the root zpool '$root_pool' on '$root_pool_dev'"
    zpool create \
      -m none \
      -R /mnt \
      -o ashift=12 \
      -O acltype=posixacl \
      -O canmount=off \
      -O compression=lz4 \
      -O dnodesize=auto \
      -O mountpoint=/ \
      -O normalization=formD \
      -O relatime=on \
      -O xattr=sa \
      "$root_pool" \
      "$root_pool_dev"
  fi
}

create_root_datasets() {
  local pool="$1"

  zfs create -o canmount=off -o mountpoint=none "$pool/ROOT"
  zfs create -o canmount=noauto -o mountpoint=/ "$pool/ROOT/default"
  zfs mount "$pool/ROOT/default"

  zfs create "$pool/home"
  zfs create -o mountpoint=/root "$pool/home/root"

  zfs create "$pool/opt"

  zfs create -o canmount=off "$pool/usr"
  zfs create "$pool/usr/local"

  zfs create -o canmount=off "$pool/var"
  zfs create -o com.sun:auto-snapshot=false "$pool/var/cache"
  zfs create "$pool/var/cache/pacman"
  zfs create -o canmount=off "$pool/var/lib"
  zfs create -o com.sun:auto-snapshot=false "$pool/var/lib/docker"
  zfs create -o canmount=off "$pool/var/lib/systemd"
  zfs create "$pool/var/lib/systemd/coredump"
  zfs create "$pool/var/log"
  zfs create "$pool/var/log/journal"
  zfs create "$pool/var/spool"
  zfs create -o com.sun:auto-snapshot=false "$pool/var/tmp"

  chmod 1777 /mnt/var/tmp
}

create_boot_datasets() {
  local pool="$1"

  zfs create -o canmount=off -o mountpoint=none "$pool/BOOT"
  zfs create -o canmount=noauto -o mountpoint=/boot "$pool/BOOT/default"
  zfs mount "$pool/BOOT/default"
}

prepare_pools() {
  local boot_pool="$1"
  local root_pool="$2"

  info "Unmounting all ZFS datasets"
  zfs unmount -a
  zfs unmount "$boot_pool/BOOT/default"
  zfs unmount "$root_pool/ROOT/default"

  info "Writing out initial /etc/fstab"
  cat <<-EOF >/etc/fstab
	$root_pool/ROOT/default	/	zfs	defaults,noatime	0 0
	EOF

  info "Setting bootfs property on $boot_pool/ROOT/default"
  # Set the bootfs property on the descendant boot filesystem so the boot
  # loader knows where to find the operating system.
  zpool set bootfs="$boot_pool/BOOT/default" "$boot_pool"

  info "Exporting the pools"
  zpool export "$boot_pool"
  zpool export "$root_pool"
}

mount_pools_for_install() {
  local esp_dev="$1"
  local boot_pool="$2"
  local root_pool="$3"
  local encrypted="$4"

  info "Re-importing the pools"
  zpool import -N -d /dev/disk/by-id -R /mnt "$root_pool"
  zpool import -N -d /dev/disk/by-id -R /mnt "$boot_pool"

  if [[ -n "$encrypted" ]]; then
    local root_pool_passwd="$5"

    info "Decrypting root pool '$root_pool'"
    zfs load-key "$root_pool" <<<"$root_pool_passwd"
  fi

  info "Re-mounting datasets"
  zfs mount "$root_pool/ROOT/default"
  zfs mount "$boot_pool/BOOT/default"
  zfs mount -a

  info "Mounting the EFI System Partition (ESP) device $esp_dev"
  mkdir -pv /mnt/boot/efi
  mount "$esp_dev" /mnt/boot/efi
}

gen_fstab() {
  local root_pool="$1"

  info "Using genfstab to generate system /etc/fstab"
  mkdir -pv /mnt/etc
  genfstab -U -p /mnt | grep -E "^$root_pool/ROOT/default" >/mnt/etc/fstab
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

install_hardware_specific_pkgs() {
  if is_in_vmware; then
    info "Installing VMware-specific software"
    in_chroot "pacman -S --noconfirm open-vm-tools"
  fi
}

setup_zpool_cache() {
  local root_pool="$1"

  info "Clearing zpool cachefile property for root pool '$root_pool'"
  in_chroot "zpool set cachefile=none '$root_pool'"

  mkdir -pv /mnt/etc/zfs
  if [[ -e /etc/zfs/zpool.cache ]]; then
    info "Copying zpool.cache"
    cp -v /etc/zfs/zpool.cache /mnt/etc/zfs/
  fi

  info "Setting zpool cachefile property for root pool '$root_pool'"
  in_chroot "zpool set cachefile=/etc/zfs/zpool.cache '$root_pool'"
}

setup_boot_pool_mounting() {
  local boot_pool="$1"

  info "Creating zfs-import-$boot_pool service unit to import boot pool"
  cat <<-EOF >"/mnt/etc/systemd/system/zfs-import-${boot_pool}.service"
	[Unit]
	Description=Import boot pool $boot_pool
	DefaultDependencies=no
	Requires=zfs-mount.service

	[Service]
	Type=oneshot
	ExecStart=/sbin/zpool import -N -o cachefile=none $boot_pool

	[Install]
	WantedBy=zfs-import.target
	EOF

  info "Adding fstab entry for /boot filesystem"
  cat <<-EOF >>/mnt/etc/fstab
	$boot_pool/BOOT/default	/boot	zfs	nodev,relatime,xattr,posixacl,x-systemd.requires=zfs-mount.service	0 0
	EOF
}

nope() {
  return
}

set_root_passwd() {
  info "Set initial root password"
  in_chroot "chpasswd <<< 'root:$ROOT_PASSWD'"
}

enable_services() {
  local boot_pool="$1"
  local services=(
    zfs.target
    zfs-import-cache
    zfs-mount
    zfs-import.target
    "zfs-import-$boot_pool"
    "dhcpcd@${NETIF}.service"
    sshd.service
  )
  local service

  if is_in_vmware; then
    services+=(vmtoolsd.service)
  fi

  for service in "${services[@]}"; do
    info "Enabling '$service' service"
    in_chroot "systemctl enable $service"
  done
}

install_grub() {
  local root_pool="$1"

  local root="root=ZFS=$root_pool/ROOT/default"
  sed -i \
    -e "s,^\\(GRUB_CMDLINE_LINUX\\)=\"\\(.*\\)\"$,\\1=\"\\2 $root\"," \
    /mnt/etc/default/grub

  info "Installing GRUB"
  in_chroot \
    "ZPOOL_VDEV_NAME_PATH=1 grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB"

  info "Regenerate grub.cfg"
  in_chroot \
    "ZPOOL_VDEV_NAME_PATH=1 grub-mkconfig -o /boot/grub/grub.cfg"

  if is_in_dell_xps_13; then
    info "Creating vconsole.conf for larger console font"
    echo "FONT=ter-132n" >/mnt/etc/vconsole.conf
  fi

  info "Modifying HOOKS in mkinitcpio.conf"
  sed -i 's|^HOOKS=.*|HOOKS="base udev keyboard autodetect modconf block consolefont zfs filesystems shutdown"|g' /mnt/etc/mkinitcpio.conf

  info "Update initial ramdisk (initrd) with ZFS support"
  in_chroot "mkinitcpio -p linux"
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

finalize_pools() {
  local boot_pool="$1"
  local root_pool="$2"

  info "Unmounting /mnt/boot/efi"
  umount /mnt/boot/efi

  info "Unmounting ZFS datasets"
  zfs unmount -a
  zfs unmount "$boot_pool/BOOT/default"
  zfs unmount "$root_pool/ROOT/default"

  info "Setting mounting to legacy for $boot_pool/BOOT/default"
  zfs set mountpoint=legacy "$boot_pool/BOOT/default"

  info "Exporting ZFS zpools"
  zpool export "$boot_pool"
  zpool export "$root_pool"
}

finish() {
  info "Arch Linux with ZFS installer complete, enjoy."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@" || exit 99
fi

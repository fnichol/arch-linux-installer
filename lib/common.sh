#!/usr/bin/env bash

read_passwd() {
  local entity="$1"
  local retype

  while true; do
    echo -n "Enter password for $entity: "
    read -r -s PASSWD
    echo

    echo -n "Retype password: "
    read -r -s retype
    echo

    if [[ "$PASSWD" == "$retype" ]]; then
      unset retype
      break
    else
      echo ">>> Passwords do not match, please try again"
      echo
    fi
  done
}

has_local_override_repo() {
  local override_repo="$1"

  local path
  path="$(dirname "$0")/$override_repo"

  if [[ -d "$path" ]]; then
    if [[ "$(find "$path" | wc -l)" != 0 ]]; then
      return 0
    else
      return 1
    fi
  else
    return 1
  fi
}

override_repo_block() {
  local override_repo="$1"
  local repo_path_prefix="$2"

  local content

  # Read complex, interpolated string into a $content variable using leading
  # full tab indentation syntax
  read -r -d '' content <<-CONTENT
	# Local [$override_repo] repo for temporary pkg pinnings (i.e. kernel, etc.)
	#
	# For more information:
	# * https://wiki.archlinux.org/index.php/Pacman/Tips_and_tricks#Custom_local_repository
	# * https://wiki.archlinux.org/index.php/downgrading_packages
	#
	[$override_repo]
	SigLevel = Optional TrustAll
	Server = file://$repo_path_prefix/\$repo/\$arch
	CONTENT

  echo "$content"
}

archzfs_repo_block() {
  local content

  # Read complex, interpolated string into a $content variable using leading
  # full tab indentation syntax
  read -r -d '' content <<-CONTENT
	# ZFS on Arch Linux support repo
	#
	# For more information:
	# * https://github.com/archzfs/archzfs/wiki
	#
	[archzfs]
	Include = /etc/pacman.d/mirrorlist-archzfs
	CONTENT

  echo "$content"
}

insert_into_pacman_conf() {
  local content="$1"
  local pacman_conf="$2"

  awk -i inplace -v content="$content" \
    '/\[core\]/ { print content "\n"}1' "$pacman_conf"
}

is_in_vmware() {
  if [[ "$(cat /sys/class/dmi/id/sys_vendor)" == "VMware, Inc." ]]; then
    return 0
  else
    return 1
  fi
}

is_in_dell_xps_13() {
  if [[ "$(cat /sys/class/dmi/id/product_name)" == "XPS 13 9370" ]]; then
    return 0
  else
    return 1
  fi
}

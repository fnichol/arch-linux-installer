#!/usr/bin/env bash

main() {
  set -eu
  if [[ -n "${DEBUG:-}" ]]; then set -x; fi

  # shellcheck source=_common.sh
  . "${0%/*}/../_common.sh"

  need_cmd basename
  need_cmd cat
  need_cmd cp
  need_cmd mkdir
  need_cmd mktemp
  need_cmd pacman
  need_cmd rm

  PROGRAM="$(basename "$0")"
  WORKDIR="$(mktemp -d -p /home -t "$(basename "$0")".XXXXXXXX)" || exit 12
  trap 'cleanup' INT TERM EXIT

  local arch
  arch="$(uname -m)"

  # The name of the override repo
  OVERRIDE_REPO=override
  # The parent path of all local repos
  REPO_PATH_PREFIX=/var/local/pacman
  # The parent path of the override repo
  REPO_PATH="$REPO_PATH_PREFIX/$OVERRIDE_REPO/$arch"

  prepare
  add_override_repo
  add_zfs_repo
  add_zfs_package
  add_openssh
  build_image

  info "All done, image is in $(dirname "$0")/out"
}

cleanup() {
  local e=$?
  info "Cleanup up $WORKDIR"
  rm -rf "$WORKDIR"
  if [[ -n "${WEB_PID:-}" ]]; then
    info "Stopping web server"
    kill "$WEB_PID"
  fi
  exit $e
}

prepare() {
  info "Preparing system and $WORKDIR"

  mkdir -pv "$WORKDIR"
  # Freshen package database and upgrade
  pacman -Syyu --noconfirm
  # Install the `archiso` package
  pacman -S --noconfirm archiso
  cp -rv /usr/share/archiso/configs/releng/* "$WORKDIR"
}

start_web_server() {
  local document_root="$1"
  local port="$2"

  pacman -S --noconfirm ruby
  need_cmd ruby

  # Start a webserver for override packages and background it. The cleanup
  # trap will kill the web server when this process terminates.
  ruby -rwebrick -e"
      WEBrick::HTTPServer.new(
        :Port => $port,
        :DocumentRoot => %{$document_root}
      ).start
    " &
  sleep 1
  WEB_PID=$!

  return 0
}

add_override_repo() {
  if has_local_override_repo; then
    local local_repo_path content
    local_repo_path="$(readlink -f "$(dirname "$0")/$OVERRIDE_REPO")"

    info "Detected [$OVERRIDE_REPO] repository to use for bootstrapping"

    mkdir -pv "$REPO_PATH"
    cp -rv "$local_repo_path"/*.pkg.tar.xz* "$REPO_PATH"

    find "$REPO_PATH" -name '*.pkg.tar.xz' -print0 \
      | xargs -0 repo-add "$REPO_PATH/$OVERRIDE_REPO.db.tar.xz"

    start_web_server "$REPO_PATH" "8000"

    # Read complex, interpolated string into a $content variable using leading
    # full tab indentation syntax
    read -r -d '' content <<-CONTENT
	#OVERRIDE_BEGIN
	[$OVERRIDE_REPO]
	SigLevel = Optional TrustAll
	Server = http://127.0.0.1:8000
	#OVERRIDE_END
	CONTENT
    insert_into_pacman_conf "$content" "$WORKDIR/pacman.conf"

    cat <<-'EOF' >>"$WORKDIR/airootfs/root/customize_airootfs.sh"

	# Remove the temporary [override] repo
	sed -i -e '/#OVERRIDE_BEGIN/,/#OVERRIDE_END/{N;d;}' /etc/pacman.conf
	EOF
  fi
}

add_zfs_repo() {
  info "Adding [archzfs] repository to $WORKDIR/pacman.conf"
  insert_into_pacman_conf "$(archzfs_repo_block)" "$WORKDIR/pacman.conf"

  info "Importing [archzfs] repository key"
  pacman-key -r F75D9D76
  pacman-key --lsign-key F75D9D76
}

add_zfs_package() {
  info "Adding the archzfs-linux package to the image"
  echo "archzfs-linux" >>"$WORKDIR/packages.x86_64"
}

add_openssh() {
  info "Adding the OpenSSH to the image"

  cat <<-'EOF' >>"$WORKDIR/airootfs/root/customize_airootfs.sh"

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

  cd "$WORKDIR"
  mkdir -pv out
  ./build.sh -v
  mkdir -v -p "$(dirname "$0")/out"
  cp -v out/*.iso "$(dirname "$0")/out/"
}

main "$@" || exit 99

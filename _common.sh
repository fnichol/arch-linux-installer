#!/usr/bin/env bash

info() {
  case "${TERM:-}" in
    *term | xterm-* | rxvt | screen | screen-*)
      printf -- "   \033[1;36;40m%s: \033[1;37;40m%s\033[0m\n" "${program}" "${1:-}"
      ;;
    *)
      printf -- "   %s: %s\n" "${program}" "${1:-}"
      ;;
  esac
  return 0
}

exit_with() {
  case "${TERM:-}" in
    *term | xterm-* | rxvt | screen | screen-*)
      printf -- "\\033[1;31mERROR: \\033[1;37m%s\\033[0m\\n" "${1:-}"
      ;;
    *)
      printf -- "ERROR: %s\\n" "${1:-}"
      ;;
  esac
  exit "${2:-99}"
}

read_passwd() {
  local user="$1"

  while true; do
    echo -n "Enter password for $user: "
    read -r -s PASSWD
    echo

    echo -n "Retype password: "
    read -r -s retype
    echo

    if [ "$PASSWD" = "$retype" ]; then
      unset retype
      break
    else
      echo ">>> Passwords do not match, please try again"
      echo
    fi
  done
}

is_in_vmware() {
  if [ "$(cat /sys/class/dmi/id/sys_vendor)" = "VMware, Inc." ]; then
    return 0
  else
    return 1
  fi
}

is_in_dell_xps_13() {
  if [ "$(cat /sys/class/dmi/id/product_name)" = "XPS 13 9370" ]; then
    return 0
  else
    return 1
  fi
}

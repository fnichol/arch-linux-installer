# Arch Linux Installer

|         |                                           |
| ------: | ----------------------------------------- |
|      CI | [![CI Status][badge-ci-overall]][ci]      |
| License | [![Crate license][badge-license]][github] |

**Table of Contents**

<!-- toc -->

## Usage

### `install`

You can use the `-h`/`--help` flag to get:

```console
$ ./bin/install --help
install 0.1.0

Arch Linux with ZFS installer.

USAGE:
    install [FLAGS] [OPTIONS] <DISK> <NETIF>

FLAGS:
    -e, --encrypt     Encrypts the partition for the zpool
                      (default: no)
    -h, --help        Prints help information
    -I, --hibernation Enables hibernation/resume (WARNING: experimental!)
                      (default: no)
    -S, --suffix      Appends a unique suffix to zpool names
    -V, --version     Prints version information
    -W, --no-swap     Do not include a swap partition
                      (default: create swap)

OPTIONS:
    -b, --boot-part=<PART>      Choose a boot partition for type partition
                                (ex: nvme0n1p3)
    -E, --encrypt-pass=<FILE>   Read the root pool password from file
                                (default: prompt)
    -l, --legacy-part=<PART>    Choose a legacy BIOS boot partition for
                                type partition (ex: nvme0n1p5)
    -p, --partition=<TYPE>      Choose a partitioning type (default: whole)
                                (values: existing, remaining, whole)
    -P, --root-pass=<FILE>      Read initial root password from file
                                (default: prompt)
    -r, --root-part=<PART>      Choose a root partition for type partition
                                (ex: nvme0n1p4)
    -s, --swap-part=<PART>      Choose a swap partition for type partition
                                (ex: nvme0n1p2)
    -t, --timezone=<TZ>         Timezone (ex: `America/Edmonton')
                                (default: `UTC')
        --bpool-size=<SIZE>     Size for boot pool partition, using sgdisk
                                sizes (default: 4G)
        --esp-size=<SIZE>       Size for ESP partition if using whole
                                partitioning type, using sgdisk sizes
                                (default: 4G)
        --rpool-size=<SIZE>     Size for root pool partition, using sgdisk
                                sizes (default: empty, uses all remaining)
        --swap-size=<SIZE>      Size for swap partition if enabled, using
                                sgdisk sizes (default: size of RAM)

ARGS:
    <DISK>      The disk to use for installation (ex: `nvme0n1')
                This can be found by using the `lsblk' program.
    <NETIF>     The network interface to setup for DHCP (ex: `ens33')
                This can be found by using the `ip addr' program.

EXAMPLES:
    Example 1 Installing with default behavior
      The following command installs Arch Linux using the whole disk,
      with a swap partition, without encryption, and a timezone of
      `UTC'.

      # install nvme0n1 ens33

    Example 2
      The following command installs Arch Linux using the whole disk,
      without a swap partition, with root pool encryption, and a
              timezone of Mountain time in North America.

      # install --encrypt --no-swap -timezone=America/Edmonton \
        nvme0n1 ens33

    Example 3
      The following command installs Arch Linux using the remaining space
      on the disk, with a swap partition, without encryption, and a
      timezone of `UTC'.

      # install --partition=remaining nvme0n1 ens33

AUTHOR:
    Fletcher Nichol <fnichol@nichol.ca>

```

### `remote-install`

You can use the `-h`/`--help` flag to get:

```sh
./bin/remote-install --help

```

## Custom Version of Kernel

If the version of `archzfs-linux` requires an older version of `linux` and
`linux-headers` you can download an older version of each of these from the
rolling release archives at:
https://archive.archlinux.org/repos/YYYY/MM/DD/core/os/x86_64/. You can create
an `override/` directory which will be used by `archiso/build` to add an
`[override]` Arch repository and will start a web server to serve up packages
back to itself. For this, you'll also need to run `repo-add` (on an Arch system)
in that directory to prepare the metadata files.

```sh
./libexec/run-with-docker
```

```sh
cd archiso
```

```sh
mkdir override
cd override

version=5.3.13.1-1
date=2019/12/02
url="https://archive.archlinux.org/repos/$date/core/os/x86_64"
```

```sh
for u in $url/linux{,-headers}-${version}.arch1-1-x86_64.pkg.tar.zst{,.sig}; do
  curl -SfL $u -o $(basename $u)
done
repo-add override.db.tar.xz *.pkg.tar.zst
```

## Recovering a System with ArchISO

Start the system with an Archiso USB key or CD/DVD image mounted to boot from.

### Login

_(Optional)_ Once booted, the system may require network connectivity if it
isn't plugged into wired networking. In this case, connect to a Wifi network
with:

```sh
wifi-menu
```

_(Optional)_ If it's easier to connect to the system remotely, then use SSH and
connect with the `root` user. To ignore the randomly generated server key use
`ssh` options with:

```sh
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$HOST
```

### Find Partitions

Let's start by setting up some variables for the _boot_ and _root_ ZFS pools:

```sh
boot_pool=bpool
root_pool=rpool
```

To find the EFI System Partition (ESP):

```sh
esp_dev="$(fdisk -l | awk '/EFI System$/ { print $1 }')"
```

### Import Pools

Next, import the ZFS pools with:

```sh
zpool import -N -d /dev/disk/by-id -R /mnt "$root_pool"
zpool import -N -d /dev/disk/by-id -R /mnt "$boot_pool"
```

### (Optional) Opening Encrypted Partitions

If the _root_ pool is encrypted then decrypt it with:

```sh
zfs load-key "$root_pool"
```

### Mount Filesystems

The ZFS filesystems need to be mounted in a particular order to replicate how
they would be presented on a booted system:

```sh
# Root fs has `canmount=off` so must be mounted explicitly first
zfs mount "$root_pool/ROOT/default"

# Boot fs has `mountpoint=legacy` so must be mounted with target
mount -t zfs "$boot_pool/BOOT/default" /mnt/boot

# Remaining fs can be auto-mounted
zfs mount -a
```

Finally, the ESP can be mounted:

```sh
mount "$esp_dev" /mnt/boot/efi
```

### Chroot into System

Now that the filesystem is setup, enter a `chroot` with:

```sh
arch-chroot /mnt /bin/bash
```

And when done, `exit` to exit the `chroot`:

```sh
exit
```

### Unmount Filesystems

Unmounting the filesystems work in the reverse order of mounting:

```sh
umount /mnt/boot/efi
zfs unmount -a
umount /mnt/boot
zfs unmount "$root_pool/ROOT/default"
```

### Export Pools

Ensure that the ZFS pools are exported so they will cleanly import on the next
system boot:

```sh
zpool export "$boot_pool"
zpool export "$root_pool"
```

### Reboot

And finally, reboot while ensuring that the USB key or CD/DVD is removed on
bootup:

```sh
reboot
```

## References

### ZFS Root Installation Reference Materials

- [OpenZFS: Arch Linux](https://openzfs.github.io/openzfs-docs/Getting%20Started/Arch%20Linux/index.html)
- [OpenZFS: Arch Linux Root on ZFS](https://openzfs.github.io/openzfs-docs/Getting%20Started/Arch%20Linux/Root%20on%20ZFS/0-overview.html)
- [Full disk encryption, including /boot: Unlocking LUKS devices from GRUB](https://cryptsetup-team.pages.debian.net/cryptsetup/encrypted-boot.html)
- [Installing Arch Linux on ZFS](https://wiki.archlinux.org/index.php/Installing_Arch_Linux_on_ZFS)
- [Arch Linux ZFS](https://wiki.archlinux.org/index.php/ZFS)
- [Arch Linux Installation Guide](https://wiki.archlinux.org/index.php/Installation_guide)
- [Arch Linux on ZFS - Part 1: Embed ZFS in Archiso](https://ramsdenj.com/2016/06/23/arch-linux-on-zfs-part-1-embed-zfs-in-archiso.html)
- [Arch Linux on ZFS - Part 2: Installation](https://ramsdenj.com/2016/06/23/arch-linux-on-zfs-part-2-installation.html)
- [Installing archlinux with zfs](https://github.com/PositronicBrain/archzfs/blob/master/Install.md)
- [Arch Linux Wiki: dm-crypt/System configuration](https://wiki.archlinux.org/title/Dm-crypt/System_configuration#Boot_loader)
- [How to change the hash-spec and iter-time of an existing dm-crypt LUKS device?](https://unix.stackexchange.com/questions/101343/how-to-change-the-hash-spec-and-iter-time-of-an-existing-dm-crypt-luks-device)
- [Install Arch Linux on ZFS with Native ROOT Encryption](https://ashu.io/blog/arch-zfs-enc/)

### Package Repository Links

- Archzfs: http://archzfs.com/archzfs/x86_64/
- https://archive.archlinux.org/packages/l/linux/
- https://archive.archlinux.org/packages/l/linux-headers/
- Arch Archive by date:
  https://archive.archlinux.org/repos/2018/04/19/core/os/x86_64/

## Code of Conduct

This project adheres to the Contributor Covenant [code of
conduct][code-of-conduct]. By participating, you are expected to uphold this
code. Please report unacceptable behavior to fnichol@nichol.ca.

## Issues

If you have any problems with or questions about this project, please contact us
through a [GitHub issue][issues].

## Contributing

You are invited to contribute to new features, fixes, or updates, large or
small; we are always thrilled to receive pull requests, and do our best to
process them as fast as we can.

Before you start to code, we recommend discussing your plans through a [GitHub
issue][issues], especially for more ambitious contributions. This gives other
contributors a chance to point you in the right direction, give you feedback on
your design, and help you find out if someone else is working on the same thing.

## Authors

Created and maintained by [Fletcher Nichol][fnichol] (<fnichol@nichol.ca>).

## License

Licensed under the Mozilla Public License Version 2.0 ([LICENSE.txt][license]).

Unless you explicitly state otherwise, any contribution intentionally submitted
for inclusion in the work by you, as defined in the MPL-2.0 license, shall be
licensed as above, without any additional terms or conditions.

[badge-check-format]:
  https://img.shields.io/cirrus/github/fnichol/arch-linux-installer.svg?style=flat-square&task=check&script=format
[badge-check-lint]:
  https://img.shields.io/cirrus/github/fnichol/arch-linux-installer.svg?style=flat-square&task=check&script=lint
[badge-ci-overall]:
  https://img.shields.io/cirrus/github/fnichol/arch-linux-installer.svg?style=flat-square
[badge-license]: https://img.shields.io/badge/License-MPL%202.0%20-blue.svg
[ci]: https://cirrus-ci.com/github/fnichol/arch-linux-installer
[ci-master]: https://cirrus-ci.com/github/fnichol/arch-linux-installer/master
[code-of-conduct]:
  https://github.com/fnichol/arch-linux-installer/blob/master/CODE_OF_CONDUCT.md
[fnichol]: https://github.com/fnichol
[github]: https://github.com/fnichol/arch-linux-installer
[issues]: https://github.com/fnichol/arch-linux-installer/issues
[license]:
  https://github.com/fnichol/arch-linux-installer/blob/master/LICENSE.txt

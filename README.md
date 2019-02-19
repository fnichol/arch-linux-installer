## ZFS Root Installation Reference Materials

* [Installing Arch Linux on ZFS](https://wiki.archlinux.org/index.php/Installing_Arch_Linux_on_ZFS)
* [Arch Linux ZFS](https://wiki.archlinux.org/index.php/ZFS)
* [Arch Linux Installation Guide](https://wiki.archlinux.org/index.php/Installation_guide)
* [Arch Linux on ZFS - Part 1: Embed ZFS in Archiso](https://ramsdenj.com/2016/06/23/arch-linux-on-zfs-part-1-embed-zfs-in-archiso.html)
* [Arch Linux on ZFS - Part 2: Installation](https://ramsdenj.com/2016/06/23/arch-linux-on-zfs-part-2-installation.html)
* [Installing archlinux with zfs](https://github.com/PositronicBrain/archzfs/blob/master/Install.md)

## Fonts

* [Better Font Rendering In Linux With Infinality](http://www.webupd8.org/2013/06/better-font-rendering-in-linux-with.html)
* [Install fonts and improve font rendering quality in Arch Linux](https://www.ostechnix.com/install-fonts-improve-font-rendering-quality-arch-linux/)
* [fontconfig-{infinality}-ultimate](https://github.com/bohoomil/fontconfig-ultimate)
* [infinality bundle fonts](http://bohoomil.com/)
* [Infinality](https://wiki.archlinux.org/index.php/Infinality)
* [Overpass font](http://overpassfont.org/)

## Look-and-Feel

* [i3wm: How To "Rice" Your Desktop](https://www.youtube.com/watch?v=ARKIwOlazKI&t=612s)
* [Improving my terminal emulator](https://www.mattwall.co.uk/2015/01/31/Improving-my-terminal-emulator.html)

## Package Repository Links

* Archzfs: http://archzfs.com/archzfs/x86_64/
* https://archive.archlinux.org/packages/l/linux/
* https://archive.archlinux.org/packages/l/linux-headers/
* Arch Archive by date: https://archive.archlinux.org/repos/2018/04/19/core/os/x86_64/

## Custom Version of Kernel

If the version of `archzfs-linux` requires an older version of `linux` and `linux-headers` you can download an older version of each of these from the rolling release archives at: https://archive.archlinux.org/repos/YYYY/MM/DD/core/os/x86_64/. You can crete a `custom/` directory which will be used by `build_archiso.sh` to add a `[custom]` Arch repo and will start a web server to serve up packages back to itself. For this, you'll also need to run `repo-add` in that directory to prepare the metadata files.

For example:

```
mkdir custom
cd custom
wget https://archive.archlinux.org/repos/2018/04/19/core/os/x86_64/linux-4.16.2-2-x86_64.pkg.tar.xz
wget https://archive.archlinux.org/repos/2018/04/19/core/os/x86_64/linux-headers-4.16.2-2-x86_64.pkg.tar.xz
repo-add custom.db.tar.xz *.pkg.tar.*
```

## Recovering a System with ArchISO

### Login

```
wifi-menu
```

```
ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@$host
```

### Find Partitions

```
pool=tank
```

```
fdisk -l | grep 'EFI System$'
```

```
esp_dev=/dev/nvme0n1p2
```

### (Optional) Opening Encrypted Partitions

```
ls -l /dev/disk/by-id/*
```

```
partid=/dev/disk/by-id/nvme-eui.000000000000001000080d02003ec7ee-part6
```

```
cryptsetup open --type luks "$partid" cryptroot
```

### Mount Filesystems

```
zpool import -d /dev/disk/by-id -R /mnt "$pool"
```

```
mount "$esp_dev" /mnt/boot/efi
```

### Chroot into System

```
arch-chroot /mnt /bin/bash
```

```
exit
```

### Unmount Filesystems

```
umount /mnt/boot/efi
zfs umount -a
zpool export "$pool"
```

### Reboot

```
reboot
```


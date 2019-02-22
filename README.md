# eclosion
An initramfs for ZFS and gentoo. 

## Status
+ Can boot on a normal zfs system (without encryption) for now...
Still under building | testing :)

## Usage

You do not need to define a pool with `bootfs`.

    $ zpool status | grep pool
      pool: zfsforninja

### 1. Normal root ZFS

+ Kernel cmdline : ` root=ZFS=zfsforninja/ROOT/gentoo `
+ Build cmd : ` ./eclosion.sh --kernel 4.14.80-gentoo `
### 2. Full disk encryption with custom hook and gpg key on the initram

An example, edit the file `hook/custom` to add your own instruction to decrypt your zpool, you can add the function `rescueShell "custom message"` if something bad happens:

```sh
# create the directory your need
mkdir -p /mnt/cryptboot

# decrypt the boot partition
gpg -qd /root/key.gpg | cryptsetup -v --key-file=- open --type luks \
  /dev/disk/by-id/ata-HARDDISK-part1 cryptboot || rescueShell "cryptboot fail to mount"

# mount the boot partition
mount /dev/mapper/cryptboot /mnt/cryptboot

# decrypt an other key
gpg -qd /root/key.gpg | cryptsetup -v --key-file=- open --type luks \
  /mnt/cryptboot/key.img lukskey || rescueShell "lukskey fail too"

# use the other key to open the final crypted device with offset, external header, etc...
cryptsetup --keyfile-offset 6668 --keyfile-size 8192 --key-file /dev/mapper/lukskey \
  --header /mnt/cryptboot/header.img open --type luks \
  /dev/disk/by-id/ata-HARDDISK-part3 zfs-enc || rescueShell "Fail to decrypt zfs-enc"
```
Save and quit.  
The init script will continous to open your zpool.

+ Kernel cmdline : ` root=ZFS=zfsforninja/ROOT/gentoo `
+ Build cmd : ` ./eclosion.sh --kernel 4.14.80-gentoo --gpg --luks --external-key /boot/key.gpg --keyboard fr-latin9 --custom `

The external key will be copied on the initram at `/root/`

## Thanks
+ [gentoo-custom-initramfs](https://wiki.gentoo.org/wiki/Custom_Initramfs)
+ [gentoo-custome-initramfs-examples](https://wiki.gentoo.org/wiki/Custom_Initramfs/Examples)
+ [mkinitramfs-ll](https://github.com/tokiclover/mkinitramfs-ll)
+ [linuxfromscratch](http://www.linuxfromscratch.org/blfs/view/svn/postlfs/initramfs.html)
+ [mdev-like-a-boss](https://github.com/slashbeast/mdev-like-a-boss)
+ [better-initramfs](https://github.com/slashbeast/better-initramfs)
+ [zfsonlinux](https://github.com/zfsonlinux/zfs/tree/master/contrib/initramfs)
+ [salsa.debian](https://salsa.debian.org/systemd-team/systemd/tree/master/debian/extra/initramfs-tools)
+ [genkernel-next](https://github.com/Sabayon/genkernel-next)
+ [bliss-initramfs](https://github.com/fearedbliss/bliss-initramfs)

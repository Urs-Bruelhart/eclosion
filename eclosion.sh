#!/bin/sh

ECLODIR=$(pwd)
ECLODIR_STATIC=$ECLODIR/static
WORKDIR=/tmp/eclosion
ROOT=/mnt/root
ZPOOL_IMPORT_PATH=/dev/disk/by-id
LOG=/tmp/eclosion.log

usage() {
  echo "-k, --kernel    Kernel version to use [Required]"
  echo "-h, --help    Print this fabulous help"
  exit 0
}

#####################################################
# Cmdline options

if [ "$#" -eq 0 ] ; then
  echo "$0: Argument required"
  echo "Try $0 --help for more information."
  exit 1
fi

while [ "$#" -gt 0 ] ; do
  case "$1" in
    -k | --kernel)
      KERNEL=$2
      shift
      shift
      ;;
    -h | --help)
      usage
      shift
      ;;
    *)
      echo "$0: Invalid option '$1'"
      echo "Try '$0 --help' for more information."
      exit 1
      ;;
  esac
done

if [ ! -d /lib/modules/$KERNEL ] ; then
  echo "Kernel version $KERNEL no found"
  exit 1
fi

LUKS="no"

[[ ! -d $WORKDIR ]] && mkdir $WORKDIR
[[ ! -d $ECLODIR_STATIC ]] && mkdir -p $ECLODIR_STATIC
echo >$LOG && echo "[+] Build saved to $LOG"

cd $WORKDIR

# Directory structure
mkdir -p bin dev etc lib64 mnt/root proc root sbin sys run usr/lib64

# If use lib64
if [[ -s /lib ]] ; then
  [[ ! -s lib ]] && ln -s lib64 lib
  [[ ! -s usr/lib ]] && cd usr; ln -s lib64 lib; cd ..
else
  mkdir lib
  mkdir usr/lib
fi

# Device nodes
cp -a /dev/{null,console,tty,tty0,tty1,zero} dev/

# mdef need /etc/group too
cp -a /etc/group etc/group

cat > etc/mdev.conf << EOF
\$MODALIAS=.*	0:0 660 @modprobe "\$MODALIAS"

null		0:0 666 @chmod 666 \$MDEV
zero		0:0 666
full		0:0 666
random		0:0 444
urandom		0:0 444
hwrandom	0:0 444
grsec		0:0 660

kmem		0:0 640
mem		0:0 640
port		0:0 640
console		0:5 600 @chmod 600 \$MDEV
ptmx		0:5 666
pty.*		0:5 660

tty		0:5 666
tty[0-9]*	0:5 660
vcsa*[0-9]*	0:5 660
ttyS[0-9]*	0:14 660

ram([0-9]*)	0:6 660 >rd/%1
loop([0-9]+)	0:6 660 >loop/%1
sd[a-z].*	0:6 660 */lib/mdev/storage-device
hd[a-z].*	0:6 660 */lib/mdev/storage-device
vd[a-z].* 0:6 660 */lib/mdev/storage-device
dm-[0-9]* 0:6 660 */lib/mdev/storage-device
bcache[0-9]* 0:6 660 */lib/mdev/storage-device

fuse		0:0 666

event[0-9]+	0:0 640 =input/
mice		0:0 640 =input/
mouse[0-9]	0:0 640 =input/
ts[0-9]		0:0 600 =input/

usbdev[0-9]*	0:0 660
EOF

mkdir -p lib/mdev
cp /lib/mdev/ide_links lib/mdev/
if [ ! -f $ECLODIR_STATIC/storage-device ] ; then
  wget -P $ECLODIR_STATIC/ https://raw.githubusercontent.com/slashbeast/mdev-like-a-boss/master/helpers/storage-device
  chmod +x $ECLODIR_STATIC/storage-device
fi
cp -a $ECLODIR_STATIC/storage-device lib/mdev/

if [[ $LUKS == "yes" ]] ; then
  mkdir -p share/gnupg
fi

# Copy binaries | static install when possible
source /etc/portage/make.conf

#######################################################
# Busybox

BUSYBOX_BIN=$WORKDIR/bin/busybox
if [ ! -x $ECLODIR_STATIC/busybox ] ; then
  echo "[+] Install busybox"
  PKG=sys-apps/busybox
  BUSYBOX_EBUILD=$(ls /usr/portage/$PKG | head -n 1)
  USE="-pam static" ebuild /usr/portage/$PKG/$BUSYBOX_EBUILD clean unpack compile
  (cp /var/tmp/portage/${PKG%/*}/${BUSYBOX_EBUILD%.*}/work/${BUSYBOX_EBUILD%.*}/busybox $ECLODIR_STATIC/busybox)
  ebuild /usr/portage/$PKG/$BUSYBOX_EBUILD clean
elif ldd $ECLODIR_STATIC/busybox >/dev/null ; then
  echo "[-] Busybox is not static"
  exit 1
else
  echo "[+] Busybox found"
fi

cp -a $ECLODIR_STATIC/busybox $BUSYBOX_BIN
BUSY_BIN=$(type -p $BUSYBOX_BIN)
BUSY_APPS=/tmp/busybox-apps
$BUSY_BIN --list-full > $BUSY_APPS

# To avoid busybox create a symbolic link of busybox
mv bin/busybox .

for bin in $(grep -e '^bin/[a-z]' $BUSY_APPS) ; do
  ln -s busybox $bin 
done
for sbin in $(grep -e '^sbin/[a-z]' $BUSY_APPS) ; do
  ln -s ../bin/busybox $sbin
done

# Replace few link by program
rm bin/busybox && mv busybox bin/
rm sbin/blkid

#######################################################
# ZFS

# ZFS bins
bins="blkid zfs zpool mount.zfs zdb fsck.zfs"
# from /usr/share/initramfs-tools/hooks/zfs
modules="zlib_deflate spl zavl znvpair zcommon zunicode icp zfs"

doBin() {
  local lib bin link
  bin=$(which $1 2>/dev/null)
  [[ $? -ne 0 ]] && bin=$1
  for lib in $(lddtree -l $bin 2>/dev/null | sort -u) ; do
    echo "[+] Copying lib $lib to .$lib ... " >>$LOG
    if [ -h $lib ] ; then
      link=$(readlink $lib)
      echo "Found a link $lib == ${lib%/*}/$link" >>$LOG
      cp -a $lib .$lib
      cp -a ${lib%/*}/$link .${lib%/*}/$link
    elif [ -x $lib ] ; then
      echo "Found binary $lib" >>$LOG
      cp -a $lib .$lib
    fi
  done
}

doMod() {
  local m mod=$1 modules lib_dir=/lib/modules/$KERNEL

  for mod; do
    modules="$(sed -nre "s/(${mod}(|[_-]).*$)/\1/p" ${lib_dir}/modules.dep)"
    if [ -n "${modules}" ]; then
      for m in ${modules}; do
        m="${m%:}"
        echo "[+] Copying module $m ..." >>$LOG
        mkdir -p .${lib_dir}/${m%/*} && cp -ar ${lib_dir}/${m} .${lib_dir}/${m}
      done
    else
      echo "[-] ${mod} kernel module not found"
    fi
  done
}

for bin in $bins ; do
  doBin $bin
done

for mod in $modules ; do
  doMod $mod
done

# TODO: install keymap for future use of gpg 

# Handle GCC libgcc_s.so
search_lib=$(find /usr/lib* -type f -name libgcc_s.so.1)
if [[ -n $search_lib ]] ; then
  doBin $search_lib
  cp ${search_lib} usr/lib64/libgcc_s.so.1
else
  echo "[-] libgcc_s.so.1 no found on the system..."
  exit 1
fi

# Add kernel modules
cp -a /lib/modules/$KERNEL/modules.dep ./lib/modules/$KERNEL/

# Create the init
cat > init << EOF
#!/bin/sh

# TODO: Later from /proc/cmdline
INIT=/lib/systemd/systemd
ROOT=$ROOT
MODULES="$modules"
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

rescueShell() {
  echo "\$1. Dropping you to a shell."
  /bin/sh -l
}

# Disable kernel log
echo 0 > /proc/sys/kernel/printk
clear

#######################################################
# Modules

# Load modules
if [ -n "\$MODULES" ]; then
  for m in \$MODULES ; do
    modprobe -q \$m
  done
else
  rescueShell "No modules found"
fi

#######################################################
# Filesytem and mdev setup

mkdir -p dev/pts proc run sys \$ROOT

# mount for mdev 
# https://git.busybox.net/busybox/plain/docs/mdev.txt
mount -t proc proc /proc
mount -t sysfs sysfs /sys

if grep -q devtmpfs /proc/filesystems; then
  mount -t devtmpfs devtmpfs /dev
else
  mount -t tmpfs -o exec,mode=755 tmpfs /dev
fi

# Add mdev (for use disk by UUID,LABEL, etc...)
echo >/dev/mdev.seq
[ -x /sbin/mdev ] && MDEV=/sbin/mdev || MDEV="/bin/busybox mdev"
mdev -s
echo \$MDEV > /proc/sys/kernel/hotplug

mount -t tmpfs -o mode=755,size=1% tmpfs /run

#######################################################
# ZFS

for x in \$(cat /proc/cmdline) ; do
  case \$x in
    root=ZFS=*)
      BOOT=\$x
    ;;
  esac
done

if [ -z \$BOOT ] ; then
  rescueShell "No pool defined has kernel cmdline"
else
  # if root=ZFS=zfsforninja/ROOT/gentoo, become
  #         zfsforninja/ROOT/gentoo
  BOOTFS=\${BOOT##*=}
  RPOOL=\${BOOTFS%%/*}
fi

zpoolMount() {
  local zfs_stderr zfs_error
  for dir in /dev/disk/by-vdev /dev/disk/by-* /dev; do
    [ ! -d \$dir ] && continue
    zfs_stderr=\$(zpool import -d \$dir -R \$ROOT -N \$RPOOL 2>&1)
    zfs_error=\$?
    if [ "\$zfs_error" == 0 ] ; then
      [[ "\$BOOTFS" != "\$RPOOL" ]] && zfs set mountpoint=/ \$BOOTFS
      return 0
    fi
  done
}

mountFs() {
  local fs canmount mountpoint zfs_cmd zfs_stderr zfs_error
  fs=\$1
  # Skip canmount=off
  if [ "\$fs" != "\$BOOTFS" ] ; then
    canmount=\$(zfs get -H -ovalue canmount "\$fs" 2> /dev/null)
    [ "\$canmount" == "off" ] && return 0
  fi
  # get original mountpoint
  mountpoint=\$(zfs get -H -ovalue mountpoint "\$fs")
  if [ \$mountpoint == "legacy" -o \$mountpoint == "none" ] ; then
    mountpoint=\$(zfs get -H -ovalue org.zol:mountpoint "\$fs")
    if [ \$mountpoint == "legacy" -o \$mountpoint == "none" -o \$mountpoint == "-" ] ; then
      if [ \$fs != "\$BOOTFS" ] ; then
        return 0
      else
        mountpoint=""
      fi
    fi
    if [ \$mountpoint == "legacy" ] ; then
      zfs_cmd="mount -t zfs"
    else
      zfs_cmd="mount -o zfsutil -t zfs"
    fi
  else
    zfs_cmd="mount -o zfsutil -t zfs"
  fi
  zfs_stderr=\$(\$zfs_cmd "\$fs" "\$ROOT/\$mountpoint" 2>&1)
  zfs_error=\$?
  if [ \$zfs_error -eq 0 ] ; then
    return 0
  else
    rescueShell "Failed to mount \$fs"
  fi
}

#######################################################
# Import POOL and dataset

echo \$\$ >/run/\${0##*/}.pid

echo "found dir: "
ls /dev/disk/by-*

zpoolMount
filesystems=\$(zfs list -oname -tfilesystem -H -r \$RPOOL)
if [ -n \$filesystems ] ; then
  for fs in \$filesystems ; do
    mountFs \$fs
  done
else
  rescueShell "Failed to get datasets, try: zfs mount -a && exit"
fi

rm /run/\${0##*/}.pid

#######################################################
# Cleanup and switch

# cleanup
umount /proc
umount /sys
umount /dev

# switch
exec switch_root /mnt/root \${INIT:-/sbin/init}

# If the switch has fail
rescueShell "Yaaa, it is sucks"
EOF

chmod u+x init

# Create the initramfs
find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../eclosion-initramfs.img

cd ..
echo "[+] initramfs created at $(pwd)/eclosion-initramfs.img"
#rm -rf $WORKDIR

exit 0

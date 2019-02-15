#!/bin/sh

########################################################
# Program Vars

ECLODIR=$(pwd)
ECLODIR_STATIC=$ECLODIR/static
WORKDIR=/tmp/eclosion
ROOT=/mnt/root
LOG=/tmp/eclosion.log
LUKS=false
QUIET=true

########################################################
# Cmdline options

usage() {
  echo "-k, --kernel    Kernel version to use [Required]"
  echo "-l, --luks    Add cryptsetup to the image"
  echo "-h, --help    Print this fabulous help"
  exit 0
}

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
    -l | --luks)
      LUKS=true
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

########################################################
# Install $WORKDIR

[[ -d $WORKDIR ]] && rm -rf $WORKDIR/*

[[ ! -d $WORKDIR ]] && mkdir $WORKDIR
[[ ! -d $ECLODIR_STATIC ]] && mkdir -p $ECLODIR_STATIC
echo >$LOG && echo "[+] Build saved to $LOG"

cd $WORKDIR

########################################################
# Base

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

########################################################
# ZFS

bins="blkid zfs zpool mount.zfs zdb fsck.zfs"
modules="zlib_deflate spl zavl znvpair zcommon zunicode icp zfs"

########################################################
# Functions

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

########################################################
# Install hooks

. $ECLODIR/hooks/busybox
. $ECLODIR/hooks/udev

DEVTMPFS=$(grep devtmpfs /proc/filesystems)
if [ -z "$DEVTMPFS" ] ; then
  . $ECLODIR/hooks/mdev
fi

########################################################
# Install cryptsetup

#modules+=" vfat nls_cp437 nls_iso8859-1 ext4"

########################################################
# libgcc_s.so.1 required by zfs

search_lib=$(find /usr/lib* -type f -name libgcc_s.so.1)
if [[ -n $search_lib ]] ; then
  bin+=" $search_lib"
  cp ${search_lib} usr/lib64/libgcc_s.so.1
else
  echo "[-] libgcc_s.so.1 no found on the system..."
  exit 1
fi

########################################################
# Install binary and modules

for bin in $bins ; do
  doBin $bin
done

for mod in $modules ; do
  doMod $mod
done

########################################################
# Copy the modules.dep

cp -a /lib/modules/$KERNEL/modules.dep ./lib/modules/$KERNEL/

########################################################
# Build the init

cat > init << EOF
#!/bin/sh

# TODO: Later from /proc/cmdline
INIT=/lib/systemd/systemd
ROOT=$ROOT
MODULES="$modules"
UDEVD=$UDEVD
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
  echo >/dev/mdev.seq
  [ -x /sbin/mdev ] && MDEV=/sbin/mdev || MDEV="/bin/busybox mdev"
  mdev -s
  echo \$MDEV > /proc/sys/kernel/hotplug
fi

mount -t tmpfs -o mode=755,size=1% tmpfs /run

#######################################################
# udevd

if [ -w /sys/kernel/uevent_helper ] ; then
  echo > /sys/kernel/uevent_helper
fi

\${UDEVD} --daemon --resolve-names=never 2> /dev/null
udevadm trigger --type=subsystems --action=add
udevadm trigger --type=devices --action=add
udevadm settle || true

#######################################################
# ZFS

for x in \$(cat /proc/cmdline) ; do
  case \$x in
    root=ZFS=*)
      BOOT=\$x
    ;;
  esac
done

# Seach a line like root=ZFS=zfsforninja/ROOT/gentoo
if [ -z \$BOOT ] ; then
  rescueShell "No pool defined has kernel cmdline"
else
  # if root=ZFS=zfsforninja/ROOT/gentoo, become
  #         zfsforninja/ROOT/gentoo
  BOOTFS=\${BOOT##*=}
  RPOOL=\${BOOTFS%%/*}
fi

# Import pool with -N (import without mounting any fs)
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

# Mount dataset manually rather than use zfs mount -a
# ref: somewhere at https://github.com/zfsonlinux/zfs/blob/master/contrib/initramfs/scripts/zfs.in
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
  zfs_stderr=\$(\$zfs_cmd "\$fs" "\$mountpoint" 2>&1)
  zfs_error=\$?
  if [ \$zfs_error -eq 0 ] ; then
    return 0
  else
    rescueShell "Failed to mount \$fs at \$mountpoint"
  fi
}

#######################################################
# Import POOL and dataset

echo \$\$ >/run/\${0##*/}.pid

#echo "found dir: "
#ls /dev/disk/by-*

zpoolMount
filesystems=\$(zfs list -oname -tfilesystem -H -r \$RPOOL)
if [ -n "\$filesystems" ] ; then
  for fs in \$filesystems ; do
    mountFs \$fs
  done
else
  rescueShell "Failed to get datasets, try: zfs mount -a && exit"
fi

rm /run/\${0##*/}.pid

#######################################################
# Cleanup and switch

udevadm control --exit

# if use mdev
if ! grep -q devtmpfs /proc/filesystems; then
  echo '' > /proc/sys/kernel/hotplug
fi

# move /dev to ROOT
mount -n -o move /dev "\$ROOT/dev" || mount -n --move /dev "\$ROOT/dev"

# create a temporary symlink to the final /dev for other initramfs scripts
if command -v nuke >/dev/null; then
  nuke /dev
else
  # shellcheck disable=SC2114
  rm -rf /dev
fi
ln -s "\$ROOT/dev" /dev

# cleanup
for dir in /run /sys /proc ; do
  echo "Unmouting \$dir"
  umount -l \$dir
  echo "\$?"
done

# switch
exec switch_root /mnt/root \${INIT:-/sbin/init}

# If the switch has fail
rescueShell "Yaaa, it is sucks"
EOF

chmod u+x init

# Create the initramfs
if [ $QUIET == true ] ; then
  find . -print0 | cpio --null -ov --format=newc 2>>$LOG | gzip -9 > ../eclosion-initramfs.img
  echo -e "\nImage size $(tail -n 1 $LOG)"
else
  find . -print0 | cpio --null -ov --format=newc | gzip -9 > ../eclosion-initramfs.img
fi

cd ..
echo "[+] initramfs created at $(pwd)/eclosion-initramfs.img"

exit 0

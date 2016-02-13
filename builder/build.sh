#!/bin/bash
set -ex
# This script should be run only inside of a Docker container
if [ ! -f /.dockerinit ]; then
  echo "ERROR: script works only in a Docker container!"
  exit 1
fi

### setting up some important variables to control the build process

# where to store our created sd-image file
BUILD_RESULT_PATH="/workspace"
BUILD_PATH="/build"

# where to store our base file system
HYPRIOT_OS_VERSION="v0.7.2"
ROOTFS_TAR="rootfs-armhf-${HYPRIOT_OS_VERSION}.tar.gz"
ROOTFS_TAR_PATH="$BUILD_RESULT_PATH/$ROOTFS_TAR"

# device specific settings
HYPRIOT_IMAGE_VERSION=${VERSION:="dirty"}
HYPRIOT_IMAGE_NAME="sd-card-odroid-xu4-${HYPRIOT_IMAGE_VERSION}.img"
IMAGE_ROOTFS_PATH="/image-rootfs.tar.gz"
QEMU_ARCH="arm"
export HYPRIOT_IMAGE_VERSION

# specific versions of kernel/firmware and docker tools
export DOCKER_ENGINE_VERSION="1.10.1-1"
export DOCKER_COMPOSE_VERSION="1.6.0-27"
export DOCKER_MACHINE_VERSION="0.4.1-72"

# size of root and boot partion (in MByte)
ROOT_PARTITION_START="3072"
ROOT_PARTITION_SIZE="800"
#---don't change here---
ROOT_PARTITION_OFFSET="$(($ROOT_PARTITION_START*512))"
#---don't change here---

# create build directory for assembling our image filesystem
rm -rf $BUILD_PATH
mkdir -p $BUILD_PATH/{boot,root}

#---create image file---
dd if=/dev/zero of=/$HYPRIOT_IMAGE_NAME bs=1MiB count=$ROOT_PARTITION_SIZE
echo -e "o\nn\np\n1\n${ROOT_PARTITION_START}\n\nw\n" | fdisk /$HYPRIOT_IMAGE_NAME
#-partition #1 - Type=83 Linux
losetup -d /dev/loop0 || /bin/true
losetup --offset $ROOT_PARTITION_OFFSET /dev/loop0 /$HYPRIOT_IMAGE_NAME
mkfs.ext4 -O ^has_journal -b 4096 -L rootfs -U e139ce78-9841-40fe-8823-96a304a09859 /dev/loop0
losetup -d /dev/loop0
sleep 3
#-test mount and write a file
mount -t ext4 -o loop=/dev/loop0,offset=$ROOT_PARTITION_OFFSET /$HYPRIOT_IMAGE_NAME $BUILD_PATH/root
echo "HypriotOS: root partition" > $BUILD_PATH/root/root.txt
tree -a $BUILD_PATH/
df -h
umount $BUILD_PATH/root
#---create image file---

# log image partioning
fdisk -l /$HYPRIOT_IMAGE_NAME
losetup

# download our base root file system
if [ ! -f $ROOTFS_TAR_PATH ]; then
  wget -q -O $ROOTFS_TAR_PATH https://github.com/hypriot/os-rootfs/releases/download/$HYPRIOT_OS_VERSION/$ROOTFS_TAR
fi

# extract root file system
tar -xzf $ROOTFS_TAR_PATH -C $BUILD_PATH

# register qemu-arm with binfmt
update-binfmts --enable qemu-$QEMU_ARCH

# set up mount points for pseudo filesystems
mkdir -p $BUILD_PATH/{proc,sys,dev/pts}

mount -o bind /dev $BUILD_PATH/dev
mount -o bind /dev/pts $BUILD_PATH/dev/pts
mount -t proc none $BUILD_PATH/proc
mount -t sysfs none $BUILD_PATH/sys

#---modify image---
# modify/add image files directly
cp -R /builder/files/* $BUILD_PATH/

# modify image in chroot environment
chroot $BUILD_PATH /bin/bash </builder/chroot-script.sh
#---modify image---

umount -l $BUILD_PATH/sys || true
umount -l $BUILD_PATH/proc || true
umount -l $BUILD_PATH/dev/pts || true
umount -l $BUILD_PATH/dev || true

# package image rootfs
tar -czf $IMAGE_ROOTFS_PATH -C $BUILD_PATH .

# create the image and add a single ext4 filesystem
# --- important settings for ODROID SD card
# - initialise the partion with MBR
# - use start sector 3072, this reserves 1.5MByte of disk space
# - don't set the partition to "bootable"
# - format the disk with ext4
# for debugging use 'set-verbose true'
#set-verbose true

#FIXME: use latest upstream u-boot files from hardkernel
# download current bootloader/u-boot images from hardkernel
wget -q https://github.com/hardkernel/u-boot/raw/odroidxu3-v2012.07/sd_fuse/hardkernel/sd_fusing.sh
chmod +x sd_fusing.sh
wget -q https://github.com/hardkernel/u-boot/raw/odroidxu3-v2012.07/sd_fuse/hardkernel/bl1.bin.hardkernel
wget -q https://github.com/hardkernel/u-boot/raw/odroidxu3-v2012.07/sd_fuse/hardkernel/bl2.bin.hardkernel
wget -q https://github.com/hardkernel/u-boot/raw/odroidxu3-v2012.07/sd_fuse/hardkernel/u-boot.bin.hardkernel
wget -q https://github.com/hardkernel/u-boot/raw/odroidxu3-v2012.07/sd_fuse/hardkernel/tzsw.bin.hardkernel

guestfish -a "/${HYPRIOT_IMAGE_NAME}" <<EOF
run

# import base rootfs
mount /dev/sda1 /
tar-in $IMAGE_ROOTFS_PATH / compress:gzip

#FIXME: use dd to directly writing u-boot to image file
#FIXME2: later on, create a dedicated .deb package to install/update u-boot
# write bootloader and u-boot into image start sectors 0-3071
upload sd_fusing.sh /boot/sd_fusing.sh
upload bl1.bin.hardkernel /boot/bl1.bin.hardkernel
upload bl2.bin.hardkernel /boot/bl2.bin.hardkernel
upload u-boot.bin.hardkernel /boot/u-boot.bin
upload tzsw.bin.hardkernel /boot/tzsw.bin.hardkernel
copy-file-to-device /boot/bl1.bin.hardkernel /dev/sda destoffset:512
copy-file-to-device /boot/bl2.bin.hardkernel /dev/sda destoffset:15872
copy-file-to-device /boot/u-boot.bin /dev/sda destoffset:32256
copy-file-to-device /boot/tzsw.bin.hardkernel /dev/sda destoffset:368128
EOF

# log image partioning
fdisk -l "/$HYPRIOT_IMAGE_NAME"

# ensure that the travis-ci user can access the SD card image file
umask 0000

# compress image
pigz --zip -c "$HYPRIOT_IMAGE_NAME" > "$BUILD_RESULT_PATH/$HYPRIOT_IMAGE_NAME.zip"

# test sd-image that we have built
VERSION=${HYPRIOT_IMAGE_VERSION} rspec --format documentation --color /builder/test

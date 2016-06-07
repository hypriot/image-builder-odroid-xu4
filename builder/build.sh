#!/bin/bash
set -ex
# This script should be run only inside of a Docker container
if [ ! -f /.dockerenv ]; then
  echo "ERROR: script works only in a Docker container!"
  exit 1
fi

# get versions for software that needs to be installed
source /workspace/versions.config

### setting up some important variables to control the build process

# where to store our created sd-image file
BUILD_RESULT_PATH="/workspace"

# place to build our sd-image
BUILD_PATH="/build"

# where to store our base file system
ROOTFS_TAR="rootfs-armhf-debian-${HYPRIOT_OS_VERSION}.tar.gz"
ROOTFS_TAR_PATH="$BUILD_RESULT_PATH/$ROOTFS_TAR"

# Show TRAVSI_TAG in travis builds
echo TRAVIS_TAG="${TRAVIS_TAG}"

# device specific settings
HYPRIOT_IMAGE_VERSION=${VERSION:="dirty"}
HYPRIOT_IMAGE_NAME="hypriotos-odroid-xu4-${HYPRIOT_IMAGE_VERSION}.img"
IMAGE_ROOTFS_PATH="/image-rootfs.tar.gz"
export HYPRIOT_IMAGE_VERSION

BOOT_PARTITION_OFFSET="3072"
# size of root and boot partion (in MByte)
ROOT_PARTITION_SIZE="800"
BOOT_PARTITION_SIZE="64"
#---don't change here---
BOOT_PARTITION_BYTE_SIZE=$((BOOT_PARTITION_SIZE*1024*1024))
ROOT_PARTITION_OFFSET=$((BOOT_PARTITION_BYTE_SIZE/512+BOOT_PARTITION_OFFSET))
#---don't change here---


# create build directory for assembling our image filesystem
rm -rf ${BUILD_PATH}
mkdir -p ${BUILD_PATH}

#---create image file---

# new size (boot+root)
dd if=/dev/zero of="/${HYPRIOT_IMAGE_NAME}" bs=1MiB count="$((ROOT_PARTITION_SIZE+BOOT_PARTITION_SIZE))"

# create DOS partition Table
echo -e "o\nw\n" | fdisk "/${HYPRIOT_IMAGE_NAME}"

# Boot partition
echo -e "n\np\n1\n${BOOT_PARTITION_OFFSET}\n$((ROOT_PARTITION_OFFSET-1))\np\nw\n" | fdisk "/${HYPRIOT_IMAGE_NAME}"

# set fat16 for boot partition
echo -e "t\n6\np\nw\n" | fdisk "/${HYPRIOT_IMAGE_NAME}"

# new root partition
echo -e "n\np\n2\n${ROOT_PARTITION_OFFSET}\n\np\nw\n" | fdisk "/${HYPRIOT_IMAGE_NAME}"

# format boot partition
losetup -d /dev/loop0 || /bin/true
losetup --offset $((BOOT_PARTITION_OFFSET*512)) /dev/loop0 "/${HYPRIOT_IMAGE_NAME}"
mkfs.msdos -F 16 -n HypriotOS /dev/loop0
losetup -d /dev/loop0
sleep 3

# format root partition
#-partition #1 - Type=83 Linux
losetup -d /dev/loop0 || /bin/true
losetup --offset $((ROOT_PARTITION_OFFSET*512)) /dev/loop0 "/${HYPRIOT_IMAGE_NAME}"
mkfs.ext4 -O ^has_journal -b 4096 -i 4096 -L root -U e139ce78-9841-40fe-8823-96a304a09859 /dev/loop0
losetup -d /dev/loop0
sleep 3


#-test mount and write a file
mount -t ext4 -o loop=/dev/loop0,offset=${ROOT_PARTITION_OFFSET*512} "/${HYPRIOT_IMAGE_NAME}" ${BUILD_PATH}
echo "HypriotOS: root partition" > ${BUILD_PATH}/root.txt
tree -a ${BUILD_PATH}/
df -h
umount ${BUILD_PATH}
#---create image file---

# log image partioning
fdisk -l "/${HYPRIOT_IMAGE_NAME}"
losetup

#---flash bootloader---
# download current bootloader/u-boot images from hardkernel
# (this one is able to boot from a EXT4 file system)
_commit=814386d3e43b8ab8d81f04aa7fe402952503d8fe
wget -q https://github.com/hardkernel/linux/raw/${_commit}/tools/hardkernel/prebuilt_uboot/bl1.bin
wget -q https://github.com/hardkernel/linux/raw/${_commit}/tools/hardkernel/prebuilt_uboot/bl2.bin
wget -q https://github.com/hardkernel/linux/raw/${_commit}/tools/hardkernel/prebuilt_uboot/u-boot.bin
wget -q https://github.com/hardkernel/linux/raw/${_commit}/tools/hardkernel/prebuilt_uboot/tzsw.bin
dd conv=notrunc if=bl1.bin of="/${HYPRIOT_IMAGE_NAME}" seek=1
dd conv=notrunc if=bl2.bin of="/${HYPRIOT_IMAGE_NAME}" seek=31
dd conv=notrunc if=u-boot.bin of="/${HYPRIOT_IMAGE_NAME}" seek=63
dd conv=notrunc if=tzsw.bin of="/${HYPRIOT_IMAGE_NAME}" seek=719
#---flash bootloader---

# download our base root file system
if [ ! -f "${ROOTFS_TAR_PATH}" ]; then
  wget -q -O "$ROOTFS_TAR_PATH" "https://github.com/hypriot/os-rootfs/releases/download/${HYPRIOT_OS_VERSION}/${ROOTFS_TAR}"
fi

# extract root file system
tar -xzf "${ROOTFS_TAR_PATH}" -C ${BUILD_PATH}

# register qemu-arm with binfmt
update-binfmts --enable qemu-arm

# set up mount points for pseudo filesystems
mkdir -p ${BUILD_PATH}/{proc,sys,dev/pts,media/boot}

mount -o bind /dev ${BUILD_PATH}/dev
mount -o bind /dev/pts ${BUILD_PATH}/dev/pts
mount -t proc none ${BUILD_PATH}/proc
mount -t sysfs none ${BUILD_PATH}/sys

#---modify image---
# modify/add image files directly
cp -R /builder/files/* ${BUILD_PATH}/

# modify image in chroot environment
chroot ${BUILD_PATH} /bin/bash </builder/chroot-script.sh
#---modify image---

umount -l ${BUILD_PATH}/sys || true
umount -l ${BUILD_PATH}/proc || true
umount -l ${BUILD_PATH}/dev/pts || true
umount -l ${BUILD_PATH}/dev || true

# package image rootfs
tar -czf ${IMAGE_ROOTFS_PATH} -C ${BUILD_PATH} .

#---copy rootfs to image file---
mkdir -p "${BUILD_PATH}/root"
mount -t ext4 -o loop=/dev/loop0,offset=$((ROOT_PARTITION_OFFSET*512)) "/${HYPRIOT_IMAGE_NAME}" ${BUILD_PATH}/root/
mount -t fat16 -o loop=/dev/loop0,offset=$((BOOT_PARTITION_OFFSET*512)) "/${HYPRIOT_IMAGE_NAME}" ${BUILD_PATH}/root/media/boot

tar -xzf ${IMAGE_ROOTFS_PATH} -C ${BUILD_PATH}
df -h
umount ${BUILD_PATH}/root/media/boot
umount ${BUILD_PATH}/root
#---copy rootfs to image file---

# log image partioning
fdisk -l "/${HYPRIOT_IMAGE_NAME}"

# ensure that the travis-ci user can access the SD card image file
umask 0000

# compress image
pigz --zip -c "${HYPRIOT_IMAGE_NAME}" > "${BUILD_RESULT_PATH}/${HYPRIOT_IMAGE_NAME}.zip"
cd ${BUILD_RESULT_PATH} && sha256sum "${HYPRIOT_IMAGE_NAME}.zip" > "${HYPRIOT_IMAGE_NAME}.zip.sha256" && cd -

# test sd-image that we have built
VERSION=${HYPRIOT_IMAGE_VERSION} rspec --format documentation --color /builder/test

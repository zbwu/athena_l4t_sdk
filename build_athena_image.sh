#!/bin/bash

SCRIPT=$(realpath ${BASH_SOURCE[0]})
LDK_DIR=$(dirname $SCRIPT)
LDK_ROOTFS_DIR="${LDK_DIR}/rootfs"

if [[ ! -f ${LDK_DIR}/tools/kernel_flash/l4t_initrd_flash.sh ]]; then
    echo "ERROR: ${LDK_DIR} is not the TOP of L4T SDK"
    exit 1
fi

if [[ ! -f ${LDK_DIR}/tools/samplefs/sample_fs.tbz2 ]]; then
    echo "ERROR: ${LDK_DIR}/tools/samplefs/sample_fs.tbz2 not found"
    exit 1
fi

THIS_USER="$(whoami)"
if [ "${THIS_USER}" != "root" ]; then
	echo "ERROR: This script requires root privilege" > /dev/stderr
	exit 1
fi
# Clear old rootfs
rm -rf ${LDK_ROOTFS_DIR}
mkdir ${LDK_ROOTFS_DIR}

# Extract sample file system
tar -xpf ${LDK_DIR}/tools/samplefs/sample_fs.tbz2 -C ${LDK_ROOTFS_DIR}

# Install nVidia userspace packages and customize rootfs
${LDK_DIR}/apply_binaries.sh

# create image, no flash
rm -rf ${LDK_DIR}/tools/kernel_flash/images
BOARDID=3668 BOARDSKU=0001 FAB=100 \
    ./tools/kernel_flash/l4t_initrd_flash.sh --no-flash --external-device nvme0n1p2 \
    -c ./tools/kernel_flash/flash_l4t_athena_rootfs.xml -S 100GiB --showlogs \
    jetson-xavier-nx-athena nvme0n1p2

# print notes
echo ""
echo ""
echo "====================================================================="
echo "Put Cyberdog into recovery mode:"
echo "        for exmaple: sudo reboot --force forced-recovery"
echo "        or: Hold down Recovery Button and push Reset Button"
echo "In Host: sudo ./tools/kernel_flash/l4t_initrd_flash.sh --flash-only"
echo "====================================================================="
echo ""
echo ""

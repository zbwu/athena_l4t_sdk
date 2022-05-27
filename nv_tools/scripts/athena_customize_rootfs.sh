#!/bin/bash

# This script contains function to apply athena customization to root
# file system

# $1 - Path to rootfs
function athena_customize_rootfs {
	LDK_ROOTFS_DIR="${1}"
	if [ ! -d "${LDK_ROOTFS_DIR}" ]; then
		echo "Error: ${LDK_ROOTFS_DIR} does not exist!"
		exit 1
	fi
	ARM_ABI_DIR=

	if [ -d "${LDK_ROOTFS_DIR}/usr/lib/arm-linux-gnueabihf/tegra" ]; then
		ARM_ABI_DIR_ABS="usr/lib/arm-linux-gnueabihf"
	elif [ -d "${LDK_ROOTFS_DIR}/usr/lib/arm-linux-gnueabi/tegra" ]; then
		ARM_ABI_DIR_ABS="usr/lib/arm-linux-gnueabi"
	elif [ -d "${LDK_ROOTFS_DIR}/usr/lib/aarch64-linux-gnu/tegra" ]; then
		ARM_ABI_DIR_ABS="usr/lib/aarch64-linux-gnu"
	else
		echo "Error: None of Hardfp/Softfp Tegra libs found"
		exit 4
	fi

	ARM_ABI_DIR="${LDK_ROOTFS_DIR}/${ARM_ABI_DIR_ABS}"
	ARM_ABI_TEGRA_DIR="${ARM_ABI_DIR}/tegra"

	if [[ -f ${LDK_ROOTFS_DIR}/opt/nvidia/l4t-usb-device-mode/nv-l4t-usb-device-mode-config.sh ]]; then
		sed -e "s:enable_rndis=1:enable_rndis=0:g" -e "s:enable_ums=1:enable_ums=0:g" \
			-i ${LDK_ROOTFS_DIR}/opt/nvidia/l4t-usb-device-mode/nv-l4t-usb-device-mode-config.sh
	fi
}

athena_customize_rootfs "${1}"

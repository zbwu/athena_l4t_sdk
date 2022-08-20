#!/bin/bash

# Copyright (c) 2021, NVIDIA CORPORATION.  All rights reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

# This is a script to update rootfs in recover kernel for the case without
# layout change. It needs to executes the following steps:
# 1. Check whether bootloader is updated. If no, go to step 3;
#    otherwise,continue
# 2. Check whether bootloader update with BUP is successful
# 3. Locate rootfs image and check whether it is valid
# 4. Run rootfs updater to update rootfs partition
# 5. Update recovery partition
# 6. Update kernel-bootctrl partition
# 7. Reboot device.
# Supposedly, the device will enter into normal kernel after reboot.

_BUP_UPDATE_UTILITIES=( "nv_update_engine" "nv_bootloader_payload_updater" "nvbootctrl" )
_KERNEL_BOOTCTRL_NORMAL_FILE="images-R32-ToT/kernel_bootctrl.bin.normal"
_NV_UPDATE_ENGINE="/usr/sbin/nv_update_engine"
_NVBOOTCTRL="/usr/sbin/nvbootctrl"
_ROOTFS_IMAGE_NAME="system.img"
_ROOTFS_UPDATE_SUCCESS="/tmp/rootfs_update_success"
_UPDATE_CONTROL_FILE="update_control"
_current_storage_device=

copy_utilities_for_BUP_update()
{
	# Prepare the utilities that are necessary to update
	# bootloader with BUP. These utilities includes:
	# nv_update_engine, nvbootctrl and nv_bootloader_payload_updater.
	# Copy these utilities from {work_dir} into /bin
	# Usage:
	#        copy_utilities_for_BUP_update {work_dir}
	local work_dir="${1}"
	local src=
	local dst=
	local item=
	for item in "${_BUP_UPDATE_UTILITIES[@]}"
	do
		dst="/usr/sbin/${item}"
		src="${work_dir}/${item}"
		if [ ! -f "${src}" ]; then
			ota_log "Error: ${src} is not found"
			return 1
		fi
		cp -f "${src}" "${dst}"
	done
}

is_bootloader_updated()
{
	# Check whether bootloader is updated by reading the value
	# from the file "${work_dir}/${_UPDATE_ROOTFS_ONLY_FILE}"
	# Usage
	#    is_bootloader_updated {work_dir}
	local work_dir="${1}"
	local update_control_file="${work_dir}/${_UPDATE_CONTROL_FILE}"
	local bl_updated=

	if [ ! -r "${update_control_file}" ]; then
		return 1
	fi

	bl_updated="$(grep -o "bootloader" <"${update_control_file}")"
	if [ "${bl_updated}" == "bootloader" ]; then
		return 0
	else
		return 1
	fi
}

is_bootloader_update_successful()
{
	# Check whether updating bootloader with BUP is successful by
	# using the utilities "nv_update_engine" and "nvbootctrl"
	# Usage
	#    is_bootloader_update_successful {work_dir}
	local work_dir="${1}"
	local ota_nv_boot_control_conf="${work_dir}"/ota_nv_boot_control.conf
	local nv_boot_control_conf=/etc/nv_boot_control.conf

	# Copy utilities for updating bootloader with BUP from "${work_dir}"
	# to /bin/ to check whether bootloader update is successful.
	ota_log "copy_utilities_for_BUP_update ${work_dir}"
	if ! copy_utilities_for_BUP_update "${work_dir}"; then
		ota_log "Failed to run \"copy_utilities_for_BUP_update ${work_dir}\""
		return 1
	fi

	# Copy "${work_dir}/ota_nv_boot_control.conf" to /etc/ on the initrd fs as
	# "nv_update_engine" utility depends on the "/etc/nv_boot_control.conf"
	if [ ! -f "${ota_nv_boot_control_conf}" ]; then
		ota_log "The file ${ota_nv_boot_control_conf} is not found"
		return 1
	fi
	cp "${ota_nv_boot_control_conf}" "${nv_boot_control_conf}"

	# Clean the status of BUP udpate
	"${_NV_UPDATE_ENGINE}" --verify

	# If bootloader update is successful, both slots are marked successful.
	local slots=
	local i=0
	slots=$("${_NVBOOTCTRL}" get-number-slots)
	if [ "${slots}" -le 1 ]; then
		ota_log "Only ${slots} slots exists"
		return 1
	fi

	local i=0
	while [ "$i" -lt 2 ]
	do
		if ! "${_NVBOOTCTRL}" is-slot-marked-successful $i; then
			ota_log "Slot $i is not marked successful"
			return 1
		fi
		i=$((i + 1))
	done
	ota_log "Updating bootloader is successful and continue updating rootfs partition"
	return 0
}

force_booting_to_normal()
{
	# Write "${_KERNEL_BOOTCTRL_NORMAL_FILE}" into "kernel-bootctrl"
	# partition to force booting device to normal kernel
	# Usage
	#     force_booting_to_normal {work_dir}
	local work_dir="${1}"
	local bootctrl_normal_file="${work_dir}/${_KERNEL_BOOTCTRL_NORMAL_FILE}"

	# Get the kernel-bootctrl partition
	local bootctrl_partition=
	get_devnode_from_name "kernel-bootctrl" "${_current_storage_device}" bootctrl_partition
	if [ "${bootctrl_partition}" == "" ] || [ ! -e "${bootctrl_partition}" ]; then
		ota_log "Error: kernel-bootctrl partition is not found"
		return 1
	fi

	# Back up the bootctrl partition
	dd if="${bootctrl_partition}" of="${work_dir}/bootctrl.backup"
	ota_log "Backed up kernel-bootctrl partition under ${work_dir} before writing them"

	# Write bootctrl normal file into bootctrl partition
	ota_log "Writing bootctrl normal file into ${bootctrl_partition}"
	local image_size=
	image_size=$(ls -al "${bootctrl_normal_file}" | cut -d\  -f 5)
	local tmp_image=${work_dir}/image.tmp
	dd if="${bootctrl_normal_file}" of="${bootctrl_partition}" >/dev/null 2>&1
	sync
	ota_log "Read back bootctrl normal file into ${tmp_image} and verify it"
	dd if="${bootctrl_partition}" of="${tmp_image}" bs=1 count="${image_size}" >/dev/null 2>&1
	if ! diff -up "${tmp_image}" "${bootctrl_normal_file}" >/dev/null 2>&1; then
		ota_log "The ${tmp_image} read back does not match ${bootctrl_normal_file}"
		# Write bootctrl normal file into bootctrl partition
		dd if="${bootctrl_normal_file}" of="${bootctrl_partition}" >/dev/null 2>&1
		return 1
	fi
	return 0
}

ota_update_rootfs_in_recovery()
{
	# Update rootfs in recovery kernel/initrd.
	# This function is called in the top script "nv_recovery.sh" and it
	# executes the following steps:
	# 1. Check whether the specified rootfs partition exists
	# 2. Check whether rootfs image exists and it is valid
	# 3. Check whether bootloader is updated with BUP
	#   3a. If yes, continue
	#   3b. If no, go to step 5
	# 4. Check whether bootloader update with BUP is successful
	#   4a. If yes, continue
	#   4b. If no, report error and force booting to normal kernel
	# 5. Run rootfs updater to update rootfs partition
	# 6. Force booting to normal kernel in next boot
	# 7. Update recovery/recovery-dtb partitions
	#
	# Usage
	#     force_booting_to_normal ${rootfs_part} {work_dir}
	local rootfs_part="${1}"
	local work_dir="${2}"
	local system_img_file="${work_dir}/${_ROOTFS_IMAGE_NAME}"
	local rootfs_part_name=

	# Check whether rootfs partition exists
	rootfs_part_name="$(blkid "${rootfs_part}" | grep -oE "PARTLABEL=\"[A-Za-z0-9_\-]+\"" | cut -d= -f 2 | sed 's/^"//' | sed 's/"$//')"
	if [ "${rootfs_part_name}" == "" ]; then
		echo "Faied to get the name of rootfs partition ${rootfs_part}"
		return 1
	fi

	_current_storage_device="$(echo "${rootfs_part}" | sed 's/[0-9][0-9]*$//g')"
	ota_log "_current_storage_device=${_current_storage_device}"

	# Check whether rootfs image exists
	if [ ! -f "${system_img_file}" ]; then
		ota_log "The rootfs image ${system_img_file} is not found"
		return 1
	fi

	# Check whether bootloader is updated with BUP.
	# If yes, need to check whether bootloader update with BUP is successful.
	# If no, update rootfs directly
	ota_log "Check wehther bootloader is updated with BUP"
	ota_log "is_bootloader_updated ${work_dir}"
	if is_bootloader_updated "${work_dir}"; then
		# Check whether bootloader update with BUP is successful
		ota_log "Check whether bootloader update with BUP is successful"
		ota_log "is_bootloader_update_successful ${work_dir}"
		if ! is_bootloader_update_successful "${work_dir}"; then
			# Write kernel-bootctrl partition to boot to normal kernel
			# and do not update rootfs partition if bootloader update is
			# not successful
			ota_log "Error: bootloader update with BUP is not sucessful, booting to normal kernel without updating rootfs partition"
			ota_log "force_booting_to_normal ${work_dir}"
			if ! force_booting_to_normal "${work_dir}"; then
				ota_log "Failed to run \"force_booting_to_normal ${work_dir}\""
			fi
			return 1
		fi
	fi

	# Get ota log file
	local ota_log_file=
	ota_log_file="$(get_ota_log_file)"
	if [ "${ota_log_file}" = "" ] || [ ! -f "${ota_log_file}" ];then
		ota_log "Not get the valid ota log path ${ota_log_file}"
		return 1
	fi
	ota_log "Get ota log file at ${ota_log_file}"

	# Set rootfs updater and update rootfs partition with it
	local rootfs_updater=
	if ! set_rootfs_updater "${work_dir}" rootfs_updater; then
		ota_log "Failed to run \"set_rootfs_updater ${work_dir} rootfs_updater\""
		return 1
	fi
	ota_log "Updating rootfs partition starts at $(date)"
	ota_log "Run source ${rootfs_updater} -p ${rootfs_part} -d ${work_dir} ${system_img_file} 2>&1 | tee -a ${ota_log_file}"
	source "${rootfs_updater}" -p "${rootfs_part}" -d "${work_dir}" "${system_img_file}" 2>&1 | tee -a "${ota_log_file}"
	if [ ! -e "${_ROOTFS_UPDATE_SUCCESS}" ]; then
		ota_log "Error happens when running \"${rootfs_updater} -p ${rootfs_part} -d ${work_dir} ${system_img_file}\""
		return 1
	fi
	ota_log "Updating rootfs partition ends at $(date)"
	sync

	# Write kernel-bootctrl partition to boot to normal kernel
	ota_log "force_booting_to_normal ${work_dir}"
	if ! force_booting_to_normal "${work_dir}"; then
		ota_log "Failed to run \"force_booting_to_normal ${work_dir}\""
		return 1
	fi

	# Update recovery partition with ToT recovery image/dtb
	echo "update_recovery ${work_dir} ${_current_storage_device}"
	if ! update_recovery "${work_dir}" "${_current_storage_device}"; then
		echo "Failed to run \"update_recovery ${work_dir} ${_current_storage_device}\""
		return 1
	fi
	return 0
}

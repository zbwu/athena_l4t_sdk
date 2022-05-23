#!/bin/bash

# Copyright (c) 2020-2021, NVIDIA CORPORATION.  All rights reserved.
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

# This script is used to align the APP partition for upgrading R28.2
# to R32 ToT
_OTA_PACKAGE_SIZE_B=
_OTA_PACKAGE_SIZE_B_FILE="ota_package_size_B"
_RESERVED_SIZE=200     # 200MB
_OTA_R32_TOT_IMAGES="images-R32-ToT"
_OTA_APP_FREE_B_FILE="ota_app_free_B"
_OTA_APP_FREE_B=
_OTA_APP_TOTAL_B_FILE="ota_app_total_B"
_OTA_APP_TOTAL_B=
_OTA_APP_NAME=APP
_OTA_TEMP_NAME=OTA_TEMP
_OTA_WORK_DIR=ota_work

# A new partition "OTA_TEMP" needs to be created to store the
# OTA files originally stored in APP partition as APP partition
# is to be resized during OTA.
# This function check whether there is enough free space to
# create such "OTA_TEMP" partition whose size should be larger
# than the total size of all OTA related files. In addition,
# extra "_RESERSIZE" size is required to store dynamically
# generated files during OTA
ota_check_app_free_space()
{
	local work_dir="$1"
	local app_partition="$2"
	local ota_package_size_B=0
	local app_mnt=
	local ota_item_size_B=

	app_mnt="$(grep -m 1 "${app_partition}" < /proc/mounts | sed -r 's/[\t ]+/ /g' | cut -d\  -f 2)"
	if [ "${app_mnt}" == "" ]; then
		ota_log "APP mount point is not found"
		return 1
	else
		# Get the total size of all ota related files/directories
		du -bs "${app_mnt}"/ota_* >/tmp/du_lines

		while read -r line
		do
			ota_item_size_B=$(echo "${line}" | sed -r 's/[\t ][\t ]*/ /g' | cut -d\  -f 1)
			ota_package_size_B=$((ota_package_size_B + ota_item_size_B))
		done </tmp/du_lines
		if [ "${ota_package_size_B}" == "0" ]; then
			ota_log "Failed to get the total size of ota package"
			return 1
		fi

		# Reserve 200MB to store the logs and intermediate files during ota
		ota_package_size_B=$((ota_package_size_B + _RESERVED_SIZE * 1024 * 1024))
		_OTA_PACKAGE_SIZE_B=${ota_package_size_B}
		echo -n "${_OTA_PACKAGE_SIZE_B}" > "${work_dir}/${_OTA_PACKAGE_SIZE_B_FILE}"
		sync
	fi

	if [ "${app_partition}" == "" ]; then
		ota_log "APP partition is not specified"
		return 1
	fi

	# Store the initial free size and total size of the filesystem
	# on the APP partition into files and then it can be used later
	# as the size of APP partition will be changed during OTA process.
	local app_free_KB=
	local app_free_B=
	local app_total_KB=
	local app_total_B=
	if [ -f "${work_dir}/${_OTA_APP_FREE_B_FILE}" ]; then
		app_free_B=$(cat "${work_dir}/${_OTA_APP_FREE_B_FILE}")
		app_total_B=$(cat "${work_dir}/${_OTA_APP_TOTAL_B_FILE}")
	else
		app_free_KB=$(df | grep "${app_partition}" | sed -r 's/[\t ]+/ /g' | cut -d\  -f 4)
		app_free_B=$((app_free_KB * 1024))
		app_total_KB=$(df | grep "${app_partition}" | sed -r 's/[\t ]+/ /g' | cut -d\  -f 2)
		app_total_B=$((app_total_KB * 1024))
		echo -n "${app_free_B}" >"${work_dir}/${_OTA_APP_FREE_B_FILE}"
		echo -n "${app_total_B}" >"${work_dir}/${_OTA_APP_TOTAL_B_FILE}"
		sync
	fi
	_OTA_APP_FREE_B=${app_free_B}
	_OTA_APP_TOTAL_B=${app_total_B}

	if [ ${app_free_B} -lt ${ota_package_size_B} ]; then
		ota_log "There is no free space in APP partition"
		return 1
	else
		ota_log "APP partition has enough free space"
		return 0
	fi
}

ota_app_get_aligned_offset()
{
	local work_dir="$1"

	local index_file="${work_dir}/${_OTA_R32_TOT_IMAGES}/flash.idx"
	if [ ! -f "${index_file}" ]; then
		ota_log "The index file ${index_file} is not found"
		return 1
	fi

	local app_offset=
	app_offset=$(grep "${_OTA_APP_NAME}" < "${index_file}" | cut -d, -f 3 | sed 's/^ //g')
	if [ "${app_offset}" == "" ]; then
		ota_log "Failed get the offset of APP"
		return 1
	else
		ota_log "echo -n ${app_offset} >${work_dir}/ota_app_new_start"
		echo -n "${app_offset}" >"${work_dir}/ota_app_new_start"
	fi

}

ota_align_app_part()
{
	# 1. e2fsck/resize2fs fs on APP to smaller size
	# 2. resizepart APP partition to smaller size
	# 3. prepare OTA_TEMP
	#    a. mkpart OTA_TEMP partition with the released free space
	#    b. mkfs.ext4 on OTA_TEMP partition
	# 4. copy all the ota files from APP into OTA_TEMP
	# 5. rm the APP partition
	# 6. prepare new APP
	#    a. mkpart new APP partition with aligned start offset
	#    b. mkfs.ext4 on new APP partition
	# 7. copy all the ota files from OTA_TEMP into APP
	# 8. rm the OTA_TEMP partition
	# 9. resizepart APP partition to merge the release space from TEMP partition
	# 10. e2fsck/resizefs fs on APP to the new APP partition size

	source /bin/nv_ota_log.sh
	source /bin/nv_ota_exception_handler.sh

	local app_partition=
	local ota_temp_partition=
	local app_mnt="/tmp/app_mnt"
	local ota_temp_mnt="/tmp/ota_temp_mnt"
	local emmc_device=
	app_partition="$(blkid | grep -m 1 ${_OTA_APP_NAME} | cut -d: -f 1)"
	ota_temp_partition="$(blkid | grep -m 1 ${_OTA_TEMP_NAME} | cut -d: -f 1)"

	mkdir -p "${app_mnt}" "${ota_temp_mnt}"


	# Use a state machine here to handle the process of adjusting APP partition
	# the state is stored into file in case any reboot happens during this procedure.
	# the state starts with "0" and ends with "10"
	local app_mount=0
	local ota_temp_mount=0
	local ota_package_mnt=

	# Try mounting APP partition
	# Return if the APP partition has been aligned
	if [ "${app_partition}" != "" ]; then
		if mount "${app_partition}" "${app_mnt}"; then
			ota_log "mount ${app_partition} ${app_mnt}: Success"
			app_mount=1
			if [ -f "${app_mnt}/ota_app_aligned" ]; then
				# Umount APP partition if it has been aligned
				ota_log "APP partition has been aligned"
				umount "${app_mnt}"
				return 0
			fi
		else
			ota_log "mount ${app_partition} ${app_mnt}: Fail "
		fi
		sync
		ls -al ${app_mnt}
	fi

	# Try mounting OTA_TEMP partition
	# In some states (state=4/5/6), APP partiton can not be mounted or
	# APP partition	does not contain the OTA related files. So the OTA_TEMP
	# needs to be mounted as it contains the OTA related files.
	if [ "${ota_temp_partition}" != "" ]; then
		if mount "${ota_temp_partition}" "${ota_temp_mnt}"; then
			ota_log "mount ${ota_temp_partition} ${ota_temp_mnt}: Success"
			ota_temp_mount=1
		else
			ota_log "mount ${ota_temp_partition} ${ota_temp_mnt}: Fail "
		fi
		sync
		ls -al ${ota_temp_mnt}
	fi

	# In some states (state=3/4/6/7), both APP and OTA_TEMP can be mounted.
	# Check the state stored in the APP and in OTA_TEMP and choose the
	# valid one.
	if [ "${app_mount}" == "1" ] && [ "${ota_temp_mount}" == "1" ]; then
		if [ -f "${app_mnt}/ota_adjust_app_state" ]; then
			app_mnt_state=$(cat "${app_mnt}/ota_adjust_app_state")
		else
			app_mnt_state=""
		fi
		if [ -f "${ota_temp_mnt}/ota_adjust_app_state" ]; then
			ota_temp_mnt_state=$(cat "${ota_temp_mnt}/ota_adjust_app_state")
		else
			ota_temp_mnt_state=""
		fi
		# If both states are valid, use the one in the source partition from
		# which the OTA files are copied, that is:
		# for "state" equals 3 or 4, use ota files on APP partition
		# for "state" equals 6 or 7, use ota files on OTA_TEMP partition
		# If only one state is valid, use the valid one.
		if [ "${app_mnt_state}" != "" ] && [ "${ota_temp_mnt_state}" != "" ]; then
			# For "state" equals 3 or 4, use ota files on APP partition
			# For "state" equals 6 or 7, use ota files on OTA_TEMP partition
			if [ "${app_mnt_state}" == "3" ] || [ "${app_mnt_state}" == "4" ]; then
				ota_package_mnt=${app_mnt}
				emmc_device="$(echo "${app_partition}" | sed -r 's/p[0-9]+$//g')"
			elif [ "${app_mnt_state}" == "6" ] || [ "${app_mnt_state}" == "7" ]; then
				ota_package_mnt=${ota_temp_mnt}
				emmc_device="$(echo "${ota_temp_partition}" | sed -r 's/p[0-9]+$//g')"
			else
				ota_log "Error: invalid ota state ${app_mnt_state}"
				umount "${app_mnt}" "${ota_temp_mnt}"
				return 1
			fi
		elif [ "${app_mnt_state}" != "" ]; then
			ota_package_mnt=${app_mnt}
			emmc_device="$(echo "${app_partition}" | sed -r 's/p[0-9]+$//g')"
		elif [ "${ota_temp_mnt_state}" != "" ]; then
			ota_package_mnt=${ota_temp_mnt}
			emmc_device="$(echo "${ota_temp_partition}" | sed -r 's/p[0-9]+$//g')"
		else
			ota_log "Error: ota state file is not found"
			return 1
		fi
	elif [ "${app_mount}" == "1" ]; then
		ota_package_mnt=${app_mnt}
		emmc_device="$(echo "${app_partition}" | sed -r 's/p[0-9]+$//g')"
	elif [ "${ota_temp_mount}" == "1" ]; then
		ota_package_mnt=${ota_temp_mnt}
		emmc_device="$(echo "${ota_temp_partition}" | sed -r 's/p[0-9]+$//g')"
	else
		ota_log "Failed to get moutable partition"
		return 1
	fi

	local ota_adjust_app_state_file="${ota_package_mnt}/ota_adjust_app_state"
	local ota_adjust_app_state=

	# set the ota adjust app state
	if [ -f "${ota_adjust_app_state_file}" ]; then
		ota_adjust_app_state=$(cat ${ota_adjust_app_state_file})
	else
		ota_adjust_app_state=0
		echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
	fi
	sync

	if [ ${ota_adjust_app_state} -ge 10 ]; then
		if [ "${app_mnt}" == "1" ]; then
			if ! umount "${ota_package_mnt}"; then
				ota_log "Failed to run \"umount ${ota_package_mnt}\""
				return 1
			fi
			sync
		fi
	fi

	local app_log_dir="${ota_package_mnt}/ota_adjust_app_logs"
	local ota_adjust_app_work="${ota_package_mnt}/${_OTA_WORK_DIR}"
	mkdir -p "${app_log_dir}" "${ota_adjust_app_work}"

	set +e
	# initialize log
	ota_log "init_ota_log ${app_log_dir}"
	if ! init_ota_log "${app_log_dir}"; then
		ota_log "Failed to run \"init_ota_log ${app_log_dir}\""
		return 1
	fi
	local ota_log_file=
	ota_log_file="$(get_ota_log_file)"
	ota_log "ota_log_file=${ota_log_file}"

	# initialize exception handler
	ota_log "init_exception_handler ${ota_package_mnt} ${ota_log_file} ${OTA_MAX_RETRY_COUNT}"
	if ! init_exception_handler "${ota_package_mnt}" "${ota_log_file}" "${OTA_MAX_RETRY_COUNT}"; then
		ota_log "Failed to run \"init_exception_handler ${ota_package_mnt} ${ota_log_file} ${OTA_MAX_RETRY_COUNT}\""
		return 1
	fi

	# umount APP and run e2fsck/resize2fs to shrink fs on it
	local app_fs_size_new_B=
	local app_fs_size_new_MB=
	if [ ${ota_adjust_app_state} -lt 1 ]; then
		if ! ota_check_app_free_space ${ota_adjust_app_work} "${app_partition}"; then
			ota_log "Failed to run \"ota_check_app_free_space ${ota_adjust_app_work} ${app_partition}\""
			return 1
		fi

		source "${ota_adjust_app_work}"/nv_ota_preserve_data.sh

		# backup specified files
		echo "ota_backup_customer_files ${ota_adjust_app_work} ${ota_package_mnt}"
		if ! ota_backup_customer_files "${ota_adjust_app_work}" "${ota_package_mnt}"; then
			echo "Failed to run \"ota_backup_customer_files ${ota_adjust_app_work} ${ota_package_mnt}\""
			return 1
		fi
		sync

		app_fs_size_new_B=$((_OTA_APP_TOTAL_B - _OTA_PACKAGE_SIZE_B))
		app_fs_size_new_MB=$((app_fs_size_new_B / 1024 / 1024))
		if ! umount "${ota_package_mnt}"; then
			ota_log "Failed to run \"umount ${ota_package_mnt}\""
			return 1
		fi
		sync
		if ! e2fsck -fy "${app_partition}"; then
			ota_log "Failed to run \"e2fsck -fy ${app_partition}\""
			return 1
		fi
		sync
		if ! resize2fs -f "${app_partition}" "${app_fs_size_new_MB}M"; then
			ota_log "Failed to run \"resize2fs -f ${app_partition} ${app_fs_size_new_MB}\""
			return 1
		fi
		sync
		if ! mount "${app_partition}" "${ota_package_mnt}"; then
			ota_log "Failed to run \"mount ${app_partition} ${ota_package_mnt}\""
			return 1
		fi
		sync
		ota_adjust_app_state=1
		ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
		echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
		sync
	fi

	# resize the APP partition to smaller size
	local app_end_B=
	local app_end_new_B=
	local app_end_stored_B=
	local app_num=
	if [ ${ota_adjust_app_state} -lt 2 ]; then
		app_end_B=$(parted "${emmc_device}" unit "B" print | grep -m 1 ${_OTA_APP_NAME} | sed 's/^[ ]*//g' | sed 's/[ ][ ]*/ /g' | cut -d\  -f 3 | sed 's/B$//g')
		if [ -f "${ota_adjust_app_work}/ota_app_end_old" ]; then
			app_end_stored_B=$(cat "${ota_adjust_app_work}/ota_app_end_old")
		else
			app_end_stored_B=${app_end_B}
			echo -n "${app_end_stored_B}" >"${ota_adjust_app_work}/ota_app_end_old"
		fi
		app_num=$(parted "${emmc_device}" unit "B" print | grep -m 1 ${_OTA_APP_NAME} | sed 's/^[ ]*//g' | sed 's/[ ][ ]*/ /g' | cut -d\  -f 1)
		if [ "${_OTA_PACKAGE_SIZE_B}" == "" ]; then
			if [ -f "${ota_adjust_app_work}/${_OTA_PACKAGE_SIZE_B_FILE}" ]; then
				_OTA_PACKAGE_SIZE_B=$(cat "${ota_adjust_app_work}/${_OTA_PACKAGE_SIZE_B_FILE}")
			else
				ota_log "The file ${ota_adjust_app_work}/${_OTA_PACKAGE_SIZE_B_FILE} is not found "
				return 1
			fi
		fi

		# shrink the APP partition if
		if [ "${app_end_B}" == "${app_end_stored_B}" ]; then
			app_end_new_B=$((app_end_B - _OTA_PACKAGE_SIZE_B))
			app_end_new_B=$((app_end_new_B / 512 * 512 - 1))
			if ! umount "${ota_package_mnt}"; then
				ota_log "Failed to run \"umount ${ota_package_mnt}\""
				return 1
			fi
			sync
			if ! parted "${emmc_device}" unit "B" resizepart "${app_num}" Yes "${app_end_new_B}" Yes; then
				ota_log "Failed to run \"parted ${emmc_device} unit B resizepart ${app_num} Yes ${app_end_new_B}B Yes\""
				return 1
			fi
			sync
			if ! mount "${app_partition}" "${ota_package_mnt}"; then
				ota_log "Failed to run \"mount ${app_partition} ${ota_package_mnt}\""
				return 1
			fi
			sync
		fi
		ota_adjust_app_state=2
		ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
		echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
		sync
	fi

	# delete SOS_b partition if it exists as the new partition can not be
	# created unless at least one exiting partition is deleted
	local sos_b_num=
	local sos_b_dev=
	sos_b_num=$(parted "${emmc_device}" unit "B" print | grep -m 1 "SOS_b" | sed 's/^[ ]*//g' | sed 's/[ ][ ]*/ /g' | cut -d\  -f 1)
	sos_b_dev=$(blkid "${emmc_device}p${sos_b_num}" | cut -d: -f 1)
	if [ "${sos_b_num}" != "" ]; then
		dd if=/dev/zero of="${sos_b_dev}" bs=1M count=100
		if ! parted "${emmc_device}" rm "${sos_b_num}"; then
			ota_log "Failed to run \"parted ${emmc_device} rm ${sos_b_num}\""
			return 1
		fi
		sync
		parted "${emmc_device}" unit B print free
	fi

	# create the OTA_TEMP partition and formatting it
	local ota_temp_start_B=
	local ota_temp_end_B=
	local ota_temp_num=
	if [ ${ota_adjust_app_state} -lt 3 ]; then
		ota_temp_num=$(parted "${emmc_device}" unit "B" print | grep -m 1 ${_OTA_TEMP_NAME} | sed 's/^[ ]*//g' | sed 's/[ ][ ]*/ /g' | cut -d\  -f 1)
		if [ "${ota_temp_num}" == "" ]; then
			# get end offset of the shrinked APP partition
			if [ "${app_end_new_B}" == "" ]; then
				app_end_new_B=$(parted "${emmc_device}" unit "B" print | grep -m 1 ${_OTA_APP_NAME} | sed 's/^[ ]*//g' | sed 's/[ ][ ]*/ /g' | cut -d\  -f 3 | sed 's/B$//g')
				if [ ! -f "${ota_adjust_app_work}/ota_app_end_old" ]; then
					ota_log "The file ${ota_adjust_app_work}/ota_app_end_old is not found"
					return 1
				else
					app_end_B=$(cat ${ota_adjust_app_work}/ota_app_end_old)
				fi
			fi
			ota_temp_start_B=$((app_end_new_B + 1))
			ota_temp_end_B=${app_end_B}

			if ! parted -s "${emmc_device}" unit "B" mkpart "${_OTA_TEMP_NAME}" "${ota_temp_start_B}" "${ota_temp_end_B}"; then
				ota_log "Failed to run \"parted ${emmc_device} unit B mkpart ${_OTA_TEMP_NAME} ${ota_temp_start_B} ${ota_temp_end_B}\""
				return 1
			fi
			sync

			ota_temp_num=$(parted "${emmc_device}" unit "B" print | grep -m 1 ${_OTA_TEMP_NAME} | sed 's/^[ ]*//g' | sed 's/[ ][ ]*/ /g' | cut -d\  -f 1)

			parted "${emmc_device}" unit B print free
		fi
		ota_temp_partition="${emmc_device}p${ota_temp_num}"
		if ! mkfs.ext4 -F "${ota_temp_partition}"; then
			ota_log "Failed to run \"mkfs.ext4 ${ota_temp_partition}\""
			return 1
		fi
		sync
		ota_adjust_app_state=3
		ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
		echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
		sync
	fi

	# mount OTA_TEMP and copy all ota files from APP into OTA_TEMP
	local tmp_mnt=
	if [ ${ota_adjust_app_state} -lt 4 ]; then
		tmp_mnt="${ota_temp_mnt}"
		if [ "${ota_temp_mount}" == "0" ]; then
			if ! mount "${ota_temp_partition}" "${tmp_mnt}"; then
				ota_log "Failed to run \"mount ${ota_temp_partition} ${tmp_mnt}\""
				return 1
			fi
			ota_temp_mount=1
			sync
		fi
		if ! find "${ota_package_mnt}" -maxdepth 1 -name "ota_*" -a ! -name "ota_payload_package.tar.gz" -exec cp -vR "{}" "${tmp_mnt}/" \;; then
			ota_log "Failed to run \"find ${ota_package_mnt} -maxdepth 1 -name \"ota_*\" -a ! -name \"ota_payload_package.tar.gz\" -exec cp -vR {} ${tmp_mnt}/ \;"
			return 1
		fi
		sync

		ota_adjust_app_state=4
		ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
		echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
		sync
	fi

	# umount APP partition if it is mounted and then delete APP partition
	if [ ${ota_adjust_app_state} -lt 5 ]; then
		parted "${emmc_device}" unit B print free
		sync

		if [ ${app_mount} == "1" ]; then
			if ! umount "${ota_package_mnt}"; then
				ota_log "Failed to run \"umount ${ota_package_mnt}\""
				return 1
			fi
			sync

			tmp_mnt=${ota_temp_mnt}
			if ! umount "${tmp_mnt}"; then
				ota_log "Failed to run \"umount ${tmp_mnt}\""
				return 1
			fi
			sync

			# mount OTA_TEMP on "ota_package_mnt"
			if ! mount "${ota_temp_partition}" "${ota_package_mnt}"; then
				ota_log "Failed to run \"mount ${ota_temp_partition} ${ota_package_mnt}\""
				return 1
			fi
			sync

			ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
			echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
			sync
		fi

		app_num=$(parted "${emmc_device}" unit "B" print | grep -m 1 ${_OTA_APP_NAME} | sed 's/^[ ]*//g' | sed 's/[ ][ ]*/ /g' | cut -d\  -f 1)
		if [ "${app_num}" != "" ]; then
			# corrupt the APP partition before delete it
			dd if=/dev/zero of="${app_partition}" bs=1M count=200
			sync

			if ! parted "${emmc_device}" rm "${app_num}" Yes; then
				ota_log "Failed to run \"parted ${emmc_device} rm ${app_num}\""
				return 1
			fi
			sync
			app_partition=""
			app_mount=0
		fi
		ota_adjust_app_state=5
		ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
		echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
		sync
	fi

	# create new APP partition
	local app_new_start_B=
	if [ ${ota_adjust_app_state} -lt 6 ]; then
		if [ ! -f "${ota_adjust_app_work}/ota_app_new_start" ]; then
			ota_app_get_aligned_offset "${ota_adjust_app_work}"
		fi
		app_new_start_B=$(cat ${ota_adjust_app_work}/ota_app_new_start)
		if [ "${ota_temp_start_B}" == "" ]; then
			ota_temp_start_B=$(parted "${emmc_device}" unit "B" print | grep -m 1 ${_OTA_TEMP_NAME} | sed 's/^[ ]*//g' | sed 's/[ ][ ]*/ /g' | cut -d\  -f 2 | sed 's/B$//g')
		fi
		app_end_new_B=$((ota_temp_start_B - 1))
		if [ "${app_partition}" == "" ]; then
			if ! parted -s "${emmc_device}" unit "B" mkpart "${_OTA_APP_NAME}" "${app_new_start_B}" "${app_end_new_B}"; then
				ota_log "Failed to run \"parted -s ${emmc_device} unit B mkpart APP ${app_new_start_B} ${app_end_new_B}\""
				return 1
			fi
			sync
		fi

		app_partition=$(blkid | grep -m 1 ${_OTA_APP_NAME} | cut -d: -f 1)
		if [ "${app_mount}" == "0" ]; then
			if ! mkfs.ext4 -F "${app_partition}"; then
				ota_log "Failed to run \"mkfs.ext4 -F ${app_partition}\""
				return 1
			fi
			sync
		fi

		parted "${emmc_device}" unit B print free
		sync

		ota_adjust_app_state=6
		ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
		echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
		sync
	fi

	# copy ota files from OTA_TEMP into the new APP partition
	if [ ${ota_adjust_app_state} -lt 7 ]; then
		if [ "${ota_package_mnt}" == "${ota_temp_mnt}" ]; then
			tmp_mnt="${app_mnt}"
		else
			tmp_mnt="${ota_temp_mnt}"
		fi
		if [ "${app_mount}" == "0" ]; then
			if ! mount "${app_partition}" "${tmp_mnt}"; then
				ota_log "Failed to run \"mount ${app_partition} ${tmp_mnt}\""
				return 1
			fi
			app_mount=1
			sync
		fi
		if ! find "${ota_package_mnt}" -maxdepth 1 -name "ota_*" -a ! -name "ota_payload_package.tar.gz" -exec cp -vR "{}" "${tmp_mnt}/" \;; then
			ota_log "Failed to run \"find ${ota_package_mnt} -maxdepth 1 -name \"ota_*\" -a ! -name \"ota_payload_package.tar.gz\" -exec cp -vR {} ${tmp_mnt}/ \;"
			return 1
		fi
		sync

		ota_adjust_app_state=7
		ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
		echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
		sync
	fi

	# umount OTA_TEMP partition if it is mounted and then delete OTA_TEMP partition
	if [ ${ota_adjust_app_state} -lt 8 ]; then
		parted "${emmc_device}" unit B print free
		sync

		if [ ${ota_temp_mount} == "1" ]; then
			if ! umount "${ota_package_mnt}"; then
				ota_log "Failed to run \"umount ${ota_package_mnt}\""
				return 1
			fi
			sync

			if [ "${ota_package_mnt}" == "${ota_temp_mnt}" ]; then
				tmp_mnt="${app_mnt}"
			else
				tmp_mnt="${ota_temp_mnt}"
			fi
			if ! umount "${tmp_mnt}"; then
				ota_log "Failed to run \"umount ${app_mnt}\""
				return 1
			fi
			sync

			# mount APP on "ota_package_mnt"
			if ! mount "${app_partition}" "${ota_package_mnt}"; then
				ota_log "Failed to run \"mount ${app_partition} ${ota_package_mnt}\""
				return 1
			fi
			ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
			echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
			sync
		fi

		ota_temp_num=$(parted "${emmc_device}" unit "B" print | grep -m 1 ${_OTA_TEMP_NAME} | sed 's/^[ ]*//g' | sed 's/[ ][ ]*/ /g' | cut -d\  -f 1)
		if [ "${ota_temp_num}" != "" ]; then
			# corrupt the OTA_TEMP partition before delete it
			dd if=/dev/zero of="${ota_temp_partition}" bs=1M count=200
			sync

			if ! parted "${emmc_device}" rm "${ota_temp_num}" Yes; then
				ota_log "Failed to run \"parted ${emmc_device} rm ${ota_temp_num}\""
				return 1
			fi
			sync
			ota_temp_partition=""
			ota_temp_mount=0
		fi
		ota_adjust_app_state=8
		ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
		echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
		sync
	fi

	# resizepart APP partition to merge the release space from TEMP partition
	if [ ${ota_adjust_app_state} -lt 9 ]; then
		if [ ! -f "${ota_adjust_app_work}/ota_app_end_old" ]; then
			ota_log "The file ${ota_adjust_app_work}/ota_app_end_old is not found"
			return 1
		fi
		app_end_new_B=$(cat ${ota_adjust_app_work}/ota_app_end_old)
		temp_end_B=$(parted "${emmc_device}" unit "B" print | grep -m 1 ${_OTA_APP_NAME} | sed 's/^[ ]*//g' | sed 's/[ ][ ]*/ /g' | cut -d\  -f 3 | sed 's/B$//g')
		app_num=$(parted "${emmc_device}" unit "B" print | grep -m 1 ${_OTA_APP_NAME} | sed 's/^[ ]*//g' | sed 's/[ ][ ]*/ /g' | cut -d\  -f 1)
		if [ "${app_end_new_B}" != "${temp_end_B}" ]; then
			if ! parted "${emmc_device}" unit "B" resizepart "${app_num}" Yes "${app_end_new_B}"; then
				ota_log "Failed to run \"parted ${emmc_device} unit B resizepart ${app_num} Yes ${app_end_new_B}\""
				return 1
			fi
		fi
		sync
		ota_adjust_app_state=9
		ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
		echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
		sync
	fi

	if [ ${ota_adjust_app_state} -lt 10 ]; then
		if ! umount "${ota_package_mnt}"; then
			ota_log "Failed to run \"umount ${ota_package_mnt}\""
			return 1
		fi
		sync
		if ! e2fsck -fy "${app_partition}"; then
			ota_log "Failed to run \"e2fsck -fy ${app_partition}\""
			return 1
		fi
		sync
		if ! resize2fs -f "${app_partition}"; then
			ota_log "Failed to run \"resize2fs -f ${app_partition}\""
			return 1
		fi
		sync

		if ! mount "${app_partition}" "${ota_package_mnt}"; then
			ota_log "Failed to run \"mount ${app_partition} ${ota_package_mnt}\""
			return 1
		fi
		sync

		ota_adjust_app_state=10
		ota_log "echo -n ${ota_adjust_app_state} >${ota_adjust_app_state_file}"
		echo -n "${ota_adjust_app_state}" >"${ota_adjust_app_state_file}"
		sync

		# mark APP partition is aligned
		echo -n "1" >"${ota_package_mnt}/ota_app_aligned"
		sync

		if ! umount "${ota_package_mnt}"; then
			ota_log "Failed to run \"umount ${ota_package_mnt}\""
			return 1
		fi
	fi

	set -e
	return 0
}

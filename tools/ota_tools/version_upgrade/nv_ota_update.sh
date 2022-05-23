#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2021 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: MIT
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
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
# DEALINGS IN THE SOFTWARE.

source /bin/nv_ota_common.func

source "${OTA_WORK_DIR}"/nv_ota_customer.conf

base_version=
if ! get_base_version_in_recovery base_version; then
	ota_log "Failed to \"get_base_version\""
	exit 1
fi

target_board=
if ! get_target_board_in_recovery target_board; then
	ota_log "Failed to \"get_target_board\""
	exit 1
fi

layout_change=
if ! get_layout_change_in_recovery layout_change; then
	ota_log "Failed to \"get_layout_change\""
	exit 1
fi

# If layout is not changed, invoke ota_update_rootfs_in_recovery() which checks
# whether bootloader update with BUP is successful if needed and updates rootfs
# partition via the rootfs updater.
# If layout is changed, invoke ota_update_all_in_recovery() to start the update
# for all partitions listed in the control file.
if [ "${layout_change}" == 0 ]; then
	source "${OTA_WORK_DIR}"/nv_ota_update_rootfs_in_recovery.sh

	rootfs_part=
	if ! load_variable "rootfs_part" rootfs_part; then
		ota_log "Failed to load variable \"rootfs_part\""
		exit 1
	fi

	ota_log "ota_update_rootfs_in_recovery ${rootfs_part} ${OTA_WORK_DIR}"
	if ! ota_update_rootfs_in_recovery "${rootfs_part}" "${OTA_WORK_DIR}"; then
		ota_log "Failed to run \"ota_update_rootfs_in_recovery ${rootfs_part} ${OTA_WORK_DIR}\""
		exit 1
	fi
else
	source "${OTA_WORK_DIR}"/nv_ota_check_version.sh
	source "${OTA_WORK_DIR}"/nv_ota_update_all_in_recovery.sh

	ota_log "ota_check_rollback ${OTA_WORK_DIR} ${target_board} ${base_version}"
	if ! ota_check_rollback "${OTA_WORK_DIR}" "${target_board}" "${base_version}"; then
		ota_log "Failed to run \"ota_check_rollback ${OTA_WORK_DIR} ${target_board} ${base_version}\""
		exit 1
	fi

	ota_log "ota_update_all_in_recovery ${OTA_WORK_DIR}"
	if ! ota_update_all_in_recovery "${OTA_WORK_DIR}"; then
		ota_log "Failed to run \"ota_update_all_in_recovery ${OTA_WORK_DIR}\""
		exit 1
	fi
fi

#!/bin/bash

# Copyright (c) 2020-2021, NVIDIA CORPORATION.  All rights reserved.
#
# NVIDIA CORPORATION and its licensors retain all intellectual property
# and proprietary rights in and to this software, related documentation
# and any modifications thereto.  Any use, reproduction, disclosure or
# distribution of this software and related documentation without an express
# license agreement from NVIDIA CORPORATION is strictly prohibited.

# This script generates factory images for jetson-xavier-nx-qspi sku 0 & 1

set -e

L4T_TOOLS_DIR="$(cd $(dirname "$0") && pwd)"
LINUX_BASE_DIR="${L4T_TOOLS_DIR%/*}"
BOOTLOADER_DIR="${LINUX_BASE_DIR}/bootloader"
SIGNED_IMAGES_DIR="${BOOTLOADER_DIR}/signed"
SYSTEM_IMAGE_RAW_FILE="${BOOTLOADER_DIR}/system.img.raw"
FLASH_INDEX_FILE="${SIGNED_IMAGES_DIR}/flash.idx"
SPI_FLASH_SIZE=33554432
K_BYTES=1024
SPI_IMAGE_NAME=""
BOARD_NAME=""

function usage()
{
	echo -e "
Usage: [env={value},...] $0 [-u <keyfile>] [-b <board>]
Where,
	-u <keyfile>	Indicate the key file used to sign these images.The default zero key
			will be used if not enabling this option
	-b <board>	Indicate to only generate QSPI image for this board. You can directly
			use one of the following boards:
			\"jetson-xavier-nx-qspi-sd-evt\", \"jetson-xavier-nx-qspi-emmc-evt\",
			\"jetson-xavier-nx-qspi-sd-dvt\", \"jetson-xavier-nx-qspi-emmc-dvt\"
			If other <board> is provided, the correct env variants for this <board>
			must be set.
			All QSPI images for these supported 4 boards will be generated if not
			enabling this option.

	The following env variant can be used to modify some parameters for the specified board:
	\"BOARDID\", \"FAB\", \"BOARDSKU\", \"BOARDREV\", \"FUSELEVEL\", \"CHIPREV\"

Example:
	1. Generate QSPI image signed by \"rsa_key.pem\" for DVT board SKU 0
		sudo $0 -u rsa_key.pem -b jetson-xavier-nx-qspi-sd-dvt
	2. Generate QSPI image with FAB=200 for DVT board SKU 1
		sudo FAB=200 $0 -b jetson-xavier-nx-qspi-emmc-dvt
	3. Generate QSPI image for XXX board
		sudo BOARDID=XXXX FAB=XXX BOARDSKU=XXXX BOARDREV=X.X FUSELEVEL=fuselevel_production CHIPREV=2 $0 -b XXX
	"; echo;
	exit 1
}

function sha1_verify()
{
	local file_image="${1}"
	local sha1_chksum="${2}"

	if [ -z "${sha1_chksum}" ];then
		echo "Error: passed-in sha1 checksum is NULL"
		return 1
	fi

	if [ ! -f "${file_image}" ];then
		echo "Error: $file_image is not found !!!"
		return 1
	fi

	local sha1_chksum_gen=$(sha1sum "${file_image}" | cut -d\  -f 1)
	if [ "${sha1_chksum_gen}" = "${sha1_chksum}" ];then
		echo "sha1 checksum matched for ${file_image}"
		return 0
	else
		echo "Error: sha1 checksum does not match (${sha1_chksum_gen} != ${sha1_chksum}) for ${file_image}"
		return 1
	fi
}

function rw_part_opt()
{
	local infile="${1}"
	local outfile="${2}"
	local inoffset="${3}"
	local outoffset="${4}"
	local size="${5}"

	if [ ! -e "${infile}" ];then
		echo "Error: input file ${infile} is not found"
		return 1
	fi

	if [ ${size} -eq 0 ];then
		echo "Error: the size of bytes to be read is ${size}"
		return 1
	fi

	local inoffset_align_K=$((${inoffset} % ${K_BYTES}))
	local outoffset_align_K=$((${outoffset} % ${K_BYTES}))
	if [ ${inoffset_align_K} -ne 0 ] || [ ${outoffset_align_K} -ne 0 ];then
		echo "Offset is not aligned to K Bytes, no optimization is applied"
		echo "dd if=${infile} of=${outfile} bs=1 skip=${inoffset} seek=${outoffset} count=${size}"
		dd if="${infile}" of="${outfile}" bs=1 skip=${inoffset} seek=${outoffset} count=${size}
		return 0
	fi

	local block=$((${size} / ${K_BYTES}))
	local remainder=$((${size} % ${K_BYTES}))
	local inoffset_blk=$((${inoffset} / ${K_BYTES}))
	local outoffset_blk=$((${outoffset} / ${K_BYTES}))

	echo "${size} bytes from ${infile} to ${outfile}: 1KB block=${block} remainder=${remainder}"

	if [ ${block} -gt 0 ];then
		echo "dd if=${infile} of=${outfile} bs=1K skip=${inoffset_blk} seek=${outoffset_blk} count=${block}"
		dd if="${infile}" of="${outfile}" bs=1K skip=${inoffset_blk} seek=${outoffset_blk} count=${block} conv=notrunc
		sync
	fi
	if [ ${remainder} -gt 0 ];then
		local block_size=$((${block} * ${K_BYTES}))
		local outoffset_rem=$((${outoffset} + ${block_size}))
		local inoffset_rem=$((${inoffset} + ${block_size}))
		echo "dd if=${infile} of=${outfile} bs=1 skip=${inoffset_rem} seek=${outoffset_rem} count=${remainder}"
		dd if="${infile}" of="${outfile}" bs=1 skip=${inoffset_rem} seek=${outoffset_rem} count=${remainder} conv=notrunc
		sync
	fi
	return 0
}

function generate_binaries()
{
	local spec="${1}"
	local signed_dir=""

	# remove existing signed images
	if [ -d "${SIGNED_IMAGES_DIR}" ];then
		rm -Rf "${SIGNED_IMAGES_DIR}/*"
	fi

	SPI_IMAGE_NAME=""
	eval "${spec}"

	if [[ "${board}" =~ "jetson-xavier-nx-qspi-sd" ]];then
		board_internal="jetson-xavier-nx-devkit"
	elif [[ "${board}" =~ "jetson-xavier-nx-qspi-emmc" ]];then
		board_internal="jetson-xavier-nx-devkit-emmc"
	else
		echo "Unlisted board ${board}"
		board_internal=${board}
	fi

	board_arg=""
	if [ "${FUSELEVEL}" = "" ];then
		if [ "${fuselevel_s}" = "0" ]; then
			fuselevel="fuselevel_nofuse";
		else
			fuselevel="fuselevel_production";
		fi
		board_arg+="FUSELEVEL=${fuselevel} "
	else
		board_arg+="FUSELEVEL=${FUSELEVEL} "
	fi

	if [ "${BOARDID}" = "" ];then
		board_arg+="BOARDID=${boardid} "
	else
		board_arg+="BOARDID=${BOARDID} "
	fi

	if [ "${FAB}" = "" ];then
		board_arg+="FAB=${fab} "
	else
		board_arg+="FAB=${FAB} "
	fi

	if [ "${BOARDSKU}" = "" ];then
		board_arg+="BOARDSKU=${boardsku} "
	else
		board_arg+="BOARDSKU=${BOARDSKU} "
	fi

	if [ "${BOARDREV}" = "" ];then
		board_arg+="BOARDREV=${boardrev} "
	else
		board_arg+="BOARDREV=${BOARDREV} "
	fi

	if [ "${CHIPREV}" = "" ];then
		board_arg+="CHIPREV=${chiprev}"
	else
		board_arg+="CHIPREV=${CHIPREV}"
	fi

	echo "Generating binaries for board spec: ${board_arg}"

	cmd_arg="--no-flash --sign "
	if [ "${KEY_FILE}" != "" ] && [ -f "${KEY_FILE}" ];then
		cmd_arg+="-u \"${KEY_FILE}\" "
	fi
	# if system.img exist, doesn't need to generate it anymore.
	if [ -f "${SYSTEM_IMAGE_RAW_FILE}" ]; then
		sysimg="--no-systemimg"
	else
		sysimg=""
	fi
	cmd_arg+="${sysimg} "
	cmd_arg+="${board_internal} ${rootdev}"
	cmd="${board_arg} ${LINUX_BASE_DIR}/flash.sh ${cmd_arg}"

	echo -e "${cmd}\r\n"
	eval "${cmd}"

	SPI_IMAGE_NAME="${board}.spi.img"
}

function fill_partition_image()
{
	local item="${1}"
	local spi_image="${2}"
	local part_name=$(echo "${item}" | cut -d, -f 2 | sed 's/^ //g' - | cut -d: -f 3)
	local file_name=$(echo "${item}" | cut -d, -f 5 | sed 's/^ //g' -)
	local start_offset=$(echo "${item}" | cut -d, -f 3 | sed 's/^ //g' -)
	local file_size=$(echo "${item}" | cut -d, -f 6 | sed 's/^ //g' -)
	local sha1_chksum=$(echo "${item}" | cut -d, -f 8 | sed 's/^ //g' -)

	if [ "${file_name}" = "" ];then
		echo "Warning: skip writing ${part_name} partition as no image is specified"
		return 0
	fi

	echo "Writing ${file_name} (parittion: ${part_name}) into ${spi_image}"

	# Try searching image in the "SIGNED_IMAGES_DIR" directory and
	# then in "BOOTLOADER_DIR" directory
	local part_image_file="${SIGNED_IMAGES_DIR}/${file_name}"
	if [ ! -f "${part_image_file}" ];then
		part_image_file="${BOOTLOADER_DIR}/${file_name}"
		if [ ! -f "${part_image_file}" ];then
			echo "Error: image for partition ${part_name} is not found at ${part_image_file}"
			return 1
		fi
	fi

	sha1_verify "${part_image_file}" "${sha1_chksum}"

	echo "Writing ${part_image_file} (${file_size} bytes) into ${spi_image}:${start_offset}"
	rw_part_opt "${part_image_file}" "${spi_image}" 0 "${start_offset}" "${file_size}"

	# Write BCT redundancy
	# BCT image should be written in multiple places: (Block 0, Slot 0), (Block 0, Slot 1) and (Block 1, Slot 0)
	# In this case, block size is 32KB and the slot size is 4KB, so the BCT image should be written at the place
	# where offset is 4096 and 32768
	if [ "${part_name}" = "BCT" ];then
		# Block 0, Slot 1
		start_offset=4096
		echo "Writing ${part_image_file} (${file_size} bytes) into ${spi_image}:${start_offset}"
		rw_part_opt "${part_image_file}" "${spi_image}" 0 "${start_offset}" "${file_size}"

		# Block 1, Slot 0
		start_offset=32768
		echo "Writing ${part_image_file} (${file_size} bytes) into ${spi_image}:${start_offset}"
		rw_part_opt "${part_image_file}" "${spi_image}" 0 "${start_offset}" "${file_size}"
	fi
}

function generate_spi_image()
{
	local image_name="${1}"
	local image_file="${BOOTLOADER_DIR}/${image_name}"

	if [ ! -f "${FLASH_INDEX_FILE}" ];then
		echo "Error: ${FLASH_INDEX_FILE} is not found"
		return 1
	fi

	# create a zero spi image
	dd if=/dev/zero of="${image_file}" bs=1M count=32

	readarray index_array < "${FLASH_INDEX_FILE}"
	echo "Flash index file is ${FLASH_INDEX_FILE}"

	lines_num=${#index_array[@]}
	echo "Number of lines is $lines_num"

	max_index=$((lines_num - 1))
	echo "max_index=${max_index}"

	for i in $(seq 0 ${max_index})
	do
		local item="${index_array[$i]}"

		# break if device type is SDMMC(1) as only generating image for SPI flash(3)
		local device_type=$(echo "${item}" | cut -d, -f 2 | sed 's/^ //g' - | cut -d: -f 1)
		if [ "${device_type}" != 3 ];then
			echo "Reach the end of the SPI device"
			break
		fi

		# fill the partition image into the SPI image
		fill_partition_image "${item}" "${image_file}"
	done

	echo "Generated image for SPI at ${image_file}"
	return 0
}

jetson_xavier_nx_qspi=(
	# jetson-xavier-nx EVT boards
	'boardid=3668;fab=000;boardsku=0000;boardrev=F.0;fuselevel_s=1;chiprev=2;board=jetson-xavier-nx-qspi-sd-evt;rootdev=mmcblk0p1'
	'boardid=3668;fab=000;boardsku=0001;boardrev=F.0;fuselevel_s=1;chiprev=2;board=jetson-xavier-nx-qspi-emmc-evt;rootdev=mmcblk0p1'

	# jetson-xavier-nx DVT boards
	'boardid=3668;fab=100;boardsku=0000;boardrev=E.0;fuselevel_s=1;chiprev=2;board=jetson-xavier-nx-qspi-sd-dvt;rootdev=mmcblk0p1'
	'boardid=3668;fab=100;boardsku=0001;boardrev=E.0;fuselevel_s=1;chiprev=2;board=jetson-xavier-nx-qspi-emmc-dvt;rootdev=mmcblk0p1'
)

opstr+="u:b:"
while getopts "${opstr}" OPTION; do
	case $OPTION in
	u) KEY_FILE=${OPTARG}; ;;
	b) BOARD_NAME=${OPTARG}; ;;
	*)
	   usage
	   ;;
	esac;
done

if [ ! -f "${LINUX_BASE_DIR}/flash.sh" ];then
	echo "Error: ${LINUX_BASE_DIR}/flash.sh is not found"
	exit 1
fi

# Generate spi image for one or all listed board(s)
generated=0
pushd "${LINUX_BASE_DIR}" > /dev/null 2>&1
for spec in "${jetson_xavier_nx_qspi[@]}"; do
	eval "${spec}"
	if [ "${BOARD_NAME}" != "" ] && [ "${BOARD_NAME}" != "${board}" ];then
		continue
	fi
	generate_binaries "${spec}"
	if [ $? -ne 0 ];then
		echo "Error: failed to generate binaries for board ${board}"
		exit 1
	fi

	if [ "${SPI_IMAGE_NAME}" = "" ];then
		echo "Error: SPI image name is NULL"
		exit 1
	fi

	echo "Generating SPI image \"${SPI_IMAGE_NAME}\""
	generate_spi_image "${SPI_IMAGE_NAME}"
	if [ $? -ne 0 ];then
		echo "Error: failed to generate SPI image \"${SPI_IMAGE_NAME}\""
		exit 1
	fi
	generated=1
done

# Generated spi image for unlisted board
if [ "${BOARD_NAME}" != "" ] && [ "${generated}" = "0" ];then
	echo "Check env variants for unlisted board ${BOARD_NAME}"
	if [ "${BOARDID}" = "" ];then
		echo "Error: invalid BOARDID=${BOARDID}"
		usage
	fi

	if [ "${FAB}" = "" ];then
		echo "Error: invalid FAB=${FAB}"
		usage
	fi

	if [ "${BOARDSKU}" = "" ];then
		echo "Error: invalid BOARDSKU=${BOARDSKU}"
		usage
	fi

	if [ "${BOARDREV}" = "" ];then
		echo "Error: invalid BOARDREV=${BOARDREV}"
		usage
	fi

	if [ "${CHIPREV}" = "" ];then
		echo "Error: invalid CHIPREV=${CHIPREV}"
		usage
	fi

	if [ "${FUSELEVEL}" != "fuselevel_nofuse" ] && \
		[ "${FUSELEVEL}" != "fuselevel_production" ] || \
		[ "${FUSELEVEL}" = "" ];then
		echo "Error: invalid FUSELEVEL=${FUSELEVEL}"
		usage
	fi

	spec="boardid=${BOARDID};fab=${FAB};boardsku=${BOARDSKU};boardrev=${BOARDREV};fuselevel_s=${FUSELEVEL};chiprev=${CHIPREV};board=${BOARD_NAME};rootdev=mmcblk0p1"
	generate_binaries "${spec}"
	if [ $? -ne 0 ];then
		echo "Error: failed to generate binaries for board ${BOARD_NAME}"
		exit 1
	fi

	if [ "${SPI_IMAGE_NAME}" = "" ];then
		echo "Error: SPI image name is NULL"
		exit 1
	fi

	echo "Generating SPI image \"${SPI_IMAGE_NAME}\""
	generate_spi_image "${SPI_IMAGE_NAME}"
	if [ $? -ne 0 ];then
		echo "Error: failed to generate SPI image \"${SPI_IMAGE_NAME}\""
		exit 1
	fi
fi

popd > /dev/null 2>&1

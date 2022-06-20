#!/bin/bash

SCRIPT=$(realpath ${BASH_SOURCE[0]})
SOURCE=$(dirname $SCRIPT)
LINUX_FOR_TEGRA=$(realpath $SOURCE/..)
CORES=$(nproc)

TEGRA_KERNEL_OUT="$SOURCE/outdir"
export CROSS_COMPILE="$SOURCE/toolchain/bin/aarch64-linux-"
export LOCALVERSION=-athena

export KBUILD_BUILD_HOST=Athena
export KBUILD_BUILD_USER=Ashlee

function build_kernel {
    clear
    
    pushd $SOURCE/kernel/kernel-5.10/
    
    mkdir -p $TEGRA_KERNEL_OUT
    
    make ARCH=arm64 O=$TEGRA_KERNEL_OUT athena_defconfig
    # make ARCH=arm64 O=$TEGRA_KERNEL_OUT dtbs
    make ARCH=arm64 O=$TEGRA_KERNEL_OUT -j$CORES
    
    # Do not install to $LINUX_FOR_TEGRA/rootfs, need root privileges
    mkdir -p $LINUX_FOR_TEGRA/overlay
    make ARCH=arm64 O=$TEGRA_KERNEL_OUT modules_install INSTALL_MOD_PATH=$LINUX_FOR_TEGRA/overlay/
    
    DATE=$(date +"%Y%m%d_%H%M%S")
    mv $LINUX_FOR_TEGRA/kernel/Image{,.$DATE}
    mv $LINUX_FOR_TEGRA/kernel/Image.gz{,.$DATE}

    if [ -e $LINUX_FOR_TEGRA/kernel/dtb/tegra194-p3668-0001-p2151-0000.dtb ]; then
        mv $LINUX_FOR_TEGRA/kernel/dtb/tegra194-p3668-0001-p2151-0000.dtb{,.$DATE}
    fi
    
    cp $TEGRA_KERNEL_OUT/arch/arm64/boot/Image $LINUX_FOR_TEGRA/kernel/Image
    cp $TEGRA_KERNEL_OUT/arch/arm64/boot/Image.gz $LINUX_FOR_TEGRA/kernel/Image.gz
    cp $TEGRA_KERNEL_OUT/arch/arm64/boot/dts/nvidia/tegra194-p3668-0001-p2151-0000.dtb $LINUX_FOR_TEGRA/kernel/dtb/
    
    ${CROSS_COMPILE}strip -g $(find $LINUX_FOR_TEGRA/overlay/ -name "*.ko")
    # remove build/source symlink
    rm -rf $(find $LINUX_FOR_TEGRA/overlay/lib/modules -type l)
    # remove test ko
    rm -rf $LINUX_FOR_TEGRA/overlay/lib/modules/*/kernel/drivers/media/platform
    rm -rf $LINUX_FOR_TEGRA/overlay/lib/modules/*/kernel/drivers/platform
    
    popd
}

function config_kernel {
    clear
    
    pushd $SOURCE/kernel/kernel-5.10/
    
    mkdir -p $TEGRA_KERNEL_OUT 
    
    make ARCH=arm64 O=$TEGRA_KERNEL_OUT athena_defconfig
    make ARCH=arm64 O=$TEGRA_KERNEL_OUT menuconfig

    popd
}

function commit_config {
    clear
    
    pushd $SOURCE/kernel/kernel-5.10/
    
    mkdir -p $TEGRA_KERNEL_OUT 
    
    DATE=$(date +"%d%m%Y_%H%M%S")
    make ARCH=arm64 O=$TEGRA_KERNEL_OUT savedefconfig
    cp arch/arm64/configs/athena_defconfig arch/arm64/configs/athena_defconfig_${DATE}
    cp ${TEGRA_KERNEL_OUT}/defconfig arch/arm64/configs/athena_defconfig

    popd
}

if [[ $1 == 'config' ]]
then
    echo "config kernel"
    config_kernel
elif [[ $1 == 'commit_config' ]]
then
    echo "commit config"
    commit_config
else
    echo "build kernel"
    build_kernel
fi
# Cyberdog refactoring based on JetPack 5

**Note: The project only contains the Xavier NX part of Cyberdog**

# Support Status

## Work well
- wireless
- bluetooth
- ethernet
- can-bus
- gpu/cuda
- nvme
- usb3/usb-otg
- debug uart
- fan/tech/pwm
- hdmi
- gpio
- realsense
- color camera
- stereo camera

## Not tested
- mcu-sensors
- gps
- touchpad

## Not supported
- mic array
- speaker


# How to build image
```
# build sample rootfs
cd tools/samplefs
sudo ./nv_build_samplefs.sh --abi aarch64 --distro ubuntu --flavor athena --version focal

# build kernel
./source/build_athena_kernel.sh

# build image
sudo ./build_athena_images.sh

# flash target
sudo ./tools/kernel_flash/l4t_initrd_flash.sh --flash-only
```




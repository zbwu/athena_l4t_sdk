************************************************************************
                              Linux for Jetson
                   Backup - restore tool for Jetson
                                   README
************************************************************************
The NVIDIA Jetson Linux package provides a tool to create a backup image and restore
a Jetson device using the backup image.

Requirements:
- Automount of new external storage devices must be temporarily disabled during
  backing up and restoring. On most distributions of Debian-based Linux, you can
  do this using the following command:
      $ systemctl stop udisks2.service
- This tool requires the host to have the following dependencies:
      $ sudo apt install libxml2-utils simg2img abootimg sshpass # For Debian-based Linux


Workflow 1: To create a backup image to host storage

Steps:
- Make sure you have only ONE Jetson device in recovery mode plugged in the host
- Run this command from the Linux_for_Tegra folder:
      $ sudo ./tools/backup_restore/l4t_backup_restore.sh -b <board-name>
  Where <board-name> is the same value as is used in used in the flash.sh
  command. (See more details in the table of device names in the "Introduction"
  topic of Jetson Linux Developer Guide).
- If this command completes successfully, a backup image is stored in
  Linux_for_Tegra/tools/backup_restore/images.


Workflow 2: To restore a Jetson using a backup image

Steps:
- Make sure you have only ONE device in recovery mode plugged in the host
- Make sure a backup image is present in Linux_for_Tegra/tools/backup_restore/images
- Run this command from the Linux_for_Tegra folder:
      $ sudo ./tools/backup_restore/l4t_backup_restore.sh -r <board-name>
  Where <board-name> is the same value as is used in used in the flash.sh
  command. (See more details in the table of device names in the "Introduction"
  topic of Jetson Linux Developer Guide)

Workflow 3: To massflash the backup image

Steps:
- Make sure you have only ONE device in recovery mode plugged in the host
- Run this command from the Linux_for_Tegra folder:
      $ sudo ./tools/backup_restore/l4t_backup_restore.sh -b -c <board-name>
  Where <board-name> are similar to the corresponding variables used
  in the flash.sh command. (See more details in the official documentation's
  board name table).
- If this command completes successfully, an initrd flash image  is stored in
Linux_for_Tegra/tools/kernel_flash/images.
- Put the device in recovery mode again and generate a massflash package using backup image:
      $ sudo ./tools/kernel_flash/l4t_initrd_flash.sh --use-backup-image --no-flash --massflash <x> <board-name> mmcblk0p1
  Where <x> is the highest possible number of devices to be flashed concurrently.
  <board-name> are similar to the corresponding variables used
  in the flash.sh command. (See more details in the official documentation's
  board name table).
- After generate the massflash image and environment, you can flash new device by putting the device into recovery mode:
      $  sudo ./tools/kernel_flash/l4t_initrd_flash.sh --flash-only --massflash <x>
  Alternatively, use the generated mfi_<target-board>.tar.gz tarball. More
  detailed instruction can be found in the Initrd flash README.


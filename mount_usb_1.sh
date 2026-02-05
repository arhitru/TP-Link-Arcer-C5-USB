#!/bin/sh

# Partition and format the USB disk.
DISK="/dev/sda"
parted -s ${DISK} -- mklabel gpt mkpart extroot 2048s -2048s
DEVICE="${DISK}1"
mkfs.ext4 -L extroot ${DEVICE}
# This will wipe all data on the disk, so do not run these commands blindly.

# Configure the extroot mount entry.
eval $(block info ${DEVICE} | grep -o -e 'UUID="\S*"')
eval $(block info | grep -o -e 'MOUNT="\S*/overlay"')
uci -q delete fstab.extroot
uci set fstab.extroot="mount"
uci set fstab.extroot.uuid="${UUID}"
uci set fstab.extroot.target="${MOUNT}"
uci commit fstab

# Configuring rootfs_data / ubifs
# Configure a mount entry for the the original overlay.
ORIG="$(block info | sed -n -e '/MOUNT="\S*\/overlay"/s/:\s.*$//p')"
uci -q delete fstab.rwm
uci set fstab.rwm="mount"
uci set fstab.rwm.device="${ORIG}"
uci set fstab.rwm.target="/rwm"
uci commit fstab
# This will allow you to access the rootfs_data / ubifs partition and customize the extroot configuration /rwm/upper/etc/config/fstab.

# Transfer the content of the current overlay to the external drive.
mount ${DEVICE} /mnt
tar -C ${MOUNT} -cvf - . | tar -C /mnt -xf -

# Reboot the device to apply the changes.
reboot
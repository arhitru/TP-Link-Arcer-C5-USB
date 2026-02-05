#!/bin/sh

DISK="/dev/sda"

# ОСТОРОЖНО: Уничтожает все данные на диске!
echo "Разбиваю диск ${DISK} на разделы..."

# Создаем GPT таблицу
parted -s ${DISK} mklabel gpt

# Раздел 1: extroot (система)
parted -s ${DISK} mkpart "extroot" ext4 2048s 1GB
mkfs.ext4 -L "extroot" ${DISK}1

# Раздел 2: swap
parted -s ${DISK} mkpart "swap" linux-swap 1GB 2GB
mkswap -L "swap" ${DISK}2
swapon ${DISK}2  # Активируем сразу

# Раздел 3: data (пользовательские данные)
parted -s ${DISK} mkpart "data" ext4 2GB 100%
mkfs.ext4 -L "data" ${DISK}3

# Просмотр результата
echo "Созданные разделы:"
parted -s ${DISK} print
echo ""
echo "Информация о файловых системах:"
blkid

# Configure the extroot mount entry.
eval $(block info | grep -o -e 'MOUNT="\S*/overlay"')

# Получаем UUID разделов
UUID_EXTROOT=$(blkid -s UUID -o value /dev/sda1)
UUID_DATA=$(blkid -s UUID -o value /dev/sda2)
UUID_SWAP=$(blkid -s UUID -o value /dev/sda3)

# Настраиваем extroot 
uci -q delete fstab.extroot
uci set fstab.extroot="mount"
uci set fstab.extroot.uuid="${UUID_EXTROOT}"
uci set fstab.extroot.target="${MOUNT}"
uci set fstab.extroot.options="rw,noatime"
uci set fstab.extroot.enabled="1"

# Настраиваем swap
uci -q delete fstab.swap
uci set fstab.swap="swap"
uci set fstab.swap.uuid="${UUID_SWAP}"
uci set fstab.swap.enabled="1"

# Настраиваем data раздел
uci -q delete fstab.data
uci set fstab.data="mount"
uci set fstab.data.uuid="${UUID_DATA}"
uci set fstab.data.target="/mnt/data"
uci set fstab.data.options="rw,noatime,data=ordered"
uci set fstab.data.enabled="1"

# Сохраняем изменения
uci commit fstab

# Создаем точку монтирования и монтируем сразу
mkdir -p /mnt/data
mount /dev/sda3 /mnt/data

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
mount ${DISK}1 /mnt
tar -C ${MOUNT} -cvf - . | tar -C /mnt -xf -

# Reboot the device to apply the changes.
reboot
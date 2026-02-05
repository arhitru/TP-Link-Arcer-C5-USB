#!/bin/sh

DISK="/dev/sda"
SIZE=$(blockdev --getsize64 $DISK)
SIZE_GB=$((SIZE / 1024 / 1024 / 1024))

echo "Размер диска: ${SIZE_GB}GB"
echo "Выберите схему разбиения:"
echo "1) 50% система, 50% данные"
echo "2) 40% система, 10% swap, 50% данные"
echo "3) 30% система, 5% swap, 65% данные"
echo "4) Ручной ввод"
read -p "Выбор [1-4]: " choice

case $choice in
    1)
        SYS_PERCENT=50
        SWAP_PERCENT=0
        ;;
    2)
        SYS_PERCENT=40
        SWAP_PERCENT=10
        ;;
    3)
        SYS_PERCENT=30
        SWAP_PERCENT=5
        ;;
    4)
        read -p "Системный раздел (%): " SYS_PERCENT
        read -p "Swap раздел (%): " SWAP_PERCENT
        ;;
    *)
        echo "Неверный выбор"
        exit 1
        ;;
esac

# Проверяем сумму
TOTAL=$((SYS_PERCENT + SWAP_PERCENT))
if [ $TOTAL -ge 100 ]; then
    echo "Ошибка: сумма процентов >= 100%"
    exit 1
fi

DATA_PERCENT=$((100 - TOTAL))

echo "Схема разбиения:"
echo "- Система: ${SYS_PERCENT}%"
echo "- Swap: ${SWAP_PERCENT}%"
echo "- Данные: ${DATA_PERCENT}%"
read -p "Продолжить? (y/N): " confirm

if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Отмена"
    exit 0
fi

# Вычисляем размеры в GB
SYS_SIZE_GB=$((SIZE_GB * SYS_PERCENT / 100))
SWAP_SIZE_GB=$((SIZE_GB * SWAP_PERCENT / 100))
DATA_SIZE_GB=$((SIZE_GB - SYS_SIZE_GB - SWAP_SIZE_GB))

echo "Создание разделов..."
parted -s $DISK mklabel gpt

# Создаем разделы
OFFSET="2048s"
if [ $SYS_PERCENT -gt 0 ]; then
    parted -s $DISK mkpart "extroot" ext4 $OFFSET ${SYS_SIZE_GB}GB
    OFFSET="${SYS_SIZE_GB}GB"
    mkfs.ext4 -L "extroot" ${DISK}1
fi

if [ $SWAP_PERCENT -gt 0 ]; then
    SWAP_END=$((SYS_SIZE_GB + SWAP_SIZE_GB))
    parted -s $DISK mkpart "swap" linux-swap ${SYS_SIZE_GB}GB ${SWAP_END}GB
    mkswap -L "swap" ${DISK}2
fi

if [ $DATA_PERCENT -gt 0 ]; then
    DATA_START=$((SYS_SIZE_GB + SWAP_SIZE_GB))
    parted -s $DISK mkpart "data" ext4 ${DATA_START}GB 100%
    mkfs.ext4 -L "data" ${DISK}$((SYS_PERCENT > 0 ? (SWAP_PERCENT > 0 ? 3 : 2) : 1))
fi

echo "Диск подготовлен!"
parted -s $DISK print

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
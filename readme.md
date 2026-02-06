# **Об этой сборке**

    Модель: TP-Link Archer C5 v4
    Платформа: ramips/mt7620
    Версия: 24.10.5 (r29087-d9c5716d1d)

Установленные пакеты:

    base-files ca-bundle dnsmasq dropbear firewall4 fstools kmod-gpio-button-hotplug 
    kmod-nft-offload kmod-rt2800-soc libc libgcc libustream-mbedtls logd mtd netifd 
    nftables opkg procd-ujail swconfig uci uclient-fetch urandom-seed urngd wpad-basic-mbedtls 
    kmod-usb2 kmod-mt76x2 kmod-switch-rtl8367b luci 
    block-mount kmod-fs-ext4 e2fsprogs parted kmod-usb-storage

Понадобится USB-накопитель. ВСЕ данные на нём будут ПОТЕРЯНЫ.

**Важные предупреждения:**
- Команды уничтожат все данные на /dev/sda
- Устройство /dev/sda должно быть постоянно подключено
- Рекомендуется сделать резервную копию конфигурации перед выполнением

**Прошивка через Tftpd64**
1. Переименовать файл openwrt-...-tftp-recovery в tp_recovery.bin.
2. Кладем файл с выбранной прошивкой в рабочую папку TFTP сервера.
3. Идем в настройки сетевого интерфейса компа, туда, где указан IP адрес.
4. Устанавливаем вручную IP адрес 192.168.0.66, маска 255.255.255.0. (Возможно, придется выключить и включить интерфейс, чтобы настройка применилась.)
5. Закрываем настройку сети и снова открываем, убеждаемся, что адрес у нас таки 192.168.0.66.
6. Запускаем Tftpd64.
7. Выбираем вкладку "Log viewer".
8. В выпадающем списке "Server interfaces" выбираем адрес "192.168.0.66".
9. На роутере выключаем питание, зажимаем кнопку RESET и включаем питание. Держим зажатую кнопку RESET 10-15 секунд или до момента появления индикатора загрузки файла в Tftpd64.
10. После окончания загрузки в "Log viewer" должны появиться подобные записи:
```
    Connection received from 192.168.0.2 on port 2793 [04/02 16:28:54.752]
    Read request for file <tp_recovery.bin>. Mode octet [04/02 16:28:54.752]
    OACK: <timeout=1,> [04/02 16:28:54.752]
    Using local port 49666 [04/02 16:28:54.752]
    <tp_recovery.bin>: sent 15873 blks, 8126464 bytes in 4 s. 0 blk resent [04/02 16:28:58.255]
```
11. Возвращаем настройки сети на ПК.
12. Подключаемся через ssh к устройству по адресу 192.168.1.1.
13. Последовательно вводим команды:
```
DISK="/dev/sda"
parted -s ${DISK} mklabel gpt
parted -s ${DISK} mkpart "extroot" ext4 2048s 1GB
mkfs.ext4 -L "extroot" ${DISK}1
parted -s ${DISK} mkpart "swap" linux-swap 1GB 2GB
mkswap -L "swap" ${DISK}2
swapon ${DISK}2  # Активируем сразу
parted -s ${DISK} mkpart "data" ext4 2GB 100%
mkfs.ext4 -L "data" ${DISK}3

# Просмотр результата
parted -s ${DISK} print

# Configure the extroot mount entry.
eval $(block info | grep -o -e 'MOUNT="\S*/overlay"')

# Получаем UUID разделов
UUID_EXTROOT="$(block info ${DISK}1 | grep -o -e 'UUID="\S*"')"
UUID_DATA="$(block info ${DISK}3 | grep -o -e 'UUID="\S*"')"

# Настраиваем extroot 
uci -q delete fstab.extroot
uci set fstab.extroot="mount"
uci set fstab.extroot.uuid="${UUID_EXTROOT}"
uci set fstab.extroot.device="${DISK}1"
uci set fstab.extroot.target="${MOUNT}"
uci set fstab.extroot.options="rw,noatime"
uci set fstab.extroot.enabled="1"

# Настраиваем swap
uci -q delete fstab.swap
uci set fstab.swap="swap"
uci set fstab.swap.device="${DISK}2"
uci set fstab.swap.enabled="1"

# Настраиваем data раздел
uci -q delete fstab.data
uci set fstab.data="mount"
uci set fstab.data.uuid="${UUID_DATA}"
uci set fstab.data.device="${DISK}3"
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
```


## **Проверка**

### **Через Web интерфейс**

**LuCI → System → Mount Points** должен быть показан раздел на внешнем USB устройстве подмонтированный как overlay.

**LuCI → System → Software** должно быть показано большее свободное пространство на overlay разделе.

### **Через командную строку**

Раздел на внешнем USB устройстве должен быть подмонтирован как overlay Свободное пространство в корневом разделе / должно быть равно пространству на /overlay.
```bash
# grep -e /overlay /etc/mtab
/dev/sda1 /overlay ext4 rw,relatime,data=ordered
overlayfs:/overlay / overlay rw,noatime,lowerdir=/,upperdir=/overlay/upper,workdir=/overlay/work
 
# df /overlay /
Filesystem           1K-blocks      Used Available Use% Mounted on
/dev/sda1              7759872    477328   7221104   6% /overlay
overlayfs:/overlay     7759872    477328   7221104   6% /
```

## **Сохранение списков программных пакетов при загрузке**
Сохранение статуса установленных пакетов opkg в /usr/lib/opkg/lists хранящемся в extroot, а не в RAM, экономит некоторую оперативную память и сохраняет списки пакетов доступными после перезагрузки.

### **Через Web интерфейс**
1. **LuCI → System → Software → Configuration**

смените
```bash
lists_dir ext /var/opkg-lists
```
на
```bash
lists_dir ext /usr/lib/opkg/lists
```
это должно выглядеть примерно так:
```bash
dest root /
dest ram /tmp
lists_dir ext /usr/lib/opkg/lists
option overlay_root /overlay
option check_signature
```
2. **LuCI → System → Software → Actions → Update lists** производит первоначальное обновление списка пакетов на extroot
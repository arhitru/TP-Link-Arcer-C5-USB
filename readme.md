# **Об этой сборке**

    Модель: TP-Link Archer C5 v4
    Платформа: ramips/mt7620
    Версия: 24.10.5 (r29087-d9c5716d1d)

Установленные пакеты:

    base-files ca-bundle dnsmasq dropbear firewall4 fstools kmod-gpio-button-hotplug kmod-nft-offload kmod-rt2800-soc libc libgcc libustream-mbedtls logd mtd netifd nftables opkg procd-ujail swconfig uci uclient-fetch urandom-seed urngd wpad-basic-mbedtls kmod-usb2 kmod-mt76x2 kmod-switch-rtl8367b luci block-mount kmod-fs-ext4 e2fsprogs parted kmod-usb-storage

Понадобится USB-накопитель. ВСЕ данные на нём будут ПОТЕРЯНЫ.

**Важные предупреждения:**
- Скрипт уничтожит все данные на /dev/sda
- Устройство /dev/sda должно быть постоянно подключено
- Рекомендуется сделать резервную копию конфигурации перед выполнением

**Прошивка через Tftpd64**
1. Переименовать файл tp_recovery_C5_USB.bin в tp_recovery.bin.
2. Кладем файл с выбранной прошивкой в рабочую папку TFTP сервера.
3. Идем в настройки сетевого интерфейса компа, туда, где указан IP адрес.
4. Устанавливаем вручную IP адрес 192.168.0.66, маска 255.255.255.0. (Возможно, придется выключить и включить интерфейс, чтобы настройка применилась.)
5. Закрываем настройку сети и снова открываем, убеждаемся, что адрес у нас таки 192.168.0.66.
6. Запускаем Tftpd64.
7. Выбираем вкладку "Log viewer".
8. В выпадающем списке "Server interfaces" выбираем адрес "192.168.0.66".
9. На роутере выключаем питание, зажимаем кнопку RESET и включаем питание. Держим зажатую кнопку RESET 10-15 секунд или до момента появления индикатора загрузки файла в Tftpd64.
10. После окончания загрузки в "Log viewer" должны появиться подобные записи:
    
    Connection received from 192.168.0.2 on port 2793 [04/02 16:28:54.752]
    Read request for file <tp_recovery.bin>. Mode octet [04/02 16:28:54.752]
    OACK: <timeout=1,> [04/02 16:28:54.752]
    Using local port 49666 [04/02 16:28:54.752]
    <tp_recovery.bin>: sent 15873 blks, 8126464 bytes in 4 s. 0 blk resent [04/02 16:28:58.255]
    
11. После загрузки прошивки отработает скрипт настроек для расширения корневой файловой системы OpenWRT на отдельный раздел диска. Цель скрипта перенести корневую файловую систему OpenWRT с ограниченной внутренней памяти на внешний накопитель для увеличения доступного пространства.
    - Определяет целевой диск.
    - создает GPT таблицу разделов.
    - создает раздел от 2048-го сектора до предпоследнего 2048-го сектора.
    - Создает файловую систему ext4 на первом разделе.
    - устанавливает метку раздела.
    - Извлекает UUID созданного раздела в переменную.
    - Находит текущую точку монтирования overlay.
    - Настраивает автоматическое монтирование нового раздела как корневой файловой системы.
    - Монтирует оригинальную внутреннюю память как /rwm для чтения/записи.
    - Монтирует новый раздел в /mnt.
    - Копирует все данные из текущего overlay в новый раздел.
12. Возвращаем настройки сети на ПК.
12. Заходим браузером в админку роутера по адресу 192.168.1.1.


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
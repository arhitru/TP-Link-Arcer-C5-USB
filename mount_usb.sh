#!/bin/sh

DISK="/dev/sda"

# Функция для обработки ошибок
error_exit() {
    echo "Ошибка: $1" >&2
    exit 1
}

# Функция для получения метки раздела
get_part_label() {
    local part="$1"
    if blkid "$part" >/dev/null 2>&1; then
        blkid -s LABEL -o value "$part" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Функция для получения UUID раздела
get_part_uuid() {
    local part="$1"
    blkid -s UUID -o value "$part" 2>/dev/null || echo ""
}

# Функция для проверки существующих разделов
check_existing_partitions() {
    local disk="$1"
    local valid_layout=true
    
    echo "Проверяю существующую разметку диска $disk..."
    
    # Проверяем каждый раздел
    for part in ${disk}[0-9]*; do
        if [ -b "$part" ]; then
            local label=$(get_part_label "$part")
            local part_num=${part##*[^0-9]}
            
            echo "  Раздел $part: метка='$label'"
            
            # Проверяем соответствие меток ожидаемым
            case "$part_num" in
                1)
                    if [ "$label" != "extroot" ]; then
                        echo "    ⚠️  Неправильная метка для extroot раздела"
                        valid_layout=false
                    fi
                    ;;
                2)
                    if [ "$label" != "swap" ]; then
                        echo "    ⚠️  Неправильная метка для swap раздела"
                        valid_layout=false
                    fi
                    ;;
                3)
                    if [ "$label" != "data" ] && [ "$label" != "extra" ]; then
                        echo "    ⚠️  Неправильная метка для data раздела"
                        valid_layout=false
                    fi
                    ;;
                4)
                    if [ "$label" != "extra" ]; then
                        echo "    ⚠️  Неправильная метка для extra раздела"
                        valid_layout=false
                    fi
                    ;;
                *)
                    echo "    ⚠️  Неожиданный раздел $part_num"
                    valid_layout=false
                    ;;
            esac
        fi
    done
    
    echo "$valid_layout"
}

# Функция для создания новой разметки
create_new_partitions() {
    local disk="$1"
    
    echo "Создаю новую разметку на диске $disk..."
    
    # Получаем размер диска в байтах
    DISK_SIZE_BYTES=$(blockdev --getsize64 "$disk") || error_exit "Не удалось определить размер диска"
    DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
    
    echo "Размер диска: ${DISK_SIZE_GB}GB"
    
    # Определяем количество разделов в зависимости от размера
    if [ "$DISK_SIZE_GB" -lt 1 ]; then
        error_exit "Диск слишком мал (меньше 1GB)"
    elif [ "$DISK_SIZE_GB" -lt 2 ]; then
        PART_COUNT=1
        echo "Создаю 1 раздел (диск менее 2GB)"
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        parted -s ${disk} mkpart "extroot" ext4 2048s 100% || error_exit "Ошибка создания раздела"
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
    elif [ "$DISK_SIZE_GB" -lt 4 ]; then
        PART_COUNT=2
        echo "Создаю 2 раздела (диск 2-3GB)"
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        
        EXTROOT_END=$((DISK_SIZE_GB * 80 / 100))
        parted -s ${disk} mkpart "extroot" ext4 2048s ${EXTROOT_END}GB || error_exit "Ошибка создания extroot"
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap ${EXTROOT_END}GB 100% || error_exit "Ошибка создания swap"
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        swapon ${disk}2 || echo "Предупреждение: не удалось активировать swap"
        
    elif [ "$DISK_SIZE_GB" -lt 64 ]; then
        PART_COUNT=3
        echo "Создаю 3 раздела (диск 4-32GB)"
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 2GB || error_exit "Ошибка создания extroot"
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 2GB 4GB || error_exit "Ошибка создания swap"
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        swapon ${disk}2 || echo "Предупреждение: не удалось активировать swap"
        
        parted -s ${disk} mkpart "data" ext4 4GB 100% || error_exit "Ошибка создания data"
        mkfs.ext4 -L "data" ${disk}3 || error_exit "Ошибка создания файловой системы"
        
    else
        PART_COUNT=4
        echo "Создаю 4 раздела (диск 64GB и более)"
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 4GB || error_exit "Ошибка создания extroot"
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 4GB 8GB || error_exit "Ошибка создания swap"
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        swapon ${disk}2 || echo "Предупреждение: не удалось активировать swap"
        
        DATA_SIZE=$((DISK_SIZE_GB - 8))
        DATA_PART1_END=$((8 + DATA_SIZE / 2))
        parted -s ${disk} mkpart "data" ext4 8GB ${DATA_PART1_END}GB || error_exit "Ошибка создания data"
        mkfs.ext4 -L "data" ${disk}3 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "extra" ext4 ${DATA_PART1_END}GB 100% || error_exit "Ошибка создания extra"
        mkfs.ext4 -L "extra" ${disk}4 || error_exit "Ошибка создания файловой системы"
    fi
    
    echo "$PART_COUNT"
}

# Функция для настройки fstab
configure_fstab() {
    local disk="$1"
    local part_count="$2"
    
    echo "Настраиваю fstab..."
    
    # Configure the extroot mount entry
    eval $(block info | grep -o -e 'MOUNT="\S*/overlay"')
    
    # Удаляем старые настройки для этого диска
    uci -q delete fstab.extroot
    uci -q delete fstab.swap
    uci -q delete fstab.data
    uci -q delete fstab.extra
    
    # Настраиваем extroot (всегда должен быть)
    if [ -b "${disk}1" ]; then
        uci set fstab.extroot="mount"
        uci set fstab.extroot.device="${disk}1"
        uci set fstab.extroot.target="${MOUNT}"
        uci set fstab.extroot.enabled="1"
        echo "  Настроен extroot: ${disk}1"
    fi
    
    # Настраиваем swap если есть
    if [ "$part_count" -ge 2 ] && [ -b "${disk}2" ]; then
        uci set fstab.swap="swap"
        uci set fstab.swap.device="${disk}2"
        uci set fstab.swap.enabled="1"
        swapon "${disk}2" 2>/dev/null || echo "    Предупреждение: не удалось активировать swap"
        echo "  Настроен swap: ${disk}2"
    fi
    
    # Настраиваем data если есть
    if [ "$part_count" -ge 3 ] && [ -b "${disk}3" ]; then
        uci set fstab.data="mount"
        uci set fstab.data.device="${disk}3"
        uci set fstab.data.target="/mnt/data"
        uci set fstab.data.enabled="1"
        
        mkdir -p /mnt/data
        if mount "${disk}3" /mnt/data 2>/dev/null; then
            echo "  Настроен и смонтирован data: ${disk}3"
        else
            echo "    Предупреждение: не удалось смонтировать data раздел"
        fi
    fi
    
    # Настраиваем extra если есть
    if [ "$part_count" -ge 4 ] && [ -b "${disk}4" ]; then
        uci set fstab.extra="mount"
        uci set fstab.extra.device="${disk}4"
        uci set fstab.extra.target="/mnt/extra"
        uci set fstab.extra.enabled="1"
        
        mkdir -p /mnt/extra
        if mount "${disk}4" /mnt/extra 2>/dev/null; then
            echo "  Настроен и смонтирован extra: ${disk}4"
        else
            echo "    Предупреждение: не удалось смонтировать extra раздел"
        fi
    fi
    
    # Сохраняем изменения
    uci commit fstab || error_exit "Ошибка сохранения конфигурации fstab"
    
    # Configuring rootfs_data / ubifs
    ORIG="$(block info | sed -n -e '/MOUNT="\S*\/overlay"/s/:\s.*$//p')"
    if [ -n "$ORIG" ]; then
        uci -q delete fstab.rwm
        uci set fstab.rwm="mount"
        uci set fstab.rwm.device="${ORIG}"
        uci set fstab.rwm.target="/rwm"
        uci commit fstab
    fi
}

# Функция для копирования данных в extroot
copy_to_extroot() {
    local disk="$1"
    
    echo "Копирую данные в extroot..."
    
    if mount "${disk}1" /mnt 2>/dev/null; then
        if [ -d "${MOUNT}" ]; then
            tar -C "${MOUNT}" -cvf - . | tar -C /mnt -xf - 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "  Данные успешно скопированы"
            else
                echo "  Предупреждение: возникли ошибки при копировании"
            fi
        else
            echo "  Предупреждение: исходная точка монтирования не найдена"
        fi
        umount /mnt 2>/dev/null
    else
        echo "  Предупреждение: не удалось смонтировать extroot для копирования данных"
    fi
}

# Основной код
main() {
    # Проверяем существование диска
    [ -b "$DISK" ] || error_exit "Диск $DISK не найден"
    
    echo "=== Настройка диска $DISK ==="
    
    # Проверяем существующие разделы
    EXISTING_PARTS=$(lsblk -ln -o NAME "$DISK" | grep -c "${DISK##*/}[0-9]")
    
    if [ "$EXISTING_PARTS" -eq 0 ]; then
        echo "Диск не размечен. Создаю новую разметку..."
        PART_COUNT=$(create_new_partitions "$DISK")
        configure_fstab "$DISK" "$PART_COUNT"
        copy_to_extroot "$DISK"
        
    else
        echo "На диске обнаружены разделы. Проверяю разметку..."
        
        # Проверяем корректность существующей разметки
        if [ "$(check_existing_partitions "$DISK")" = "true" ]; then
            echo "✅ Существующая разметка корректна. Использую её."
            
            # Определяем количество корректных разделов
            PART_COUNT=0
            for part in ${DISK}[0-9]*; do
                if [ -b "$part" ]; then
                    PART_COUNT=$((PART_COUNT + 1))
                fi
            done
            
            echo "Обнаружено $PART_COUNT корректных разделов"
            configure_fstab "$DISK" "$PART_COUNT"
            
            # Проверяем, нужно ли копировать данные в extroot
            if [ -b "${DISK}1" ] && ! mountpoint -q "${MOUNT}"; then
                echo "Extroot еще не настроен. Копирую данные..."
                copy_to_extroot "$DISK"
            else
                echo "Extroot уже настроен. Пропускаю копирование данных."
            fi
            
        else
            echo "❌ Существующая разметка некорректна или неполная."
            echo "Переразмечаем диск. Все данные будут удалены!" 
            echo "Переразмечаю диск..."
            PART_COUNT=$(create_new_partitions "$DISK")
            configure_fstab "$DISK" "$PART_COUNT"
            copy_to_extroot "$DISK"
        fi
    fi
    
    # Показываем итоговую информацию
    echo ""
    echo "=== Итоговая информация ==="
    echo "Таблица разделов:"
    parted -s "$DISK" print 2>/dev/null || echo "Не удалось отобразить таблицу разделов"
    
    echo ""
    echo "Монтированные разделы:"
    mount | grep "^$DISK" || echo "Нет смонтированных разделов с этого диска"
    
    echo ""
    echo "Настройка fstab завершена успешно!"
    
    # Автоматическая перезагрузка только при изменении разметки
    if [ "$EXISTING_PARTS" -eq 0 ] || [ "$(check_existing_partitions "$DISK")" != "true" ]; then
        echo "Перезагружаюсь для применения изменений..."
        sleep 2
        reboot
    else
        echo "Для применения изменений в extroot требуется перезагрузка."
        read -p "Перезагрузить сейчас? [y/N]: " REBOOT_NOW
        if [ "$REBOOT_NOW" = "y" ] || [ "$REBOOT_NOW" = "Y" ]; then
            echo "Перезагружаюсь..."
            sleep 2
            reboot
        fi
    fi
}

# Запускаем основной код
main
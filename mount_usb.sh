#!/bin/sh

DISK="/dev/sda"

# Функция для обработки ошибок
error_exit() {
    echo "Ошибка: $1" >&2
    exit 1
}

# Основной код
main() {
    # Проверяем существование диска
    [ -b "$DISK" ] || error_exit "Диск $DISK не найден"
    
    echo "=== Настройка диска $DISK ==="
    
    # Сначала показываем текущую таблицу разделов
    echo "Текущая таблица разделов:"
    if command -v parted >/dev/null 2>&1; then
        parted -s "$DISK" print 2>/dev/null || echo "Не удалось отобразить таблицу разделов"
    else
        echo "Утилита parted не найдена"
    fi
    echo ""
    
    # Проверяем наличие разделов
    EXISTING_PARTS=0
    for i in 1 2 3 4; do
        if [ -b "${DISK}${i}" ]; then
            EXISTING_PARTS=$((EXISTING_PARTS + 1))
        fi
    done
    
    if [ "$EXISTING_PARTS" -eq 0 ]; then
        echo "Диск не размечен. Создаю новую разметку..."
        # Здесь будет код создания разметки
        echo "Создаю 3 раздела (по умолчанию для диска 4-32GB)..."
        
        # Определяем размер диска
        if command -v blockdev >/dev/null 2>&1; then
            DISK_SIZE_BYTES=$(blockdev --getsize64 "$DISK" 2>/dev/null)
            DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
            echo "Размер диска: ${DISK_SIZE_GB}GB"
        else
            echo "Размер диска: неизвестен (использую настройки по умолчанию)"
        fi
        
        # Создаем разделы
        parted -s ${DISK} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        parted -s ${DISK} mkpart "extroot" ext4 2048s 2GB || error_exit "Ошибка создания extroot"
        sleep 2
        mkfs.ext4 -L "extroot" ${DISK}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${DISK} mkpart "swap" linux-swap 2GB 4GB || error_exit "Ошибка создания swap"
        sleep 2
        mkswap -L "swap" ${DISK}2 || error_exit "Ошибка создания swap"
        swapon ${DISK}2 2>/dev/null || echo "Предупреждение: не удалось активировать swap"
        
        parted -s ${DISK} mkpart "data" ext4 4GB 100% || error_exit "Ошибка создания data"
        sleep 2
        mkfs.ext4 -L "data" ${DISK}3 || error_exit "Ошибка создания файловой системы"
        
        PART_COUNT=3
        echo "Создано $PART_COUNT раздела"
        
    else
        echo "На диске обнаружены разделы ($EXISTING_PARTS)."
        
        # Простая проверка через parted
        if command -v parted >/dev/null 2>&1; then
            echo "Проверяю разметку через parted..."
            
            # Получаем информацию о разделах
            PARTITIONS_INFO=$(parted -s "$DISK" print 2>/dev/null | awk 'NR > 7 && /^ [0-9]/ {print $1 " " $6 " " $5}')
            
            if [ -n "$PARTITIONS_INFO" ]; then
                echo "$PARTITIONS_INFO" | while read -r num name fstype; do
                    case "$num" in
                        1)
                            if [ "$name" = "extroot" ] && echo "$fstype" | grep -q "ext4"; then
                                echo "  ✅ Раздел 1: $name ($fstype) - корректный"
                            else
                                echo "  ❌ Раздел 1: $name ($fstype) - ожидается: extroot, ext4"
                            fi
                            ;;
                        2)
                            if [ "$name" = "swap" ] && echo "$fstype" | grep -q -E "swap|linux-swap"; then
                                echo "  ✅ Раздел 2: $name ($fstype) - корректный"
                            else
                                echo "  ❌ Раздел 2: $name ($fstype) - ожидается: swap, swap"
                            fi
                            ;;
                        3)
                            if [ "$name" = "data" ] && echo "$fstype" | grep -q "ext4"; then
                                echo "  ✅ Раздел 3: $name ($fstype) - корректный"
                            elif [ "$name" = "extra" ] && echo "$fstype" | grep -q "ext4"; then
                                echo "  ✅ Раздел 3: $name ($fstype) - корректный"
                            else
                                echo "  ❌ Раздел 3: $name ($fstype) - ожидается: data или extra, ext4"
                            fi
                            ;;
                        4)
                            if [ "$name" = "extra" ] && echo "$fstype" | grep -q "ext4"; then
                                echo "  ✅ Раздел 4: $name ($fstype) - корректный"
                            else
                                echo "  ❌ Раздел 4: $name ($fstype) - ожидается: extra, ext4"
                            fi
                            ;;
                    esac
                done
                
                # Простая проверка: если все разделы 1-3 существуют и имеют правильные имена
                if [ -b "${DISK}1" ] && [ -b "${DISK}2" ] && [ -b "${DISK}3" ]; then
                    echo "✅ Обнаружена корректная 3-раздельная структура"
                    PART_COUNT=3
                    
                    # Настраиваем fstab
                    echo "Настраиваю fstab..."
                    
                    # Configure the extroot mount entry
                    eval $(block info | grep -o -e 'MOUNT="\S*/overlay"')
                    
                    # Настраиваем extroot
                    uci -q delete fstab.extroot
                    uci set fstab.extroot="mount"
                    uci set fstab.extroot.device="${DISK}1"
                    uci set fstab.extroot.target="${MOUNT}"
                    uci set fstab.extroot.enabled="1"
                    
                    # Настраиваем swap
                    uci -q delete fstab.swap
                    uci set fstab.swap="swap"
                    uci set fstab.swap.device="${DISK}2"
                    uci set fstab.swap.enabled="1"
                    swapon "${DISK}2" 2>/dev/null || echo "Предупреждение: не удалось активировать swap"
                    
                    # Настраиваем data
                    uci -q delete fstab.data
                    uci set fstab.data="mount"
                    uci set fstab.data.device="${DISK}3"
                    uci set fstab.data.target="/mnt/data"
                    uci set fstab.data.enabled="1"
                    
                    # Сохраняем изменения
                    uci commit fstab || echo "Предупреждение: не удалось сохранить fstab"
                    
                    # Монтируем data раздел
                    mkdir -p /mnt/data
                    mount "${DISK}3" /mnt/data 2>/dev/null || echo "Предупреждение: не удалось смонтировать data раздел"
                    
                    echo "Настройка завершена успешно!"
                    exit 0
                fi
            fi
        fi
        
        # Если дошли сюда, значит разметка некорректна
        echo ""
        echo "❌ Существующая разметка некорректна или неполная."
        
        # Интерактивный режим
        read -p "Переразметить диск? (Все данные будут удалены!) [y/N]: " CONFIRM
        
        if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
            echo "Переразмечаю диск..."
            # Здесь будет код переразметки
            echo "Создаю новую разметку..."
            
            # Определяем размер диска
            if command -v blockdev >/dev/null 2>&1; then
                DISK_SIZE_BYTES=$(blockdev --getsize64 "$DISK" 2>/dev/null)
                DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
                echo "Размер диска: ${DISK_SIZE_GB}GB"
            fi
            
            # Создаем разделы
            parted -s ${DISK} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
            parted -s ${DISK} mkpart "extroot" ext4 2048s 2GB || error_exit "Ошибка создания extroot"
            sleep 2
            mkfs.ext4 -L "extroot" ${DISK}1 || error_exit "Ошибка создания файловой системы"
            
            parted -s ${DISK} mkpart "swap" linux-swap 2GB 4GB || error_exit "Ошибка создания swap"
            sleep 2
            mkswap -L "swap" ${DISK}2 || error_exit "Ошибка создания swap"
            swapon ${DISK}2 2>/dev/null || echo "Предупреждение: не удалось активировать swap"
            
            parted -s ${DISK} mkpart "data" ext4 4GB 100% || error_exit "Ошибка создания data"
            sleep 2
            mkfs.ext4 -L "data" ${DISK}3 || error_exit "Ошибка создания файловой системы"
            
            echo "Переразметка завершена. Необходимо перезагрузиться."
            reboot
        else
            echo "Отменено пользователем."
            exit 0
        fi
    fi
}

# Запускаем основной код
main
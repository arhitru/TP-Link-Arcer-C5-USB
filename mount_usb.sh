#!/bin/sh

DISK="/dev/sda"

# Функция для обработки ошибок
error_exit() {
    echo "Ошибка: $1" >&2
    exit 1
}

# Функция для определения размера диска
get_disk_size() {
    local disk="$1"
    
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --getsize64 "$disk" 2>/dev/null
    elif [ -f "/sys/block/${disk##*/}/size" ]; then
        local sectors=$(cat "/sys/block/${disk##*/}/size" 2>/dev/null)
        if [ -n "$sectors" ]; then
            echo $((sectors * 512))
        else
            echo ""
        fi
    elif command -v fdisk >/dev/null 2>&1; then
        fdisk -l "$disk" 2>/dev/null | grep -E "^Disk ${disk}:" | awk '{print $5}'
    else
        echo ""
    fi
}

# Функция для подсчета существующих разделов
count_existing_partitions() {
    local disk="$1"
    local count=0
    
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -b "${disk}${i}" ]; then
            count=$((count + 1))
        fi
    done
    
    echo "$count"
}

# Функция для быстрой проверки (основная)
quick_check() {
    local disk="$1"
    
    echo "Быстрая проверка разметки..."
    
    # Проверяем наличие parted
    if ! command -v parted >/dev/null 2>&1; then
        echo "  ⚠️ Утилита parted не найдена"
        echo "false"
        return
    fi
    
    # Проверяем наличие GPT
    if ! parted -s "$disk" print 2>/dev/null | grep -q "Partition Table:.*gpt"; then
        echo "  ❌ Таблица разделов не GPT"
        echo "false"
        return
    fi
    
    # Получаем список разделов
    local partitions=$(parted -s "$disk" print 2>/dev/null | awk 'NR > 7 && /^ [0-9]/ {print $1 " " $6 " " $5}')
    
    if [ -z "$partitions" ]; then
        echo "  Диск не размечен"
        echo "0"
        return
    fi
    
    # Проверяем последовательно разделы
    local valid_count=0
    
    # Используем файл для накопления результатов
    local result_file=$(mktemp /tmp/partcheck.XXXXXX)
    
    echo "$partitions" | while read -r num name fstype; do
        if [ "$num" -ge 1 ] && [ "$num" -le 4 ]; then
            case "$num" in
                1)
                    if [ "$name" = "extroot" ] && echo "$fstype" | grep -q "ext4"; then
                        echo "  ✅ Раздел 1: $name ($fstype) - корректный"
                        echo "1" >> "$result_file"
                    else
                        echo "  ❌ Раздел 1: $name ($fstype) - ожидается: extroot, ext4"
                    fi
                    ;;
                2)
                    if [ "$name" = "swap" ] && echo "$fstype" | grep -q -E "swap|linux-swap"; then
                        echo "  ✅ Раздел 2: $name ($fstype) - корректный"
                        echo "1" >> "$result_file"
                    else
                        echo "  ❌ Раздел 2: $name ($fstype) - ожидается: swap, swap"
                    fi
                    ;;
                3)
                    if [ "$name" = "data" ] && echo "$fstype" | grep -q "ext4"; then
                        echo "  ✅ Раздел 3: $name ($fstype) - корректный"
                        echo "1" >> "$result_file"
                    elif [ "$name" = "extra" ] && echo "$fstype" | grep -q "ext4"; then
                        echo "  ✅ Раздел 3: $name ($fstype) - корректный"
                        echo "1" >> "$result_file"
                    else
                        echo "  ❌ Раздел 3: $name ($fstype) - ожидается: data или extra, ext4"
                    fi
                    ;;
                4)
                    if [ "$name" = "extra" ] && echo "$fstype" | grep -q "ext4"; then
                        echo "  ✅ Раздел 4: $name ($fstype) - корректный"
                        echo "1" >> "$result_file"
                    else
                        echo "  ❌ Раздел 4: $name ($fstype) - ожидается: extra, ext4"
                    fi
                    ;;
            esac
        else
            echo "  ⚠️  Раздел $num: пропускается (поддерживаются только разделы 1-4)"
        fi
    done
    
    # Подсчитываем результаты
    if [ -f "$result_file" ]; then
        valid_count=$(wc -l < "$result_file" 2>/dev/null)
        # Удаляем пробелы и переводы строк
        valid_count=$(echo "$valid_count" | tr -d '[:space:]')
        rm -f "$result_file"
    fi
    
    # Проверяем непрерывность последовательности
    local continuous="true"
    if [ "$valid_count" -gt 0 ]; then
        for i in $(seq 1 $valid_count); do
            if [ ! -b "${disk}${i}" ]; then
                continuous="false"
                break
            fi
        done
    fi
    
    if [ "$valid_count" -eq 0 ]; then
        echo "  ❌ Не найдено корректных разделов"
        echo "false"
    elif [ "$continuous" = "false" ]; then
        echo "  ⚠️  Нарушена последовательность разделов"
        echo "$valid_count"
    else
        echo "  ✅ Найдено $valid_count корректных разделов"
        echo "$valid_count"
    fi
}

# Функция для автоматического определения конфигурации
auto_detect_layout() {
    local disk="$1"
    
    echo "Автоматическое определение конфигурации диска..."
    
    # Получаем информацию из parted
    if ! command -v parted >/dev/null 2>&1; then
        echo "  ⚠️ Parted не найден, использую простой подсчет"
        local count=$(count_existing_partitions "$disk")
        echo "$count"
        return
    fi
    
    local parted_info=$(parted -s "$disk" print 2>/dev/null)
    local gpt_check=$(echo "$parted_info" | grep -c "Partition Table:.*gpt")
    
    if [ "$gpt_check" -eq 0 ]; then
        echo "  ❌ Таблица разделов не GPT"
        echo "false"
        return
    fi
    
    # Извлекаем информацию о разделах
    local partitions=$(echo "$parted_info" | awk 'NR > 7 && /^ [0-9]/ {print $1 "|" $6 "|" $5}')
    
    if [ -z "$partitions" ]; then
        echo "  Диск не размечен"
        echo "0"
        return
    fi
    
    # Используем временные файлы для каждого раздела
    local part1_file=$(mktemp /tmp/part1.XXXXXX)
    local part2_file=$(mktemp /tmp/part2.XXXXXX)
    local part3_file=$(mktemp /tmp/part3.XXXXXX)
    local part4_file=$(mktemp /tmp/part4.XXXXXX)
    
    echo "$partitions" | while IFS='|' read -r num name fstype; do
        case "$num" in
            1)
                if [ "$name" = "extroot" ] || echo "$fstype" | grep -q "ext4"; then
                    echo "extroot" > "$part1_file"
                fi
                ;;
            2)
                if [ "$name" = "swap" ] || echo "$fstype" | grep -q -E "swap|linux-swap"; then
                    echo "swap" > "$part2_file"
                fi
                ;;
            3)
                if [ "$name" = "data" ] || [ "$name" = "extra" ] || echo "$fstype" | grep -q "ext4"; then
                    echo "data" > "$part3_file"
                fi
                ;;
            4)
                if [ "$name" = "extra" ] || echo "$fstype" | grep -q "ext4"; then
                    echo "extra" > "$part4_file"
                fi
                ;;
        esac
    done
    
    # Ждем завершения пайплайна
    wait
    
    # Определяем конфигурацию
    local part_count=0
    
    if [ -s "$part1_file" ]; then
        part_count=$((part_count + 1))
        echo "  Раздел 1: $(cat "$part1_file")"
    fi
    
    if [ -s "$part2_file" ]; then
        part_count=$((part_count + 1))
        echo "  Раздел 2: $(cat "$part2_file")"
    fi
    
    if [ -s "$part3_file" ]; then
        part_count=$((part_count + 1))
        echo "  Раздел 3: $(cat "$part3_file")"
    fi
    
    if [ -s "$part4_file" ]; then
        part_count=$((part_count + 1))
        echo "  Раздел 4: $(cat "$part4_file")"
    fi
    
    # Удаляем временные файлы
    rm -f "$part1_file" "$part2_file" "$part3_file" "$part4_file"
    
    if [ "$part_count" -eq 0 ]; then
        echo "  ❌ Не удалось определить конфигурацию"
        echo "false"
    else
        echo "  ✅ Обнаружена конфигурация с $part_count разделами"
        echo "$part_count"
    fi
}

# Функция для создания новой разметки
create_new_partitions() {
    local disk="$1"
    
    echo "Создаю новую разметку на диске $disk..."
    
    # Получаем размер диска
    DISK_SIZE_BYTES=$(get_disk_size "$disk") || error_exit "Не удалось определить размер диска"
    
    if [ -z "$DISK_SIZE_BYTES" ] || [ "$DISK_SIZE_BYTES" -eq 0 ]; then
        error_exit "Не удалось определить размер диска"
    fi
    
    # Конвертируем в гигабайты
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
        sleep 2
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
    elif [ "$DISK_SIZE_GB" -lt 4 ]; then
        PART_COUNT=2
        echo "Создаю 2 раздела (диск 2-3GB)"
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        
        EXTROOT_END=$((DISK_SIZE_GB * 80 / 100))
        parted -s ${disk} mkpart "extroot" ext4 2048s ${EXTROOT_END}GB || error_exit "Ошибка создания extroot"
        sleep 2
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap ${EXTROOT_END}GB 100% || error_exit "Ошибка создания swap"
        sleep 2
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        swapon ${disk}2 2>/dev/null || echo "Предупреждение: не удалось активировать swap"
        
    elif [ "$DISK_SIZE_GB" -lt 64 ]; then
        PART_COUNT=3
        echo "Создаю 3 раздела (диск 4-32GB)"
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 2GB || error_exit "Ошибка создания extroot"
        sleep 2
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 2GB 4GB || error_exit "Ошибка создания swap"
        sleep 2
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        swapon ${disk}2 2>/dev/null || echo "Предупреждение: не удалось активировать swap"
        
        parted -s ${disk} mkpart "data" ext4 4GB 100% || error_exit "Ошибка создания data"
        sleep 2
        mkfs.ext4 -L "data" ${disk}3 || error_exit "Ошибка создания файловой системы"
        
    else
        PART_COUNT=4
        echo "Создаю 4 раздела (диск 64GB и более)"
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 4GB || error_exit "Ошибка создания extroot"
        sleep 2
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 4GB 8GB || error_exit "Ошибка создания swap"
        sleep 2
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        swapon ${disk}2 2>/dev/null || echo "Предупреждение: не удалось активировать swap"
        
        DATA_SIZE=$((DISK_SIZE_GB - 8))
        DATA_PART1_END=$((8 + DATA_SIZE / 2))
        parted -s ${disk} mkpart "data" ext4 8GB ${DATA_PART1_END}GB || error_exit "Ошибка создания data"
        sleep 2
        mkfs.ext4 -L "data" ${disk}3 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "extra" ext4 ${DATA_PART1_END}GB 100% || error_exit "Ошибка создания extra"
        sleep 2
        mkfs.ext4 -L "extra" ${disk}4 || error_exit "Ошибка создания файловой системы"
    fi
    
    echo "$PART_COUNT"
}

# Функция для удаления старых записей fstab (по UUID или пути)
cleanup_old_fstab_entries() {
    local disk="$1"
    
    echo "Очищаю старые записи fstab..."
    
    # Получаем UUID всех разделов на диске
    local uuids=""
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -b "${disk}${i}" ]; then
            local uuid=$(blkid -s UUID -o value "${disk}${i}" 2>/dev/null)
            if [ -n "$uuid" ]; then
                uuids="$uuids $uuid"
                echo "  UUID раздела ${disk}${i}: $uuid"
            fi
        fi
    done
    
    # Удаляем все записи mount и swap, ссылающиеся на этот диск
    local configs=$(uci show fstab 2>/dev/null | grep -E "fstab\.(@mount\[|@swap\[)" | cut -d'=' -f1 | sed "s/'$//" | sort -u)
    
    for config in $configs; do
        # Получаем device или uuid записи
        local device=$(uci -q get "${config}.device" 2>/dev/null)
        local uuid=$(uci -q get "${config}.uuid" 2>/dev/null)
        local target=$(uci -q get "${config}.target" 2>/dev/null)
        
        # Проверяем, относится ли запись к нашему диску
        local remove=0
        
        # Проверка по device
        if [ -n "$device" ]; then
            if echo "$device" | grep -q "^${disk}[0-9]*$"; then
                remove=1
            fi
        fi
        
        # Проверка по UUID
        if [ -n "$uuid" ]; then
            for disk_uuid in $uuids; do
                if [ "$uuid" = "$disk_uuid" ]; then
                    remove=1
                    break
                fi
            done
        fi
        
        # Проверка по target (монтирование в /mnt/sda*)
        if [ -n "$target" ]; then
            if echo "$target" | grep -q "^/mnt/sda[0-9]*$"; then
                remove=1
            fi
        fi
        
        # Удаляем запись если нужно
        if [ "$remove" -eq 1 ]; then
            uci -q delete "$config"
            if [ -n "$device" ]; then
                echo "  Удалена запись: device=$device"
            elif [ -n "$uuid" ]; then
                echo "  Удалена запись: uuid=$uuid"
            elif [ -n "$target" ]; then
                echo "  Удалена запись: target=$target"
            fi
        fi
    done
}

# Функция для настройки fstab
configure_fstab() {
    local disk="$1"
    local part_count="$2"
    
    echo "Настраиваю fstab..."
    
    # Очищаем старые записи перед созданием новых
    cleanup_old_fstab_entries "$disk"

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
    
    # Сначала показываем текущую таблицу разделов
    echo "Текущая таблица разделов:"
    if command -v parted >/dev/null 2>&1; then
        parted -s "$DISK" print 2>/dev/null || echo "Не удалось отобразить таблицу разделов"
    else
        echo "Утилита parted не найдена"
    fi
    echo ""
    
    # Проверяем существующие разделы
    EXISTING_PARTS=$(count_existing_partitions "$DISK")
    
    if [ "$EXISTING_PARTS" -eq 0 ]; then
        echo "Диск не размечен. Создаю новую разметку..."
        PART_COUNT=$(create_new_partitions "$DISK")
        configure_fstab "$DISK" "$PART_COUNT"
        copy_to_extroot "$DISK"
        
    else
        echo "На диске обнаружены разделы ($EXISTING_PARTS). Проверяю разметку..."
        
        # Используем быструю проверку
        # CHECK_RESULT=$(quick_check "$DISK")
        CHECK_RESULT=$(quick_check "$DISK" | tail -n1)  # Берем последнюю строку
        
        if [ "$CHECK_RESULT" != "false" ] && [ -n "$CHECK_RESULT" ] && [ "$CHECK_RESULT" -gt 0 ]; then
            PART_COUNT="$CHECK_RESULT"
            echo ""
            echo "✅ Существующая разметка корректна. Использую её."
            echo "Обнаружено $PART_COUNT корректных разделов"
            
            configure_fstab "$DISK" "$PART_COUNT"
            
            # Проверяем, нужно ли копировать данные в extroot
            # Ищем точку монтирования overlay
            OVERLAY_MOUNT=$(block info | grep 'MOUNT="[^"]*/overlay"' | cut -d'"' -f2)
            if [ -n "$OVERLAY_MOUNT" ] && [ -b "${DISK}1" ] && ! mountpoint -q "$OVERLAY_MOUNT" 2>/dev/null; then
                MOUNT="$OVERLAY_MOUNT"
                echo "Extroot еще не настроен. Копирую данные..."
                copy_to_extroot "$DISK"
            else
                echo "Extroot уже настроен или точка монтирования не найдена. Пропускаю копирование данных."
            fi
            
        else
            echo ""
            echo "❌ Существующая разметка некорректна или неполная."
            
            # Пробуем автоматическое определение как запасной вариант
            if [ "$CHECK_RESULT" = "false" ]; then
                echo "Пробую автоматическое определение..."
                ALT_CHECK=$(auto_detect_layout "$DISK")
                
                if [ "$ALT_CHECK" != "false" ] && [ -n "$ALT_CHECK" ] && [ "$ALT_CHECK" -gt 0 ]; then
                    PART_COUNT="$ALT_CHECK"
                    echo ""
                    echo "⚠️  Автоматическое определение: найдено $PART_COUNT разделов"
                    echo "Использую эту конфигурацию..."
                    
                    configure_fstab "$DISK" "$PART_COUNT"
                    
                    # Завершаем работу после настройки
                    echo ""
                    echo "Настройка завершена на основе автоматического определения."
                    echo "Рекомендуется проверить корректность настроек."
                    exit 0
                fi
            fi
            
            # Автоматический режим для скриптов
            if [ -t 0 ]; then
                # Интерактивный режим (если есть терминал)
                read -p "Переразметить диск? (Все данные будут удалены!) [y/N]: " CONFIRM
                
                if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                    echo "Переразмечаю диск..."
                    PART_COUNT=$(create_new_partitions "$DISK")
                    configure_fstab "$DISK" "$PART_COUNT"
                    copy_to_extroot "$DISK"
                else
                    echo "Отменено пользователем."
                    exit 0
                fi
            else
                # Автоматический режим (без терминала)
                echo "Автоматический режим: переразмечаю диск..."
                PART_COUNT=$(create_new_partitions "$DISK")
                configure_fstab "$DISK" "$PART_COUNT"
                copy_to_extroot "$DISK"
            fi
        fi
    fi
    
    # Показываем итоговую информацию
    echo ""
    echo "=== Итоговая информация ==="
    echo "Таблица разделов:"
    if command -v parted >/dev/null 2>&1; then
        parted -s "$DISK" print 2>/dev/null || echo "Не удалось отобразить таблицу разделов"
    fi
    
    echo ""
    echo "Монтированные разделы:"
    mount | grep "^$DISK" 2>/dev/null || echo "Нет смонтированных разделов с этого диска"
    
    echo ""
    echo "Настройка fstab завершена успешно!"
    
    # Автоматическая перезагрузка только при изменении разметки
    if [ "$EXISTING_PARTS" -eq 0 ] || [ "$CHECK_RESULT" = "false" ]; then
        echo "Перезагружаюсь для применения изменений..."
        sleep 3
        reboot
    else
        echo "Изменения применены без переразметки."
        echo "Для полного применения изменений в extroot может потребоваться перезагрузка."
        read -p "Перезагрузить сейчас? [y/N]: " REBOOT_NOW
        if [ "$REBOOT_NOW" = "y" ] || [ "$REBOOT_NOW" = "Y" ]; then
            echo "Перезагружаюсь..."
            sleep 3
            reboot
        fi
    fi
}

# Запускаем основной код
main
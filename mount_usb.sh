#!/bin/sh

LOG="/root/mount_usb.log"
echo "=== Начало установки: $(date) ===" > $LOG

DISK="/dev/sda"

# Функция для обработки ошибок
error_exit() {
    echo "Ошибка: $1"  | tee -a $LOG >&2
    exit 1
}

# Функция для принудительной перезагрузки таблицы разделов
force_reload_partitions() {
    local disk="$1"
    
    echo "Принудительно перезагружаю таблицу разделов $disk..." | tee -a $LOG
    
    # 1. Пробуем hdparm
    if command -v hdparm >/dev/null 2>&1; then
        hdparm -z "$disk" 2>/dev/null && echo "  ✅ hdparm -z выполнен" | tee -a $LOG
    fi
    
    # 2. Пробуем blockdev
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --rereadpt "$disk" 2>/dev/null && echo "  ✅ blockdev --rereadpt выполнен" | tee -a $LOG
    fi
    
    # 3. Пробуем partprobe
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$disk" 2>/dev/null && echo "  ✅ partprobe выполнен" | tee -a $LOG
    fi
    
    # 4. Пробуем через /sys
    if [ -f "/sys/block/${disk##*/}/device/rescan" ]; then
        echo 1 > "/sys/block/${disk##*/}/device/rescan" 2>/dev/null && echo "  ✅ sysfs rescan выполнен" | tee -a $LOG
    fi
    
    sleep 2
}

# Функция для агрессивного размонтирования всех разделов диска
unmount_disk_partitions() {
    local disk="$1"
    local mounted_parts=0
    local max_attempts=3
    local attempt=1
    
    # uci -q delete fstab.extroot
    # uci -q delete fstab.swap
    # uci -q delete fstab.data
    # uci -q delete fstab.extra
    # uci commit fstab
    
    echo "Проверка смонтированных разделов на $disk..." | tee -a $LOG
    
    # Сначала отключаем swap на всех разделах диска
    for part in ${disk}*; do
        if [ -b "$part" ] && [ "$part" != "$disk" ]; then
            if swapon -s 2>/dev/null | grep -q "^$part "; then
                echo "  Отключение swap на $part..." | tee -a $LOG
                swapoff "$part" 2>/dev/null
                sleep 1
            fi
        fi
    done
    
    # Многократные попытки размонтирования
    while [ $attempt -le $max_attempts ]; do
        echo "Попытка размонтирования #$attempt..." | tee -a $LOG
        local unmounted=0
        
        for part in ${disk}*; do
            if [ -b "$part" ] && [ "$part" != "$disk" ]; then
                # Проверяем, смонтирован ли раздел
                if mount | grep -q "^$part "; then
                    mounted_parts=$((mounted_parts + 1))
                    echo "  Размонтирование $part..." | tee -a $LOG
                    
                    # Пытаемся размонтировать всеми способами
                    umount -f "$part" 2>/dev/null || \
                    umount -l "$part" 2>/dev/null || \
                    umount "$part" 2>/dev/null
                    
                    # Проверяем результат
                    if mount | grep -q "^$part "; then
                        echo "  ⚠️  Не удалось размонтировать $part" | tee -a $LOG
                    else
                        echo "  ✅ $part размонтирован" | tee -a $LOG
                        unmounted=$((unmounted + 1))
                    fi
                fi
            fi
        done
        
        if [ $unmounted -eq 0 ]; then
            echo "  Нет смонтированных разделов" | tee -a $LOG
            break
        fi
        
        attempt=$((attempt + 1))
        sleep 2
    done
    
    # Проверяем, остались ли смонтированные разделы
    local remaining=0
    for part in ${disk}*; do
        if [ -b "$part" ] && [ "$part" != "$disk" ]; then
            if mount | grep -q "^$part "; then
                remaining=$((remaining + 1))
                echo "  ❌ Раздел $part всё ещё смонтирован" | tee -a $LOG
            fi
        fi
    done
    
    if [ $remaining -gt 0 ]; then
        echo "  ⚠️  Осталось $remaining смонтированных разделов" | tee -a $LOG
        return 1
    else
        echo "  ✅ Все разделы размонтированы" | tee -a $LOG
        return 0
    fi
}

# Функция для полной остановки использования диска
stop_disk_usage() {
    local disk="$1"
    
    echo "Останавливаю все процессы, использующие $disk..." | tee -a $LOG
    
    # Находим все процессы, которые используют диск
    if command -v lsof >/dev/null 2>&1; then
        lsof "$disk"* 2>/dev/null | tail -n +2 | awk '{print $2}' | sort -u | while read pid; do
            echo "  Завершение процесса PID: $pid" | tee -a $LOG
            kill -9 "$pid" 2>/dev/null
        done
    fi
    
    # Альтернативный метод через fuser
    if command -v fuser >/dev/null 2>&1; then
        fuser -km "$disk"* 2>/dev/null
        sleep 1
    fi
    
    sleep 2
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
    
    echo "$count" | tee -a $LOG
}

# Функция для быстрой проверки (основная)
quick_check() {
    local disk="$1"
    
    echo "Быстрая проверка разметки..." | tee -a $LOG
    
    # Проверяем наличие parted
    if ! command -v parted >/dev/null 2>&1; then
        echo "  ⚠️ Утилита parted не найдена" | tee -a $LOG
        echo "false" | tee -a $LOG
        return
    fi
    
    # Проверяем наличие GPT
    if ! parted -s "$disk" print 2>/dev/null | grep -q "Partition Table:.*gpt"; then
        echo "  ❌ Таблица разделов не GPT" | tee -a $LOG
        echo "false" | tee -a $LOG
        return
    fi
    
    # Получаем список разделов
    local partitions=$(parted -s "$disk" print 2>/dev/null | awk 'NR > 7 && /^ [0-9]/ {print $1 " " $6 " " $5}')
    
    if [ -z "$partitions" ]; then
        echo "  Диск не размечен" | tee -a $LOG
        echo "0" | tee -a $LOG
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
                        echo "  ✅ Раздел 1: $name ($fstype) - корректный" | tee -a $LOG
                        echo "1" >> "$result_file"
                    else
                        echo "  ❌ Раздел 1: $name ($fstype) - ожидается: extroot, ext4" | tee -a $LOG
                    fi
                    ;;
                2)
                    if [ "$name" = "swap" ] && echo "$fstype" | grep -q -E "swap|linux-swap"; then
                        echo "  ✅ Раздел 2: $name ($fstype) - корректный" | tee -a $LOG
                        echo "1" >> "$result_file"
                    else
                        echo "  ❌ Раздел 2: $name ($fstype) - ожидается: swap, swap" | tee -a $LOG
                    fi
                    ;;
                3)
                    if [ "$name" = "data" ] && echo "$fstype" | grep -q "ext4"; then
                        echo "  ✅ Раздел 3: $name ($fstype) - корректный" | tee -a $LOG
                        echo "1" >> "$result_file"
                    elif [ "$name" = "extra" ] && echo "$fstype" | grep -q "ext4"; then
                        echo "  ✅ Раздел 3: $name ($fstype) - корректный" | tee -a $LOG
                        echo "1" >> "$result_file"
                    else
                        echo "  ❌ Раздел 3: $name ($fstype) - ожидается: data или extra, ext4" | tee -a $LOG
                    fi
                    ;;
                4)
                    if [ "$name" = "extra" ] && echo "$fstype" | grep -q "ext4"; then
                        echo "  ✅ Раздел 4: $name ($fstype) - корректный" | tee -a $LOG
                        echo "1" >> "$result_file"
                    else
                        echo "  ❌ Раздел 4: $name ($fstype) - ожидается: extra, ext4" | tee -a $LOG
                    fi
                    ;;
            esac
        else
            echo "  ⚠️  Раздел $num: пропускается (поддерживаются только разделы 1-4)" | tee -a $LOG
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
        echo "  ❌ Не найдено корректных разделов" | tee -a $LOG
        echo "false" | tee -a $LOG
    elif [ "$continuous" = "false" ]; then
        echo "  ⚠️  Нарушена последовательность разделов" | tee -a $LOG
        echo "$valid_count" | tee -a $LOG
    else
        echo "  ✅ Найдено $valid_count корректных разделов" | tee -a $LOG
        echo "$valid_count" | tee -a $LOG
    fi
}

# Функция для автоматического определения конфигурации
auto_detect_layout() {
    local disk="$1"
    
    echo "Автоматическое определение конфигурации диска..." | tee -a $LOG
    
    # Получаем информацию из parted
    if ! command -v parted >/dev/null 2>&1; then
        echo "  ⚠️ Parted не найден, использую простой подсчет" | tee -a $LOG
        local count=$(count_existing_partitions "$disk")
        echo "$count" | tee -a $LOG
        return
    fi
    
    local parted_info=$(parted -s "$disk" print 2>/dev/null)
    local gpt_check=$(echo "$parted_info" | grep -c "Partition Table:.*gpt")
    
    if [ "$gpt_check" -eq 0 ]; then
        echo "  ❌ Таблица разделов не GPT" | tee -a $LOG
        echo "false" | tee -a $LOG
        return
    fi
    
    # Извлекаем информацию о разделах
    local partitions=$(echo "$parted_info" | awk 'NR > 7 && /^ [0-9]/ {print $1 "|" $6 "|" $5}')
    
    if [ -z "$partitions" ]; then
        echo "  Диск не размечен" | tee -a $LOG
        echo "0" | tee -a $LOG
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
        echo "  Раздел 1: $(cat "$part1_file")" | tee -a $LOG
    fi
    
    if [ -s "$part2_file" ]; then
        part_count=$((part_count + 1))
        echo "  Раздел 2: $(cat "$part2_file")" | tee -a $LOG
    fi
    
    if [ -s "$part3_file" ]; then
        part_count=$((part_count + 1))
        echo "  Раздел 3: $(cat "$part3_file")" | tee -a $LOG
    fi
    
    if [ -s "$part4_file" ]; then
        part_count=$((part_count + 1))
        echo "  Раздел 4: $(cat "$part4_file")" | tee -a $LOG
    fi
    
    # Удаляем временные файлы
    rm -f "$part1_file" "$part2_file" "$part3_file" "$part4_file"
    
    if [ "$part_count" -eq 0 ]; then
        echo "  ❌ Не удалось определить конфигурацию" | tee -a $LOG
        echo "false" | tee -a $LOG
    else
        echo "  ✅ Обнаружена конфигурация с $part_count разделами" | tee -a $LOG
        echo "$part_count" | tee -a $LOG
    fi
}

# Функция для создания новой разметки
create_new_partitions() {
    local disk="$1"
    
    echo "Создаю новую разметку на диске $disk..." | tee -a $LOG
    
    # Получаем размер диска
    DISK_SIZE_BYTES=$(get_disk_size "$disk") || error_exit "Не удалось определить размер диска"
    
    if [ -z "$DISK_SIZE_BYTES" ] || [ "$DISK_SIZE_BYTES" -eq 0 ]; then
        error_exit "Не удалось определить размер диска"
    fi
    
    # Конвертируем в гигабайты
    DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
    
    echo "Размер диска: ${DISK_SIZE_GB}GB" | tee -a $LOG
    
    # Определяем количество разделов в зависимости от размера
    if [ "$DISK_SIZE_GB" -lt 1 ]; then
        error_exit "Диск слишком мал (меньше 1GB)"
    elif [ "$DISK_SIZE_GB" -lt 2 ]; then
        PART_COUNT=1
        echo "Создаю 1 раздел (диск менее 2GB)" | tee -a $LOG
        
        # Сначала убеждаемся, что диск не используется
        force_reload_partitions "$disk"
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        sleep 1
        parted -s ${disk} mkpart "extroot" ext4 2048s 100% || error_exit "Ошибка создания раздела"
        sleep 2
        force_reload_partitions "$disk"
        sleep 1
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
    elif [ "$DISK_SIZE_GB" -lt 4 ]; then
        PART_COUNT=2
        echo "Создаю 2 раздела (диск 2-3GB)" | tee -a $LOG
        
        force_reload_partitions "$disk"
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        sleep 1
        
        EXTROOT_END=1
        parted -s ${disk} mkpart "extroot" ext4 2048s ${EXTROOT_END}GB || error_exit "Ошибка создания extroot"
        sleep 2
        force_reload_partitions "$disk"
        sleep 1
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap ${EXTROOT_END}GB 100% || error_exit "Ошибка создания swap"
        sleep 2
        force_reload_partitions "$disk"
        sleep 1
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        
    elif [ "$DISK_SIZE_GB" -lt 64 ]; then
        PART_COUNT=3
        echo "Создаю 3 раздела (диск 4-32GB)" | tee -a $LOG
        
        force_reload_partitions "$disk"
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        sleep 1
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 1GB || error_exit "Ошибка создания extroot"
        sleep 2
        force_reload_partitions "$disk"
        sleep 1
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 1GB 2GB || error_exit "Ошибка создания swap"
        sleep 2
        force_reload_partitions "$disk"
        sleep 1
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        
        parted -s ${disk} mkpart "data" ext4 2GB 100% || error_exit "Ошибка создания data"
        sleep 2
        force_reload_partitions "$disk"
        sleep 1
        mkfs.ext4 -L "data" ${disk}3 || error_exit "Ошибка создания файловой системы"
        
    else
        PART_COUNT=4
        echo "Создаю 4 раздела (диск 64GB и более)" | tee -a $LOG
        
        force_reload_partitions "$disk"
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        sleep 1
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 1GB || error_exit "Ошибка создания extroot"
        sleep 2
        force_reload_partitions "$disk"
        sleep 1
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 1GB 2GB || error_exit "Ошибка создания swap"
        sleep 2
        force_reload_partitions "$disk"
        sleep 1
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        
        DATA_PART1_END=8
        parted -s ${disk} mkpart "data" ext4 2GB ${DATA_PART1_END}GB || error_exit "Ошибка создания data"
        sleep 2
        force_reload_partitions "$disk"
        sleep 1
        mkfs.ext4 -L "data" ${disk}3 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "extra" ext4 ${DATA_PART1_END}GB 100% || error_exit "Ошибка создания extra"
        sleep 2
        force_reload_partitions "$disk"
        sleep 1
        mkfs.ext4 -L "extra" ${disk}4 || error_exit "Ошибка создания файловой системы"
    fi
    
    echo "$PART_COUNT" | tee -a $LOG
}

# Функция для удаления старых записей fstab (по UUID или пути)
cleanup_old_fstab_entries() {
    local disk="$1"
    
    echo "Очищаю старые записи fstab..." | tee -a $LOG
    
    # Получаем UUID всех разделов на диске
    local uuids=""
    echo "Поиск разделов на диске $disk:" | tee -a $LOG
    
    # Проверяем существование базового диска
    if [ ! -b "$disk" ]; then
        echo "  Диск $disk не найден" | tee -a $LOG
        return
    fi
    
    # Ищем все разделы диска
    for i in 1 2 3 4 5 6 7 8 9; do
        local partition="${disk}${i}"
        if [ -b "$partition" ]; then
            echo "  Найден раздел: $partition" | tee -a $LOG
            local uuid="$(block info ${DISK}${i} | grep -o -e 'UUID="\S*"')"
                        #$(blkid -s UUID -o value "$partition" 2>/dev/null)
            if [ -n "$uuid" ]; then
                echo "    UUID: $uuid" | tee -a $LOG
                uuids="$uuids $uuid"
            else
                echo "    UUID: не определен" | tee -a $LOG
            fi
        fi
    done
    
    echo "Список UUID для удаления: $uuids" | tee -a $LOG
    
    # Получаем все конфигурации fstab
    if ! uci show fstab >/dev/null 2>&1; then
        echo "  Конфигурация fstab не найдена" | tee -a $LOG
        return
    fi
    
    # Ищем все записи mount и swap
    local configs=$(uci show fstab 2>/dev/null | grep -E "fstab\.(@mount\[|@swap\[|fstab\.[a-zA-Z])" | cut -d'=' -f1 | sed "s/'$//" | sort -u)
    
    echo "Найдено записей в fstab: $(echo "$configs" | wc -l)" | tee -a $LOG
    
    for config in $configs; do
        # Получаем device или uuid записи
        local device=$(uci -q get "${config}.device" 2>/dev/null)
        local uuid=$(uci -q get "${config}.uuid" 2>/dev/null)
        local target=$(uci -q get "${config}.target" 2>/dev/null)
        
        echo "  Проверяю запись $config:" | tee -a $LOG
        echo "    device=$device" | tee -a $LOG
        echo "    uuid=$uuid" | tee -a $LOG
        echo "    target=$target" | tee -a $LOG
        
        # Проверяем, относится ли запись к нашему диску
        local remove=0
        
        # 1. Проверка по device (прямое совпадение с /dev/sda*)
        if [ -n "$device" ]; then
            if echo "$device" | grep -q "^${disk}[0-9]*$"; then
                remove=1
                echo "    -> Удалить: совпадение по device" | tee -a $LOG
            fi
        fi
        
        # 2. Проверка по UUID
        if [ -n "$uuid" ] && [ "$remove" -eq 0 ]; then
            for disk_uuid in $uuids; do
                if [ "$uuid" = "$disk_uuid" ]; then
                    remove=1
                    echo "    -> Удалить: совпадение по UUID $disk_uuid" | tee -a $LOG
                    break
                fi
            done
        fi
        
        # 3. Проверка по target (монтирование в /mnt/sda*)
        if [ -n "$target" ] && [ "$remove" -eq 0 ]; then
            local disk_name=$(basename "$disk")  # "sda"
            if echo "$target" | grep -q "^/mnt/${disk_name}[0-9]*$"; then
                remove=1
                echo "    -> Удалить: совпадение по target" | tee -a $LOG
            fi
        fi
        
        # 4. Дополнительная проверка: если устройство существует, проверяем его реальный UUID
        if [ -n "$device" ] && [ -b "$device" ] && [ "$remove" -eq 0 ]; then
            local real_uuid=$(blkid -s UUID -o value "$device" 2>/dev/null)
            if [ -n "$real_uuid" ]; then
                for disk_uuid in $uuids; do
                    if [ "$real_uuid" = "$disk_uuid" ]; then
                        remove=1
                        echo "    -> Удалить: реальный UUID устройства совпадает" | tee -a $LOG
                        break
                    fi
                done
            fi
        fi
        
        # Удаляем запись если нужно
        if [ "$remove" -eq 1 ]; then
            uci -q delete "$config"
            echo "    УДАЛЕНО: $config" | tee -a $LOG
        else
            echo "    ОСТАВЛЕНО: не относится к диску $disk" | tee -a $LOG
        fi
    done
    
    # Дополнительно: удаляем все записи с enabled="0" для нашего диска
    echo "Проверка записей с enabled=0..." | tee -a $LOG
    for config in $configs; do
        local enabled=$(uci -q get "${config}.enabled" 2>/dev/null)
        local device=$(uci -q get "${config}.device" 2>/dev/null)
        local target=$(uci -q get "${config}.target" 2>/dev/null)
        
        if [ "$enabled" = "0" ]; then
            # Проверяем, относится ли к нашему диску
            local should_delete=0
            
            if [ -n "$device" ] && echo "$device" | grep -q "^${disk}[0-9]*$"; then
                should_delete=1
            elif [ -n "$target" ] && echo "$target" | grep -q "^/mnt/$(basename $disk)[0-9]*$"; then
                should_delete=1
            fi
            
            if [ "$should_delete" -eq 1 ]; then
                uci -q delete "$config"
                echo "  Удалена отключенная запись: $config" | tee -a $LOG
            fi
        fi
    done
        
    # Удаляем старые настройки для этого диска
    uci -q delete fstab.extroot
    uci -q delete fstab.swap
    uci -q delete fstab.data
    uci -q delete fstab.extra

    echo "Очистка завершена" | tee -a $LOG
}

# Функция для настройки fstab
configure_fstab() {
    local disk="$1"
    local part_count="$2"
    
    echo "Настраиваю fstab..." | tee -a $LOG
    
    # Очищаем старые записи перед созданием новых
    cleanup_old_fstab_entries "$disk"

    # Configure the extroot mount entry
    eval $(block info | grep -o -e 'MOUNT="\S*/overlay"')
    
    # Настраиваем extroot (всегда должен быть)
    if [ -b "${disk}1" ]; then
        uci set fstab.extroot="mount"
        uci set fstab.extroot.device="${disk}1"
        uci set fstab.extroot.target="${MOUNT}"
        uci set fstab.extroot.enabled="1"
        echo "  Настроен extroot: ${disk}1" | tee -a $LOG
    fi
    
    # Настраиваем swap если есть
    if [ -b "${disk}2" ]; then
        uci set fstab.swap="swap"
        uci set fstab.swap.device="${disk}2"
        uci set fstab.swap.enabled="1"
        echo "  Настроен swap: ${disk}2" | tee -a $LOG
    fi
    
    # Настраиваем data если есть
    if [ -b "${disk}3" ]; then
        uci set fstab.data="mount"
        uci set fstab.data.device="${disk}3"
        uci set fstab.data.target="/mnt/data"
        uci set fstab.data.enabled="1"
        
        mkdir -p /mnt/data
        echo "  Настроен data: ${disk}3" | tee -a $LOG
    fi
    
    # Настраиваем extra если есть
    if [ -b "${disk}4" ]; then
        uci set fstab.extra="mount"
        uci set fstab.extra.device="${disk}4"
        uci set fstab.extra.target="/mnt/extra"
        uci set fstab.extra.enabled="1"
        
        mkdir -p /mnt/extra
        echo "  Настроен extra: ${disk}4" | tee -a $LOG
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
    
    echo "Копирую данные в extroot..." | tee -a $LOG
    
    if mount "${disk}1" /mnt 2>/dev/null; then
        if [ -d "${MOUNT}" ]; then
            tar -C "${MOUNT}" -cvf - . | tar -C /mnt -xf - 2>/dev/null
            if [ $? -eq 0 ]; then
                echo "  Данные успешно скопированы" | tee -a $LOG
            else
                echo "  Предупреждение: возникли ошибки при копировании" | tee -a $LOG
            fi
        else
            echo "  Предупреждение: исходная точка монтирования не найдена" | tee -a $LOG
        fi
        umount /mnt 2>/dev/null
    else
        echo "  Предупреждение: не удалось смонтировать extroot для копирования данных" | tee -a $LOG
    fi
}

# Основной код
main() {
    # Проверяем существование диска
    [ -b "$DISK" ] || error_exit "Диск $DISK не найден"
    
    echo "=== Настройка диска $DISK ===" | tee -a $LOG
    
    # Сначала останавливаем все процессы, использующие диск
    stop_disk_usage "$DISK"
    
    # Затем размонтируем все разделы диска
    if ! unmount_disk_partitions "$DISK"; then
        echo "⚠️  Предупреждение: не удалось размонтировать все разделы, продолжаем..." | tee -a $LOG
    fi
    
    # Принудительно перезагружаем таблицу разделов
    force_reload_partitions "$DISK"
    
    # Сначала показываем текущую таблицу разделов
    echo "Текущая таблица разделов:" | tee -a $LOG
    if command -v parted >/dev/null 2>&1; then
        parted -s "$DISK" print 2>/dev/null || echo "Не удалось отобразить таблицу разделов"
    else
        echo "Утилита parted не найдена" | tee -a $LOG
    fi
    echo "" | tee -a $LOG
    
    # Проверяем существующие разделы
    EXISTING_PARTS=$(count_existing_partitions "$DISK")
    
    if [ "$EXISTING_PARTS" -eq 0 ]; then
        echo "Диск не размечен. Создаю новую разметку..." | tee -a $LOG
        PART_COUNT=$(create_new_partitions "$DISK")
        configure_fstab "$DISK" "$PART_COUNT"
        copy_to_extroot "$DISK"
        
    else
        echo "На диске обнаружены разделы ($EXISTING_PARTS). Проверяю разметку..." | tee -a $LOG
        
        # Используем быструю проверку
        CHECK_RESULT=$(quick_check "$DISK" | tail -n1)  # Берем последнюю строку
        
        if [ "$CHECK_RESULT" != "false" ] && [ -n "$CHECK_RESULT" ] && [ "$CHECK_RESULT" -gt 0 ]; then
            PART_COUNT="$CHECK_RESULT"
            echo "" | tee -a $LOG
            echo "✅ Существующая разметка корректна. Использую её." | tee -a $LOG
            echo "Обнаружено $PART_COUNT корректных разделов" | tee -a $LOG
            
            configure_fstab "$DISK" "$PART_COUNT"
            
            # Проверяем, нужно ли копировать данные в extroot
            # Ищем точку монтирования overlay
            OVERLAY_MOUNT=$(block info | grep 'MOUNT="[^"]*/overlay"' | cut -d'"' -f2)
            if [ -n "$OVERLAY_MOUNT" ] && [ -b "${DISK}1" ] && ! mountpoint -q "$OVERLAY_MOUNT" 2>/dev/null; then
                MOUNT="$OVERLAY_MOUNT"
                echo "Extroot еще не настроен. Копирую данные..." | tee -a $LOG
                copy_to_extroot "$DISK"
            else
                echo "Extroot уже настроен или точка монтирования не найдена. Пропускаю копирование данных." | tee -a $LOG
            fi
            
        else
            echo "" | tee -a $LOG
            echo "❌ Существующая разметка некорректна или неполная." | tee -a $LOG
            
            # Пробуем автоматическое определение как запасной вариант
            if [ "$CHECK_RESULT" = "false" ]; then
                echo "Пробую автоматическое определение..." | tee -a $LOG
                ALT_CHECK=$(auto_detect_layout "$DISK")
                
                if [ "$ALT_CHECK" != "false" ] && [ -n "$ALT_CHECK" ] && [ "$ALT_CHECK" -gt 0 ]; then
                    PART_COUNT="$ALT_CHECK"
                    echo "" | tee -a $LOG
                    echo "⚠️  Автоматическое определение: найдено $PART_COUNT разделов" | tee -a $LOG
                    echo "Использую эту конфигурацию..." | tee -a $LOG
                    
                    configure_fstab "$DISK" "$PART_COUNT"
                    
                    # Завершаем работу после настройки
                    echo "" | tee -a $LOG
                    echo "Настройка завершена на основе автоматического определения." | tee -a $LOG
                    echo "Рекомендуется проверить корректность настроек." | tee -a $LOG
                    exit 0
                fi
            fi
            
            # Автоматический режим для скриптов
            if [ -t 0 ]; then
                # Интерактивный режим (если есть терминал)
                read -p "Переразметить диск? (Все данные будут удалены!) [y/N]: " CONFIRM
                
                if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                    echo "Переразмечаю диск..." | tee -a $LOG
                    PART_COUNT=$(create_new_partitions "$DISK")
                    configure_fstab "$DISK" "$PART_COUNT"
                    copy_to_extroot "$DISK"
                else
                    echo "Отменено пользователем." | tee -a $LOG
                    exit 0
                fi
            else
                # Автоматический режим (без терминала)
                echo "Автоматический режим: переразмечаю диск..." | tee -a $LOG
                PART_COUNT=$(create_new_partitions "$DISK")
                configure_fstab "$DISK" "$PART_COUNT"
                copy_to_extroot "$DISK"
            fi
        fi
    fi
    
    # Показываем итоговую информацию
    echo "" | tee -a $LOG
    echo "=== Итоговая информация ===" | tee -a $LOG
    echo "Таблица разделов:" | tee -a $LOG
    if command -v parted >/dev/null 2>&1; then
        parted -s "$DISK" print 2>/dev/null || echo "Не удалось отобразить таблицу разделов"
    fi
    
    echo "" | tee -a $LOG
    echo "Монтированные разделы:" | tee -a $LOG
    mount | grep "^$DISK" 2>/dev/null || echo "Нет смонтированных разделов с этого диска"
    
    echo "" | tee -a $LOG
    echo "Настройка fstab завершена успешно!" | tee -a $LOG
    
    # Автоматическая перезагрузка всегда при изменении разметки
    if [ "$EXISTING_PARTS" -eq 0 ] || [ "$CHECK_RESULT" = "false" ]; then
        if [ -t 0 ]; then
            echo "Перезагружаюсь для применения изменений..." | tee -a $LOG
            sleep 3
            reboot
        fi
    else
        echo "Изменения применены без переразметки." | tee -a $LOG
        echo "Для полного применения изменений в extroot может потребоваться перезагрузка." | tee -a $LOG
        if [ -t 0 ]; then
            read -p "Перезагрузить сейчас? [y/N]: " REBOOT_NOW
            if [ "$REBOOT_NOW" = "y" ] || [ "$REBOOT_NOW" = "Y" ]; then
                echo "Перезагружаюсь..." | tee -a $LOG
                sleep 3
                reboot
            fi
        else
            echo "Перезагружаюсь..." | tee -a $LOG
#            reboot
        fi
    fi
}

# Запускаем основной код
main
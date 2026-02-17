#!/bin/sh

# ============================================================================
# Функция для обработки ошибок
# ============================================================================
error_exit() {
    log_error "$1"
    exit 1
}

# ============================================================================
# Функция для принудительной перезагрузки таблицы разделов
# ============================================================================
force_reload_partitions() {
    local disk="$1"
    
    log_info "Принудительно перезагружаю таблицу разделов $disk..."
    
    # 1. Пробуем hdparm
    if command -v hdparm >/dev/null 2>&1; then
        hdparm -z "$disk" 2>/dev/null && log_debug "  ✅ hdparm -z выполнен"
    fi
    
    # 2. Пробуем blockdev
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --rereadpt "$disk" 2>/dev/null && log_debug "  ✅ blockdev --rereadpt выполнен"
    fi
    
    # 3. Пробуем partprobe
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$disk" 2>/dev/null && log_debug "  ✅ partprobe выполнен"
    fi
    
    # 4. Пробуем через /sys
    if [ -f "/sys/block/${disk##*/}/device/rescan" ]; then
        echo 1 > "/sys/block/${disk##*/}/device/rescan" 2>/dev/null && log_debug "  ✅ sysfs rescan выполнен"
    fi
    
    sleep 2
}

# ============================================================================
# Функция для агрессивного размонтирования всех разделов диска
# ============================================================================
unmount_disk_partitions() {
    local disk="$1"
    local mounted_parts=0
    local max_attempts=3
    local attempt=1
    
    log_info "Проверка смонтированных разделов на $disk..."
    
    # Сначала отключаем swap на всех разделах диска
    for part in ${disk}*; do
        if [ -b "$part" ] && [ "$part" != "$disk" ]; then
            if swapon -s 2>/dev/null | grep -q "^$part "; then
                log_debug "  Отключение swap на $part..."
                swapoff "$part" 2>/dev/null
                sleep 1
            fi
        fi
    done
    
    # Многократные попытки размонтирования
    while [ $attempt -le $max_attempts ]; do
        log_debug "Попытка размонтирования #$attempt..."
        local unmounted=0
        
        for part in ${disk}*; do
            if [ -b "$part" ] && [ "$part" != "$disk" ]; then
                # Проверяем, смонтирован ли раздел
                if mount | grep -q "^$part "; then
                    mounted_parts=$((mounted_parts + 1))
                    log_debug "  Размонтирование $part..."
                    
                    # Пытаемся размонтировать всеми способами
                    umount -f "$part" 2>/dev/null || \
                    umount -l "$part" 2>/dev/null || \
                    umount "$part" 2>/dev/null
                    
                    # Проверяем результат
                    if mount | grep -q "^$part "; then
                        log_warn "  ⚠️  Не удалось размонтировать $part"
                    else
                        log_debug "  ✅ $part размонтирован"
                        unmounted=$((unmounted + 1))
                    fi
                fi
            fi
        done
        
        if [ $unmounted -eq 0 ]; then
            log_debug "  Нет смонтированных разделов"
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
                log_error "  ❌ Раздел $part всё ещё смонтирован"
            fi
        fi
    done
    
    if [ $remaining -gt 0 ]; then
        log_warn "  ⚠️  Осталось $remaining смонтированных разделов"
        return 1
    else
        log_success "  ✅ Все разделы размонтированы"
        return 0
    fi
}

# ============================================================================
# Функция для полной остановки использования диска
# ============================================================================
stop_disk_usage() {
    local disk="$1"
    
    log_info "Останавливаю все процессы, использующие $disk..."
    
    # Находим все процессы, которые используют диск
    if command -v lsof >/dev/null 2>&1; then
        lsof "$disk"* 2>/dev/null | tail -n +2 | awk '{print $2}' | sort -u | while read pid; do
            log_debug "  Завершение процесса PID: $pid"
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

# ============================================================================
# Функция для определения размера диска
# ============================================================================
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

# ============================================================================
# Функция для подсчета существующих разделов
# ============================================================================
count_existing_partitions() {
    local disk="$1"
    local count=0
    
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -b "${disk}${i}" ]; then
            count=$((count + 1))
        fi
    done
    
    log_debug "Найдено существующих разделов: $count"
    echo "$count"
}

# ============================================================================
# Функция для быстрой проверки (основная)
# ============================================================================
quick_check() {
    local disk="$1"
    
    log_info "Быстрая проверка разметки..."
    
    # Проверяем наличие parted
    if ! command -v parted >/dev/null 2>&1; then
        log_warn "  ⚠️ Утилита parted не найдена"
        echo "false"
        return
    fi
    
    # Проверяем наличие GPT
    if ! parted -s "$disk" print 2>/dev/null | grep -q "Partition Table:.*gpt"; then
        log_error "  ❌ Таблица разделов не GPT"
        echo "false"
        return
    fi
    
    # Получаем список разделов
    local partitions=$(parted -s "$disk" print 2>/dev/null | awk 'NR > 7 && /^ [0-9]/ {print $1 " " $6 " " $5}')
    
    if [ -z "$partitions" ]; then
        log_info "  Диск не размечен"
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
                        log_success "  ✅ Раздел 1: $name ($fstype) - корректный"
                        echo "1" >> "$result_file"
                    else
                        log_error "  ❌ Раздел 1: $name ($fstype) - ожидается: extroot, ext4"
                    fi
                    ;;
                2)
                    if [ "$name" = "swap" ] && echo "$fstype" | grep -q -E "swap|linux-swap"; then
                        log_success "  ✅ Раздел 2: $name ($fstype) - корректный"
                        echo "1" >> "$result_file"
                    else
                        log_error "  ❌ Раздел 2: $name ($fstype) - ожидается: swap, swap"
                    fi
                    ;;
                3)
                    if [ "$name" = "data" ] && echo "$fstype" | grep -q "ext4"; then
                        log_success "  ✅ Раздел 3: $name ($fstype) - корректный"
                        echo "1" >> "$result_file"
                    elif [ "$name" = "extra" ] && echo "$fstype" | grep -q "ext4"; then
                        log_success "  ✅ Раздел 3: $name ($fstype) - корректный"
                        echo "1" >> "$result_file"
                    else
                        log_error "  ❌ Раздел 3: $name ($fstype) - ожидается: data или extra, ext4"
                    fi
                    ;;
                4)
                    if [ "$name" = "extra" ] && echo "$fstype" | grep -q "ext4"; then
                        log_success "  ✅ Раздел 4: $name ($fstype) - корректный"
                        echo "1" >> "$result_file"
                    else
                        log_error "  ❌ Раздел 4: $name ($fstype) - ожидается: extra, ext4"
                    fi
                    ;;
            esac
        else
            log_warn "  ⚠️  Раздел $num: пропускается (поддерживаются только разделы 1-4)"
        fi
    done
    
    # Подсчитываем результаты
    if [ -f "$result_file" ]; then
        valid_count=$(wc -l < "$result_file" 2>/dev/null)
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
        log_error "  ❌ Не найдено корректных разделов"
        echo "false"
    elif [ "$continuous" = "false" ]; then
        log_warn "  ⚠️  Нарушена последовательность разделов"
        echo "$valid_count"
    else
        log_success "  ✅ Найдено $valid_count корректных разделов"
        echo "$valid_count"
    fi
}

# ============================================================================
# Функция для автоматического определения конфигурации
# ============================================================================
auto_detect_layout() {
    local disk="$1"
    
    log_info "Автоматическое определение конфигурации диска..."
    
    # Получаем информацию из parted
    if ! command -v parted >/dev/null 2>&1; then
        log_warn "  ⚠️ Parted не найден, использую простой подсчет"
        local count=$(count_existing_partitions "$disk")
        echo "$count"
        return
    fi
    
    local parted_info=$(parted -s "$disk" print 2>/dev/null)
    local gpt_check=$(echo "$parted_info" | grep -c "Partition Table:.*gpt")
    
    if [ "$gpt_check" -eq 0 ]; then
        log_error "  ❌ Таблица разделов не GPT"
        echo "false"
        return
    fi
    
    # Извлекаем информацию о разделах
    local partitions=$(echo "$parted_info" | awk 'NR > 7 && /^ [0-9]/ {print $1 "|" $6 "|" $5}')
    
    if [ -z "$partitions" ]; then
        log_info "  Диск не размечен"
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
        log_debug "  Раздел 1: $(cat "$part1_file")"
    fi
    
    if [ -s "$part2_file" ]; then
        part_count=$((part_count + 1))
        log_debug "  Раздел 2: $(cat "$part2_file")"
    fi
    
    if [ -s "$part3_file" ]; then
        part_count=$((part_count + 1))
        log_debug "  Раздел 3: $(cat "$part3_file")"
    fi
    
    if [ -s "$part4_file" ]; then
        part_count=$((part_count + 1))
        log_debug "  Раздел 4: $(cat "$part4_file")"
    fi
    
    # Удаляем временные файлы
    rm -f "$part1_file" "$part2_file" "$part3_file" "$part4_file"
    
    if [ "$part_count" -eq 0 ]; then
        log_error "  ❌ Не удалось определить конфигурацию"
        echo "false"
    else
        log_success "  ✅ Обнаружена конфигурация с $part_count разделами"
        echo "$part_count"
    fi
}

# ============================================================================
# Функция для создания новой разметки
# ============================================================================
create_new_partitions() {
    local disk="$1"
    
    log_info "Создаю новую разметку на диске $disk..."
    
    # Получаем размер диска
    DISK_SIZE_BYTES=$(get_disk_size "$disk") || error_exit "Не удалось определить размер диска"
    
    if [ -z "$DISK_SIZE_BYTES" ] || [ "$DISK_SIZE_BYTES" -eq 0 ]; then
        error_exit "Не удалось определить размер диска"
    fi
    
    # Конвертируем в гигабайты
    DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
    
    log_info "Размер диска: ${DISK_SIZE_GB}GB"
    
    # Определяем количество разделов в зависимости от размера
    if [ "$DISK_SIZE_GB" -lt 1 ]; then
        error_exit "Диск слишком мал (меньше 1GB)"
    elif [ "$DISK_SIZE_GB" -lt 2 ]; then
        PART_COUNT=1
        log_info "Создаю 1 раздел (диск менее 2GB)"
        
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
        log_info "Создаю 2 раздела (диск 2-3GB)"
        
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
        log_info "Создаю 3 раздела (диск 4-32GB)"
        
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
        log_info "Создаю 4 раздела (диск 64GB и более)"
        
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
    
    log_success "Создано $PART_COUNT разделов"
}

# ============================================================================
# Функция для удаления старых записей fstab (по UUID или пути)
# ============================================================================
cleanup_old_fstab_entries() {
    local disk="$1"
    
    log_info "Очищаю старые записи fstab..."
    
    # Получаем UUID всех разделов на диске
    local uuids=""
    log_debug "Поиск разделов на диске $disk:"
    
    # Проверяем существование базового диска
    if [ ! -b "$disk" ]; then
        log_warn "  Диск $disk не найден"
        return
    fi
    
    # Ищем все разделы диска
    for i in 1 2 3 4 5 6 7 8 9; do
        local partition="${disk}${i}"
        if [ -b "$partition" ]; then
            log_debug "  Найден раздел: $partition"
            local uuid="$(block info ${DISK}${i} | grep -o -e 'UUID="\S*"')"
            if [ -n "$uuid" ]; then
                log_debug "    UUID: $uuid"
                uuids="$uuids $uuid"
            else
                log_debug "    UUID: не определен"
            fi
        fi
    done
    
    log_debug "Список UUID для удаления: $uuids"
    
    # Получаем все конфигурации fstab
    if ! uci show fstab >/dev/null 2>&1; then
        log_info "  Конфигурация fstab не найдена"
        return
    fi
    
    # Ищем все записи mount и swap
    local configs=$(uci show fstab 2>/dev/null | grep -E "fstab\.(@mount\[|@swap\[|fstab\.[a-zA-Z])" | cut -d'=' -f1 | sed "s/'$//" | sort -u)
    
    log_debug "Найдено записей в fstab: $(echo "$configs" | wc -l)"
    
    for config in $configs; do
        # Получаем device или uuid записи
        local device=$(uci -q get "${config}.device" 2>/dev/null)
        local uuid=$(uci -q get "${config}.uuid" 2>/dev/null)
        local target=$(uci -q get "${config}.target" 2>/dev/null)
        
        log_debug "  Проверяю запись $config:"
        log_debug "    device=$device"
        log_debug "    uuid=$uuid"
        log_debug "    target=$target"
        
        # Проверяем, относится ли запись к нашему диску
        local remove=0
        
        # 1. Проверка по device (прямое совпадение с /dev/sda*)
        if [ -n "$device" ]; then
            if echo "$device" | grep -q "^${disk}[0-9]*$"; then
                remove=1
                log_debug "    -> Удалить: совпадение по device"
            fi
        fi
        
        # 2. Проверка по UUID
        if [ -n "$uuid" ] && [ "$remove" -eq 0 ]; then
            for disk_uuid in $uuids; do
                if [ "$uuid" = "$disk_uuid" ]; then
                    remove=1
                    log_debug "    -> Удалить: совпадение по UUID $disk_uuid"
                    break
                fi
            done
        fi
        
        # 3. Проверка по target (монтирование в /mnt/sda*)
        if [ -n "$target" ] && [ "$remove" -eq 0 ]; then
            local disk_name=$(basename "$disk")  # "sda"
            if echo "$target" | grep -q "^/mnt/${disk_name}[0-9]*$"; then
                remove=1
                log_debug "    -> Удалить: совпадение по target"
            fi
        fi
        
        # 4. Дополнительная проверка: если устройство существует, проверяем его реальный UUID
        if [ -n "$device" ] && [ -b "$device" ] && [ "$remove" -eq 0 ]; then
            local real_uuid=$(blkid -s UUID -o value "$device" 2>/dev/null)
            if [ -n "$real_uuid" ]; then
                for disk_uuid in $uuids; do
                    if [ "$real_uuid" = "$disk_uuid" ]; then
                        remove=1
                        log_debug "    -> Удалить: реальный UUID устройства совпадает"
                        break
                    fi
                done
            fi
        fi
        
        # Удаляем запись если нужно
        if [ "$remove" -eq 1 ]; then
            uci -q delete "$config"
            log_success "    УДАЛЕНО: $config"
        else
            log_debug "    ОСТАВЛЕНО: не относится к диску $disk"
        fi
    done
    
    # Дополнительно: удаляем все записи с enabled="0" для нашего диска
    log_debug "Проверка записей с enabled=0..."
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
                log_debug "  Удалена отключенная запись: $config"
            fi
        fi
    done
        
    # Удаляем старые настройки для этого диска
    uci -q delete fstab.extroot
    uci -q delete fstab.swap
    uci -q delete fstab.data
    uci -q delete fstab.extra

    log_success "Очистка завершена"
}

# ============================================================================
# Функция для настройки fstab
# ============================================================================
configure_fstab() {
    local disk="$1"
    local part_count="$2"
    
    log_info "Настраиваю fstab..."
    
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
        log_success "  Настроен extroot: ${disk}1"
    fi
    
    # Настраиваем swap если есть
    if [ -b "${disk}2" ]; then
        uci set fstab.swap="swap"
        uci set fstab.swap.device="${disk}2"
        uci set fstab.swap.enabled="1"
        log_success "  Настроен swap: ${disk}2"
    fi
    
    # Настраиваем data если есть
    if [ -b "${disk}3" ]; then
        uci set fstab.data="mount"
        uci set fstab.data.device="${disk}3"
        uci set fstab.data.target="/mnt/data"
        uci set fstab.data.enabled="1"
        
        mkdir -p /mnt/data
        log_success "  Настроен data: ${disk}3"
    fi
    
    # Настраиваем extra если есть
    if [ -b "${disk}4" ]; then
        uci set fstab.extra="mount"
        uci set fstab.extra.device="${disk}4"
        uci set fstab.extra.target="/mnt/extra"
        uci set fstab.extra.enabled="1"
        
        mkdir -p /mnt/extra
        log_success "  Настроен extra: ${disk}4"
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
        log_success "  Настроен rwm: ${ORIG}"
    fi
}

# ============================================================================
# Функция для копирования данных в extroot
# ============================================================================
copy_to_extroot() {
    local disk="$1"
    
    log_info "Копирую данные в extroot..."
    
    if mount "${disk}1" /mnt 2>/dev/null; then
        if [ -d "${MOUNT}" ]; then
            tar -C "${MOUNT}" -cvf - . | tar -C /mnt -xf - 2>/dev/null
            if [ $? -eq 0 ]; then
                log_success "  Данные успешно скопированы"
            else
                log_warn "  Предупреждение: возникли ошибки при копировании"
            fi
        else
            log_warn "  Предупреждение: исходная точка монтирования не найдена"
        fi
        umount /mnt 2>/dev/null
    else
        log_warn "  Предупреждение: не удалось смонтировать extroot для копирования данных"
    fi
}

# ============================================================================
# Основная функция
# ============================================================================
mount_usb_main() {
    # Проверяем существование диска
    [ -b "$DISK" ] || error_exit "Диск $DISK не найден"
    
    log_info "=== Настройка диска $DISK ==="
    
    # Сначала останавливаем все процессы, использующие диск
    stop_disk_usage "$DISK"
    
    # Затем размонтируем все разделы диска
    if ! unmount_disk_partitions "$DISK"; then
        log_warn "⚠️  Предупреждение: не удалось размонтировать все разделы, продолжаем..."
    fi
    
    # Принудительно перезагружаем таблицу разделов
    force_reload_partitions "$DISK"
    
    # Сначала показываем текущую таблицу разделов
    log_info "Текущая таблица разделов:"
    if command -v parted >/dev/null 2>&1; then
        parted -s "$DISK" print 2>/dev/null || log_warn "Не удалось отобразить таблицу разделов"
    else
        log_warn "Утилита parted не найдена"
    fi
    
    # Проверяем существующие разделы
    EXISTING_PARTS=$(count_existing_partitions "$DISK")
    
    if [ "$EXISTING_PARTS" -eq 0 ]; then
        log_info "Диск не размечен. Создаю новую разметку..."
        PART_COUNT=$(create_new_partitions "$DISK")
        configure_fstab "$DISK" "$PART_COUNT"
        copy_to_extroot "$DISK"
        
    else
        log_info "На диске обнаружены разделы ($EXISTING_PARTS). Проверяю разметку..."
        
        # Используем быструю проверку
        CHECK_RESULT=$(quick_check "$DISK" | tail -n1)  # Берем последнюю строку
        
        if [ "$CHECK_RESULT" != "false" ] && [ -n "$CHECK_RESULT" ] && [ "$CHECK_RESULT" -gt 0 ]; then
            PART_COUNT="$CHECK_RESULT"
            log_success "✅ Существующая разметка корректна. Использую её."
            log_success "Обнаружено $PART_COUNT корректных разделов"
            
            configure_fstab "$DISK" "$PART_COUNT"
            
            # Проверяем, нужно ли копировать данные в extroot
            # Ищем точку монтирования overlay
            OVERLAY_MOUNT=$(block info | grep 'MOUNT="[^"]*/overlay"' | cut -d'"' -f2)
            if [ -n "$OVERLAY_MOUNT" ] && [ -b "${DISK}1" ] && ! mountpoint -q "$OVERLAY_MOUNT" 2>/dev/null; then
                MOUNT="$OVERLAY_MOUNT"
                log_info "Extroot еще не настроен. Копирую данные..."
                copy_to_extroot "$DISK"
            else
                log_info "Extroot уже настроен или точка монтирования не найдена. Пропускаю копирование данных."
            fi
            
        else
            log_error "❌ Существующая разметка некорректна или неполная."
            
            # Пробуем автоматическое определение как запасной вариант
            if [ "$CHECK_RESULT" = "false" ]; then
                log_info "Пробую автоматическое определение..."
                ALT_CHECK=$(auto_detect_layout "$DISK")
                
                if [ "$ALT_CHECK" != "false" ] && [ -n "$ALT_CHECK" ] && [ "$ALT_CHECK" -gt 0 ]; then
                    PART_COUNT="$ALT_CHECK"
                    log_warn "⚠️  Автоматическое определение: найдено $PART_COUNT разделов"
                    log_warn "Использую эту конфигурацию..."
                    
                    configure_fstab "$DISK" "$PART_COUNT"
                    
                    # Завершаем работу после настройки
                    log_warn "Настройка завершена на основе автоматического определения."
                    log_warn "Рекомендуется проверить корректность настроек."
                    exit 0
                fi
            fi
            
            # Автоматический режим для скриптов
            if [ $AUTO_MODE -eq 0 ] && [ -t 0 ]; then
                # Интерактивный режим (если есть терминал)
                log_question "Переразметить диск? (Все данные будут удалены!) [y/N]: "
                read CONFIRM
                
                if [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ]; then
                    log_info "Переразмечаю диск..."
                    PART_COUNT=$(create_new_partitions "$DISK")
                    configure_fstab "$DISK" "$PART_COUNT"
                    copy_to_extroot "$DISK"
                else
                    log_info "Отменено пользователем."
                    exit 0
                fi
            else
                # Автоматический режим (без терминала или AUTO_MODE=1)
                log_info "Автоматический режим: переразмечаю диск..."
                PART_COUNT=$(create_new_partitions "$DISK")
                configure_fstab "$DISK" "$PART_COUNT"
                copy_to_extroot "$DISK"
            fi
        fi
    fi
    
    # Показываем итоговую информацию
    log_info "=== Итоговая информация ==="
    log_info "Таблица разделов:"
    if command -v parted >/dev/null 2>&1; then
        parted -s "$DISK" print 2>/dev/null || log_warn "Не удалось отобразить таблицу разделов"
    fi
    
    log_info "Монтированные разделы:"
    mount | grep "^$DISK" 2>/dev/null || log_info "Нет смонтированных разделов с этого диска"
    
    log_success "Настройка fstab завершена успешно!"
    cat /etc/config/fstab

    # Удаляем сам скрипт
    while [ -f "/root/mount_usb_function.sh" ]; do
        rm -f /root/mount_usb_function.sh
    done
    if [ ! -f "/root/mount_usb_function.sh" ]; then
        log_info "Скрипт удален"
    fi
}
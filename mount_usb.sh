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
    
    if command -v hdparm >/dev/null 2>&1; then
        hdparm -z "$disk" 2>/dev/null && echo "  ✅ hdparm -z выполнен" | tee -a $LOG
    fi
    
    if command -v blockdev >/dev/null 2>&1; then
        blockdev --rereadpt "$disk" 2>/dev/null && echo "  ✅ blockdev --rereadpt выполнен" | tee -a $LOG
    fi
    
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$disk" 2>/dev/null && echo "  ✅ partprobe выполнен" | tee -a $LOG
    fi
    
    sleep 2
}

# Функция для размонтирования всех разделов диска
unmount_disk_partitions() {
    local disk="$1"
    local mounted_parts=0
    local max_attempts=3
    local attempt=1
    
    echo "Проверка смонтированных разделов на $disk..." | tee -a $LOG
    
    # Отключаем swap
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
                if mount | grep -q "^$part "; then
                    mounted_parts=$((mounted_parts + 1))
                    echo "  Размонтирование $part..." | tee -a $LOG
                    
                    umount -f "$part" 2>/dev/null || \
                    umount -l "$part" 2>/dev/null || \
                    umount "$part" 2>/dev/null
                    
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
    
    # Проверяем остатки
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

# Функция для получения информации о разделах
get_partition_info() {
    local disk="$1"
    
    if ! command -v parted >/dev/null 2>&1; then
        echo "false"
        return
    fi
    
    local info_file=$(mktemp /tmp/partinfo.XXXXXX)
    
    parted -s "$disk" unit s print 2>/dev/null | awk 'NR > 7 && /^ [0-9]/ {
        gsub(/s$/, "", $2);
        gsub(/s$/, "", $3);
        gsub(/s$/, "", $4);
        print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6
    }' > "$info_file"
    
    echo "$info_file"
}

# Функция для поиска свободного места в конце диска
find_free_space_at_end() {
    local disk="$1"
    local part_info_file="$2"
    local target_size_sectors="$3"
    
    local last_end=0
    
    if [ -s "$part_info_file" ]; then
        last_end=$(tail -n1 "$part_info_file" | cut -d'|' -f3 | sed 's/s$//')
    fi
    
    local disk_size_sectors=0
    if [ -f "/sys/block/${disk##*/}/size" ]; then
        disk_size_sectors=$(cat "/sys/block/${disk##*/}/size" 2>/dev/null)
    fi
    
    if [ $disk_size_sectors -gt 0 ] && [ $((disk_size_sectors - last_end - 1)) -ge $target_size_sectors ]; then
        echo $((last_end + 1))
    else
        echo ""
    fi
}

# Функция для определения оптимальной конфигурации
determine_optimal_layout() {
    local disk="$1"
    local disk_size_gb="$2"
    
    if [ "$disk_size_gb" -lt 2 ]; then
        echo "1:extroot:100%"
    elif [ "$disk_size_gb" -lt 4 ]; then
        echo "2:extroot:1GB:swap:100%"
    elif [ "$disk_size_gb" -lt 64 ]; then
        echo "3:extroot:1GB:swap:1GB:data:100%"
    else
        echo "4:extroot:1GB:swap:1GB:data:6GB:extra:100%"
    fi
}

# Функция для безопасного создания файловой системы с проверкой
safe_mkfs() {
    local partition="$1"
    local fstype="$2"
    local label="$3"
    
    echo "    Создание FS на $partition: $fstype, метка $label" | tee -a $LOG
    
    # Ждем появления устройства
    local max_wait=10
    local wait_count=0
    while [ ! -b "$partition" ] && [ $wait_count -lt $max_wait ]; do
        sleep 1
        wait_count=$((wait_count + 1))
    done
    
    if [ ! -b "$partition" ]; then
        echo "    ❌ Устройство $partition не появилось" | tee -a $LOG
        return 1
    fi
    
    case "$fstype" in
        "ext4")
            mkfs.ext4 -F -L "$label" "$partition" >/dev/null 2>&1
            ;;
        "swap")
            mkswap -L "$label" "$partition" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
    
    if [ $? -eq 0 ]; then
        echo "    ✅ FS создана успешно" | tee -a $LOG
        # Проверяем, что метка установилась
        sleep 1
        local actual_label=$(blkid -s LABEL -o value "$partition" 2>/dev/null)
        echo "    Метка раздела: $actual_label" | tee -a $LOG
        return 0
    else
        echo "    ❌ Ошибка создания FS" | tee -a $LOG
        return 1
    fi
}

# Функция для создания недостающих разделов
create_missing_partitions() {
    local disk="$1"
    local disk_size_gb="$2"
    local existing_parts="$3"
    
    echo "Анализ существующих разделов и создание недостающих..." | tee -a $LOG
    
    local part_info_file=$(get_partition_info "$disk")
    
    # Определяем, какие разделы уже есть
    local has_extroot=0
    local has_swap=0
    local has_data=0
    local has_extra=0
    
    if [ -s "$part_info_file" ]; then
        while IFS='|' read -r num start end size fs name; do
            name=$(echo "$name" | tr -d ' ')
            case "$name" in
                "extroot")
                    has_extroot=1
                    echo "  ✅ Найден extroot: раздел $num" | tee -a $LOG
                    ;;
                "swap")
                    has_swap=1
                    echo "  ✅ Найден swap: раздел $num" | tee -a $LOG
                    ;;
                "data")
                    has_data=1
                    echo "  ✅ Найден data: раздел $num" | tee -a $LOG
                    ;;
                "extra")
                    has_extra=1
                    echo "  ✅ Найден extra: раздел $num" | tee -a $LOG
                    ;;
            esac
        done < "$part_info_file"
    fi
    
    # Также проверяем по меткам через blkid (более надежно)
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -b "${disk}${i}" ]; then
            local label=$(blkid -s LABEL -o value "${disk}${i}" 2>/dev/null)
            case "$label" in
                "extroot") has_extroot=1 ;;
                "swap") has_swap=1 ;;
                "data") has_data=1 ;;
                "extra") has_extra=1 ;;
            esac
        fi
    done
    
    local optimal_layout=$(determine_optimal_layout "$disk" "$disk_size_gb")
    local optimal_count=$(echo "$optimal_layout" | cut -d':' -f1)
    
    echo "Оптимальная конфигурация для диска ${disk_size_gb}GB: $optimal_count раздела(ов)" | tee -a $LOG
    
    # Проверяем наличие extroot - это критично
    if [ "$has_extroot" -eq 0 ]; then
        echo "  ❌ Extroot раздел не найден! Требуется полная переразметка." | tee -a $LOG
        rm -f "$part_info_file"
        return 1
    fi
    
    # Определяем, какие разделы нужно создать
    local parts_to_create=""
    
    case "$optimal_count" in
        2)
            if [ "$has_swap" -eq 0 ]; then
                parts_to_create="$parts_to_create swap"
                echo "  ❌ Отсутствует swap раздел" | tee -a $LOG
            fi
            ;;
        3)
            if [ "$has_swap" -eq 0 ]; then
                parts_to_create="$parts_to_create swap"
                echo "  ❌ Отсутствует swap раздел" | tee -a $LOG
            fi
            if [ "$has_data" -eq 0 ] && [ "$has_extra" -eq 0 ]; then
                parts_to_create="$parts_to_create data"
                echo "  ❌ Отсутствует data раздел" | tee -a $LOG
            fi
            ;;
        4)
            if [ "$has_swap" -eq 0 ]; then
                parts_to_create="$parts_to_create swap"
                echo "  ❌ Отсутствует swap раздел" | tee -a $LOG
            fi
            if [ "$has_data" -eq 0 ]; then
                parts_to_create="$parts_to_create data"
                echo "  ❌ Отсутствует data раздел" | tee -a $LOG
            fi
            if [ "$has_extra" -eq 0 ]; then
                parts_to_create="$parts_to_create extra"
                echo "  ❌ Отсутствует extra раздел" | tee -a $LOG
            fi
            ;;
    esac
    
    if [ -z "$parts_to_create" ]; then
        echo "  ✅ Все необходимые разделы уже существуют" | tee -a $LOG
        echo "$optimal_count"
        rm -f "$part_info_file"
        return 0
    fi
    
    echo "  Нужно создать недостающие разделы:$parts_to_create" | tee -a $LOG
    echo "  Поиск свободного места в конце диска..." | tee -a $LOG
    
    # Рассчитываем необходимый размер
    local total_needed_mb=0
    for part in $parts_to_create; do
        case "$part" in
            "swap") total_needed_mb=$((total_needed_mb + 1024)) ;; # 1GB
            "data") total_needed_mb=$((total_needed_mb + 6144)) ;; # 6GB
            "extra") total_needed_mb=$((total_needed_mb + 1024)) ;; # 1GB минимум
        esac
    done
    
    # Конвертируем в сектора (512 байт)
    local total_needed_sectors=$((total_needed_mb * 1024 * 1024 / 512))
    
    local free_end_start=$(find_free_space_at_end "$disk" "$part_info_file" $total_needed_sectors)
    
    if [ -n "$free_end_start" ]; then
        echo "  ✅ Найдено свободное место в конце диска (сектор $free_end_start)" | tee -a $LOG
        echo "  Создаю недостающие разделы..." | tee -a $LOG
        
        local current_start=$free_end_start
        local next_part_num=$((existing_parts + 1))
        
        # Создаем разделы
        for part in $parts_to_create; do
            case "$part" in
                "swap")
                    echo "    Создание swap раздела (номер $next_part_num)..." | tee -a $LOG
                    
                    # Размер 1GB = 1953125 секторов (512 байт)
                    local swap_end=$((current_start + 1953125))
                    
                    parted -s "$disk" mkpart "swap" linux-swap ${current_start}s ${swap_end}s || {
                        echo "    ❌ Ошибка создания swap" | tee -a $LOG
                        rm -f "$part_info_file"
                        return 1
                    }
                    sleep 2
                    force_reload_partitions "$disk"
                    safe_mkfs "${disk}${next_part_num}" "swap" "swap" || {
                        echo "    ❌ Ошибка создания swap FS" | tee -a $LOG
                    }
                    current_start=$((swap_end + 1))
                    next_part_num=$((next_part_num + 1))
                    has_swap=1
                    ;;
                "data")
                    echo "    Создание data раздела (номер $next_part_num)..." | tee -a $LOG
                    
                    # Размер 6GB = 11718750 секторов
                    local data_end=$((current_start + 11718750))
                    
                    parted -s "$disk" mkpart "data" ext4 ${current_start}s ${data_end}s || {
                        echo "    ❌ Ошибка создания data" | tee -a $LOG
                        rm -f "$part_info_file"
                        return 1
                    }
                    sleep 2
                    force_reload_partitions "$disk"
                    safe_mkfs "${disk}${next_part_num}" "ext4" "data" || {
                        echo "    ❌ Ошибка создания data FS" | tee -a $LOG
                    }
                    current_start=$((data_end + 1))
                    next_part_num=$((next_part_num + 1))
                    has_data=1
                    ;;
                "extra")
                    echo "    Создание extra раздела (номер $next_part_num)..." | tee -a $LOG
                    
                    # Используем оставшееся место до конца диска
                    parted -s "$disk" mkpart "extra" ext4 ${current_start}s 100% || {
                        echo "    ❌ Ошибка создания extra" | tee -a $LOG
                        rm -f "$part_info_file"
                        return 1
                    }
                    sleep 2
                    force_reload_partitions "$disk"
                    safe_mkfs "${disk}${next_part_num}" "ext4" "extra" || {
                        echo "    ❌ Ошибка создания extra FS" | tee -a $LOG
                    }
                    has_extra=1
                    ;;
            esac
            sleep 1
        done
        
        echo "  ✅ Недостающие разделы созданы" | tee -a $LOG
        
        local new_part_count=$(count_existing_partitions "$disk")
        echo "$new_part_count"
        rm -f "$part_info_file"
        return 0
    else
        echo "  ❌ Недостаточно свободного места в конце диска" | tee -a $LOG
        rm -f "$part_info_file"
        return 1
    fi
}

# Функция для создания новой разметки
create_new_partitions() {
    local disk="$1"
    
    echo "Создаю новую разметку на диске $disk..." | tee -a $LOG
    
    DISK_SIZE_BYTES=$(get_disk_size "$disk") || error_exit "Не удалось определить размер диска"
    
    if [ -z "$DISK_SIZE_BYTES" ] || [ "$DISK_SIZE_BYTES" -eq 0 ]; then
        error_exit "Не удалось определить размер диска"
    fi
    
    DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
    
    echo "Размер диска: ${DISK_SIZE_GB}GB" | tee -a $LOG
    
    force_reload_partitions "$disk"
    
    # Очищаем диск
    dd if=/dev/zero of="$disk" bs=1M count=1 2>/dev/null
    sleep 1
    force_reload_partitions "$disk"
    
    if [ "$DISK_SIZE_GB" -lt 1 ]; then
        error_exit "Диск слишком мал (меньше 1GB)"
    elif [ "$DISK_SIZE_GB" -lt 2 ]; then
        PART_COUNT=1
        echo "Создаю 1 раздел (диск менее 2GB)" | tee -a $LOG
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        sleep 1
        parted -s ${disk} mkpart "extroot" ext4 2048s 100% || error_exit "Ошибка создания раздела"
        sleep 2
        force_reload_partitions "$disk"
        safe_mkfs "${disk}1" "ext4" "extroot" || error_exit "Ошибка создания файловой системы"
        
    elif [ "$DISK_SIZE_GB" -lt 4 ]; then
        PART_COUNT=2
        echo "Создаю 2 раздела (диск 2-3GB)" | tee -a $LOG
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        sleep 1
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 1GB || error_exit "Ошибка создания extroot"
        sleep 2
        force_reload_partitions "$disk"
        safe_mkfs "${disk}1" "ext4" "extroot" || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 1GB 100% || error_exit "Ошибка создания swap"
        sleep 2
        force_reload_partitions "$disk"
        safe_mkfs "${disk}2" "swap" "swap" || error_exit "Ошибка создания swap"
        
    elif [ "$DISK_SIZE_GB" -lt 64 ]; then
        PART_COUNT=3
        echo "Создаю 3 раздела (диск 4-32GB)" | tee -a $LOG
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        sleep 1
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 1GB || error_exit "Ошибка создания extroot"
        sleep 2
        force_reload_partitions "$disk"
        safe_mkfs "${disk}1" "ext4" "extroot" || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 1GB 2GB || error_exit "Ошибка создания swap"
        sleep 2
        force_reload_partitions "$disk"
        safe_mkfs "${disk}2" "swap" "swap" || error_exit "Ошибка создания swap"
        
        parted -s ${disk} mkpart "data" ext4 2GB 100% || error_exit "Ошибка создания data"
        sleep 2
        force_reload_partitions "$disk"
        safe_mkfs "${disk}3" "ext4" "data" || error_exit "Ошибка создания файловой системы"
        
    else
        PART_COUNT=4
        echo "Создаю 4 раздела (диск 64GB и более)" | tee -a $LOG
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        sleep 1
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 1GB || error_exit "Ошибка создания extroot"
        sleep 2
        force_reload_partitions "$disk"
        safe_mkfs "${disk}1" "ext4" "extroot" || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 1GB 2GB || error_exit "Ошибка создания swap"
        sleep 2
        force_reload_partitions "$disk"
        safe_mkfs "${disk}2" "swap" "swap" || error_exit "Ошибка создания swap"
        
        parted -s ${disk} mkpart "data" ext4 2GB 8GB || error_exit "Ошибка создания data"
        sleep 2
        force_reload_partitions "$disk"
        safe_mkfs "${disk}3" "ext4" "data" || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "extra" ext4 8GB 100% || error_exit "Ошибка создания extra"
        sleep 2
        force_reload_partitions "$disk"
        safe_mkfs "${disk}4" "ext4" "extra" || error_exit "Ошибка создания файловой системы"
    fi
    
    echo "$PART_COUNT" | tee -a $LOG
}

# Функция для удаления старых записей fstab
cleanup_old_fstab_entries() {
    local disk="$1"
    
    echo "Очищаю старые записи fstab..." | tee -a $LOG
    
    local uuids=""
    
    if [ ! -b "$disk" ]; then
        echo "  Диск $disk не найден" | tee -a $LOG
        return
    fi
    
    for i in 1 2 3 4 5 6 7 8 9; do
        local partition="${disk}${i}"
        if [ -b "$partition" ]; then
            local uuid=$(blkid -s UUID -o value "$partition" 2>/dev/null)
            if [ -n "$uuid" ]; then
                uuids="$uuids $uuid"
            fi
        fi
    done
    
    if ! uci show fstab >/dev/null 2>&1; then
        echo "  Конфигурация fstab не найдена" | tee -a $LOG
        return
    fi
    
    local configs=$(uci show fstab 2>/dev/null | grep -E "fstab\.(@mount\[|@swap\[|fstab\.[a-zA-Z])" | cut -d'=' -f1 | sed "s/'$//" | sort -u)
    
    for config in $configs; do
        local device=$(uci -q get "${config}.device" 2>/dev/null)
        local uuid=$(uci -q get "${config}.uuid" 2>/dev/null)
        local remove=0
        
        if [ -n "$device" ] && echo "$device" | grep -q "^${disk}[0-9]*$"; then
            remove=1
        fi
        
        if [ -n "$uuid" ] && [ "$remove" -eq 0 ]; then
            for disk_uuid in $uuids; do
                if [ "$uuid" = "$disk_uuid" ]; then
                    remove=1
                    break
                fi
            done
        fi
        
        if [ "$remove" -eq 1 ]; then
            uci -q delete "$config"
            echo "    УДАЛЕНО: $config" | tee -a $LOG
        fi
    done
    
    uci commit fstab
    echo "Очистка завершена" | tee -a $LOG
}

# Функция для настройки fstab
configure_fstab() {
    local disk="$1"
    local part_count="$2"
    
    echo "Настраиваю fstab..." | tee -a $LOG
    
    cleanup_old_fstab_entries "$disk"
    
    # Получаем точку монтирования overlay
    eval $(block info | grep -o -e 'MOUNT="\S*/overlay"')
    
    # Удаляем старые настройки для этого диска
    uci -q delete fstab.extroot
    uci -q delete fstab.swap
    uci -q delete fstab.data
    uci -q delete fstab.extra
    
    # Настраиваем extroot (всегда раздел 1 с меткой extroot)
    if [ -b "${disk}1" ]; then
        local label=$(blkid -s LABEL -o value "${disk}1" 2>/dev/null)
        if [ "$label" = "extroot" ]; then
            uci set fstab.extroot="mount"
            uci set fstab.extroot.device="${disk}1"
            uci set fstab.extroot.target="${MOUNT}"
            uci set fstab.extroot.enabled="1"
            uci set fstab.extroot.enabled_fsck="0"
            echo "  ✅ Настроен extroot: ${disk}1 (метка: $label)" | tee -a $LOG
        else
            echo "  ⚠️  Раздел ${disk}1 не имеет метки extroot (метка: $label)" | tee -a $LOG
        fi
    fi
    
    # Ищем swap раздел по метке
    local swap_found=0
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -b "${disk}${i}" ]; then
            local label=$(blkid -s LABEL -o value "${disk}${i}" 2>/dev/null)
            local fstype=$(blkid -s TYPE -o value "${disk}${i}" 2>/dev/null)
            
            if [ "$label" = "swap" ] || [ "$fstype" = "swap" ]; then
                uci set fstab.swap="swap"
                uci set fstab.swap.device="${disk}${i}"
                uci set fstab.swap.enabled="1"
                echo "  ✅ Настроен swap: ${disk}${i} (метка: $label, тип: $fstype)" | tee -a $LOG
                swap_found=1
                
                # Активируем swap
                swapon "${disk}${i}" 2>/dev/null && echo "  ✅ Swap активирован" | tee -a $LOG
                break
            fi
        fi
    done
    
    if [ "$swap_found" -eq 0 ]; then
        echo "  ⚠️  Swap раздел не найден" | tee -a $LOG
    fi
    
    # Ищем data раздел по метке
    local data_found=0
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -b "${disk}${i}" ] && [ "$i" -ne 1 ]; then
            local label=$(blkid -s LABEL -o value "${disk}${i}" 2>/dev/null)
            
            if [ "$label" = "data" ]; then
                uci set fstab.data="mount"
                uci set fstab.data.device="${disk}${i}"
                uci set fstab.data.target="/mnt/data"
                uci set fstab.data.enabled="1"
                uci set fstab.data.enabled_fsck="1"
                uci set fstab.data.options="rw,sync,noatime,nodiratime"
                echo "  ✅ Настроен data: ${disk}${i} (метка: $label)" | tee -a $LOG
                data_found=1
                
                # Создаем точку монтирования и монтируем
                mkdir -p /mnt/data
                mount "${disk}${i}" /mnt/data 2>/dev/null && echo "  ✅ Data раздел смонтирован" | tee -a $LOG
                break
            fi
        fi
    done
    
    if [ "$data_found" -eq 0 ]; then
        echo "  ⚠️  Data раздел не найден" | tee -a $LOG
    fi
    
    # Ищем extra раздел по метке
    local extra_found=0
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -b "${disk}${i}" ] && [ "$i" -ne 1 ]; then
            local label=$(blkid -s LABEL -o value "${disk}${i}" 2>/dev/null)
            
            if [ "$label" = "extra" ]; then
                uci set fstab.extra="mount"
                uci set fstab.extra.device="${disk}${i}"
                uci set fstab.extra.target="/mnt/extra"
                uci set fstab.extra.enabled="1"
                uci set fstab.extra.enabled_fsck="1"
                uci set fstab.extra.options="rw,sync,noatime,nodiratime"
                echo "  ✅ Настроен extra: ${disk}${i} (метка: $label)" | tee -a $LOG
                extra_found=1
                
                # Создаем точку монтирования и монтируем
                mkdir -p /mnt/extra
                mount "${disk}${i}" /mnt/extra 2>/dev/null && echo "  ✅ Extra раздел смонтирован" | tee -a $LOG
                break
            fi
        fi
    done
    
    if [ "$extra_found" -eq 0 ]; then
        echo "  ⚠️  Extra раздел не найден" | tee -a $LOG
    fi
    
    # Сохраняем изменения
    uci commit fstab || error_exit "Ошибка сохранения конфигурации fstab"
    
    # Настройка rootfs_data
    ORIG="$(block info | sed -n -e '/MOUNT="\S*\/overlay"/s/:\s.*$//p')"
    if [ -n "$ORIG" ]; then
        uci -q delete fstab.rwm
        uci set fstab.rwm="mount"
        uci set fstab.rwm.device="${ORIG}"
        uci set fstab.rwm.target="/rwm"
        uci set fstab.rwm.enabled="1"
        uci set fstab.rwm.enabled_fsck="1"
        uci commit fstab
        echo "  ✅ Настроен rwm: ${ORIG}" | tee -a $LOG
    fi
    
    echo "  ✅ Настройка fstab завершена" | tee -a $LOG
}

# Функция для копирования данных в extroot
copy_to_extroot() {
    local disk="$1"
    
    echo "Копирую данные в extroot..." | tee -a $LOG
    
    if [ ! -b "${disk}1" ]; then
        echo "  ❌ Раздел extroot не найден" | tee -a $LOG
        return 1
    fi
    
    # Создаем временную точку монтирования
    mkdir -p /tmp/extroot_mount
    
    if mount "${disk}1" /tmp/extroot_mount 2>/dev/null; then
        if [ -d "${MOUNT}" ] && [ "${MOUNT}" != "/" ]; then
            echo "  Копирование из ${MOUNT} в /tmp/extroot_mount..." | tee -a $LOG
            
            # Копируем данные, исключая некоторые директории
            tar -C "${MOUNT}" -cf - --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./tmp --exclude=./mnt --exclude=./overlay . | tar -C /tmp/extroot_mount -xf - 2>/dev/null
            
            if [ $? -eq 0 ]; then
                echo "  ✅ Данные успешно скопированы" | tee -a $LOG
            else
                echo "  ⚠️  Возникли ошибки при копировании" | tee -a $LOG
            fi
            
            # Создаем необходимые директории
            mkdir -p /tmp/extroot_mount/overlay
            mkdir -p /tmp/extroot_mount/proc /tmp/extroot_mount/sys /tmp/extroot_mount/dev /tmp/extroot_mount/tmp /tmp/extroot_mount/mnt
            chmod 755 /tmp/extroot_mount
        else
            echo "  ⚠️  Исходная точка монтирования не найдена" | tee -a $LOG
        fi
        
        umount /tmp/extroot_mount 2>/dev/null
        rmdir /tmp/extroot_mount 2>/dev/null
    else
        echo "  ⚠️  Не удалось смонтировать extroot для копирования данных" | tee -a $LOG
        return 1
    fi
}

# Функция для быстрой проверки
quick_check() {
    local disk="$1"
    
    echo "Быстрая проверка разметки..." | tee -a $LOG
    
    if ! command -v parted >/dev/null 2>&1; then
        echo "  ⚠️ Утилита parted не найдена" | tee -a $LOG
        echo "false" | tee -a $LOG
        return
    fi
    
    if ! parted -s "$disk" print 2>/dev/null | grep -q "Partition Table:.*gpt"; then
        echo "  ❌ Таблица разделов не GPT" | tee -a $LOG
        echo "false" | tee -a $LOG
        return
    fi
    
    local partitions=$(parted -s "$disk" print 2>/dev/null | awk 'NR > 7 && /^ [0-9]/ {print $1 " " $6 " " $5}')
    
    if [ -z "$partitions" ]; then
        echo "  Диск не размечен" | tee -a $LOG
        echo "0" | tee -a $LOG
        return
    fi
    
    local valid_count=0
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
    
    if [ -f "$result_file" ]; then
        valid_count=$(wc -l < "$result_file" 2>/dev/null)
        valid_count=$(echo "$valid_count" | tr -d '[:space:]')
        rm -f "$result_file"
    fi
    
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

# Основной код
main() {
    [ -b "$DISK" ] || error_exit "Диск $DISK не найден"
    
    echo "=== Настройка диска $DISK ===" | tee -a $LOG
    
    unmount_disk_partitions "$DISK"
    force_reload_partitions "$DISK"
    
    echo "Текущая таблица разделов:" | tee -a $LOG
    if command -v parted >/dev/null 2>&1; then
        parted -s "$DISK" print 2>/dev/null || echo "Не удалось отобразить таблицу разделов"
    fi
    echo "" | tee -a $LOG
    
    EXISTING_PARTS=$(count_existing_partitions "$DISK")
    DISK_SIZE_BYTES=$(get_disk_size "$DISK")
    DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
    
    if [ "$EXISTING_PARTS" -eq 0 ]; then
        echo "Диск не размечен. Создаю новую разметку..." | tee -a $LOG
        PART_COUNT=$(create_new_partitions "$DISK")
        configure_fstab "$DISK" "$PART_COUNT"
        copy_to_extroot "$DISK"
        
    else
        echo "На диске обнаружены разделы ($EXISTING_PARTS). Проверяю наличие extroot..." | tee -a $LOG
        
        # Проверяем наличие extroot
        local has_extroot=0
        if [ -b "${DISK}1" ]; then
            local label=$(blkid -s LABEL -o value "${DISK}1" 2>/dev/null)
            if [ "$label" = "extroot" ]; then
                has_extroot=1
                echo "✅ Extroot раздел найден (${DISK}1, метка: $label)" | tee -a $LOG
            fi
        fi
        
        if [ "$has_extroot" -eq 0 ]; then
            echo "❌ Extroot раздел отсутствует!" | tee -a $LOG
            echo "Пытаюсь создать недостающие разделы без потери данных..." | tee -a $LOG
            
            NEW_PART_COUNT=$(create_missing_partitions "$DISK" "$DISK_SIZE_GB" "$EXISTING_PARTS")
            CREATE_RESULT=$?
            
            if [ $CREATE_RESULT -eq 0 ] && [ -n "$NEW_PART_COUNT" ] && [ "$NEW_PART_COUNT" -gt 0 ]; then
                echo "✅ Недостающие разделы успешно созданы" | tee -a $LOG
                PART_COUNT="$NEW_PART_COUNT"
                configure_fstab "$DISK" "$PART_COUNT"
                
                if [ -b "${DISK}1" ]; then
                    OVERLAY_MOUNT=$(block info | grep 'MOUNT="[^"]*/overlay"' | cut -d'"' -f2)
                    if [ -n "$OVERLAY_MOUNT" ]; then
                        MOUNT="$OVERLAY_MOUNT"
                        copy_to_extroot "$DISK"
                    fi
                fi
            else
                echo "❌ Не удалось создать недостающие разделы без переразметки." | tee -a $LOG
                
                if [ -t 0 ]; then
                    read -p "Переразметить диск полностью? (Все данные будут удалены!) [y/N]: " CONFIRM
                    
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
                    echo "Автоматический режим: переразмечаю диск..." | tee -a $LOG
                    PART_COUNT=$(create_new_partitions "$DISK")
                    configure_fstab "$DISK" "$PART_COUNT"
                    copy_to_extroot "$DISK"
                fi
            fi
        else
            echo "Extroot присутствует. Проверяю остальные разделы..." | tee -a $LOG
            
            NEW_PART_COUNT=$(create_missing_partitions "$DISK" "$DISK_SIZE_GB" "$EXISTING_PARTS")
            CREATE_RESULT=$?
            
            if [ $CREATE_RESULT -eq 0 ] && [ -n "$NEW_PART_COUNT" ] && [ "$NEW_PART_COUNT" -gt 0 ]; then
                echo "✅ Недостающие разделы успешно созданы" | tee -a $LOG
                PART_COUNT="$NEW_PART_COUNT"
            else
                PART_COUNT="$EXISTING_PARTS"
            fi
            
            configure_fstab "$DISK" "$PART_COUNT"
            
            OVERLAY_MOUNT=$(block info | grep 'MOUNT="[^"]*/overlay"' | cut -d'"' -f2)
            if [ -n "$OVERLAY_MOUNT" ] && [ -b "${DISK}1" ]; then
                local is_mounted=$(mount | grep -c "${DISK}1")
                if [ "$is_mounted" -eq 0 ]; then
                    MOUNT="$OVERLAY_MOUNT"
                    echo "Extroot еще не настроен. Копирую данные..." | tee -a $LOG
                    copy_to_extroot "$DISK"
                else
                    echo "Extroot уже настроен. Пропускаю копирование." | tee -a $LOG
                fi
            fi
        fi
    fi
    
    echo "" | tee -a $LOG
    echo "=== Итоговая информация ===" | tee -a $LOG
    echo "Таблица разделов:" | tee -a $LOG
    if command -v parted >/dev/null 2>&1; then
        parted -s "$DISK" print 2>/dev/null || echo "Не удалось отобразить таблицу разделов"
    fi
    
    echo "" | tee -a $LOG
    echo "Разделы и их метки:" | tee -a $LOG
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -b "${DISK}${i}" ]; then
            label=$(blkid -s LABEL -o value "${DISK}${i}" 2>/dev/null)
            fstype=$(blkid -s TYPE -o value "${DISK}${i}" 2>/dev/null)
            echo "  ${DISK}${i}: $fstype, метка: $label" | tee -a $LOG
        fi
    done
    
    echo "" | tee -a $LOG
    echo "Настройка fstab завершена!" | tee -a $LOG
    echo "Текущие настройки fstab:" | tee -a $LOG
    uci show fstab | tee -a $LOG
    
    echo "" | tee -a $LOG
    echo "Смонтированные разделы:" | tee -a $LOG
    mount | grep "^$DISK" 2>/dev/null || echo "  Нет смонтированных разделов" | tee -a $LOG
    
    echo "" | tee -a $LOG
    echo "Swap разделы:" | tee -a $LOG
    swapon -s 2>/dev/null | grep "^$DISK" || echo "  Нет активных swap разделов" | tee -a $LOG
    
    echo "" | tee -a $LOG
    echo "Для применения всех изменений требуется перезагрузка." | tee -a $LOG
    
    if [ -t 0 ]; then
        read -p "Перезагрузить сейчас? [y/N]: " REBOOT_NOW
        if [ "$REBOOT_NOW" = "y" ] || [ "$REBOOT_NOW" = "Y" ]; then
            echo "Перезагружаюсь..." | tee -a $LOG
            sleep 3
            reboot
        else
            echo "Перезагрузка отложена. Рекомендуется перезагрузить систему вручную." | tee -a $LOG
        fi
    else
        echo "Автоматическая перезагрузка через 5 секунд..." | tee -a $LOG
        sleep 5
        reboot
    fi
}

# Запускаем основной код
main
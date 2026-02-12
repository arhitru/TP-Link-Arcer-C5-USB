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

# Функция для получения информации о разделах в структурированном виде
get_partition_info() {
    local disk="$1"
    
    if ! command -v parted >/dev/null 2>&1; then
        echo "false"
        return
    fi
    
    # Создаем временный файл для хранения информации
    local info_file=$(mktemp /tmp/partinfo.XXXXXX)
    
    # Получаем информацию из parted
    parted -s "$disk" unit s print 2>/dev/null | awk 'NR > 7 && /^ [0-9]/ {
        gsub(/s$/, "", $2);
        gsub(/s$/, "", $3);
        gsub(/s$/, "", $4);
        print $1 "|" $2 "|" $3 "|" $4 "|" $5 "|" $6
    }' > "$info_file"
    
    echo "$info_file"
}

# Функция для поиска свободного места в начале диска
find_free_space_before_first_partition() {
    local disk="$1"
    local part_info_file="$2"
    
    local first_part_start=""
    
    if [ -s "$part_info_file" ]; then
        # Берем начало первого раздела
        first_part_start=$(head -n1 "$part_info_file" | cut -d'|' -f2)
    fi
    
    if [ -z "$first_part_start" ]; then
        # Если разделов нет, все место свободно
        echo "0"
    else
        echo "$first_part_start"
    fi
}

# Функция для поиска свободного места между разделами
find_free_space_between_partitions() {
    local disk="$1"
    local part_info_file="$2"
    local target_size_sectors="$3"  # размер в секторах
    
    local prev_end=0
    local free_start=""
    local free_size=0
    
    while IFS='|' read -r num start end size fs name; do
        # Убираем суффикс 's' если есть
        start=$(echo "$start" | sed 's/s$//')
        end=$(echo "$end" | sed 's/s$//')
        
        # Проверяем свободное место перед этим разделом
        if [ $prev_end -gt 0 ] && [ $start -gt $((prev_end + 1)) ]; then
            free_start=$((prev_end + 1))
            free_size=$((start - free_start))
            
            if [ $free_size -ge $target_size_sectors ]; then
                echo "$free_start"
                return
            fi
        fi
        
        prev_end=$end
    done < "$part_info_file"
    
    # Если ничего не нашли
    echo ""
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
    
    # Получаем общий размер диска в секторах
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

# Функция для определения оптимальной конфигурации разделов
determine_optimal_layout() {
    local disk="$1"
    local disk_size_gb="$2"
    
    # Определяем базовую конфигурацию в зависимости от размера
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

# Функция для создания недостающих разделов
create_missing_partitions() {
    local disk="$1"
    local disk_size_gb="$2"
    local existing_parts="$3"
    
    echo "Анализ существующих разделов и создание недостающих..." | tee -a $LOG
    
    # Получаем информацию о существующих разделах
    local part_info_file=$(get_partition_info "$disk")
    
    # Определяем, какие разделы уже есть
    local has_extroot=0
    local has_swap=0
    local has_data=0
    local has_extra=0
    local extroot_part_num=""
    local swap_part_num=""
    local data_part_num=""
    local extra_part_num=""
    
    if [ -s "$part_info_file" ]; then
        while IFS='|' read -r num start end size fs name; do
            name=$(echo "$name" | tr -d ' ')
            case "$name" in
                "extroot")
                    has_extroot=1
                    extroot_part_num=$num
                    echo "  ✅ Найден extroot: раздел $num" | tee -a $LOG
                    ;;
                "swap")
                    has_swap=1
                    swap_part_num=$num
                    echo "  ✅ Найден swap: раздел $num" | tee -a $LOG
                    ;;
                "data")
                    has_data=1
                    data_part_num=$num
                    echo "  ✅ Найден data: раздел $num" | tee -a $LOG
                    ;;
                "extra")
                    has_extra=1
                    extra_part_num=$num
                    echo "  ✅ Найден extra: раздел $num" | tee -a $LOG
                    ;;
            esac
        done < "$part_info_file"
    fi
    
    # Определяем оптимальную конфигурацию
    local optimal_layout=$(determine_optimal_layout "$disk" "$disk_size_gb")
    local optimal_count=$(echo "$optimal_layout" | cut -d':' -f1)
    
    echo "Оптимальная конфигурация для диска ${disk_size_gb}GB: $optimal_count раздела(ов)" | tee -a $LOG
    
    # Проверяем наличие extroot - это критично
    if [ "$has_extroot" -eq 0 ]; then
        echo "  ❌ Extroot раздел не найден! Это критично." | tee -a $LOG
        echo "  Поиск свободного места для создания extroot..." | tee -a $LOG
        
        # Ищем свободное место в начале диска
        local free_start_sectors=$(find_free_space_before_first_partition "$disk" "$part_info_file")
        
        if [ -n "$free_start_sectors" ] && [ "$free_start_sectors" != "0" ]; then
            echo "  Найдено свободное место в начале диска (сектор $free_start_sectors)" | tee -a $LOG
            
            # Проверяем, достаточно ли места (минимум 1GB = 2048 секторов * 512 байт = ~1MB? Нужно пересчитать)
            # 1GB = 1953125 секторов (512 байт)
            local min_extroot_sectors=1953125
            
            if [ "$free_start_sectors" -ge 2048 ] && [ "$free_start_sectors" -gt $min_extroot_sectors ]; then
                echo "  Создаю extroot раздел в начале диска..." | tee -a $LOG
                
                # Определяем следующий свободный номер раздела
                local next_part_num=$((existing_parts + 1))
                
                # Сдвигаем существующие разделы? Нет, просто создаем перед ними
                # Это сложная операция, проще пересоздать всю разметку
                echo "  ⚠️  Невозможно создать раздел перед существующими без их удаления." | tee -a $LOG
                echo "  Требуется полная переразметка диска." | tee -a $LOG
                return 1
            else
                echo "  Недостаточно места в начале диска или место занято" | tee -a $LOG
            fi
        fi
        
        # Если не нашли в начале, ищем другое свободное место
        echo "  Поиск свободного места для extroot в другом месте..." | tee -a $LOG
        
        # Для extroot лучше всего место в начале, но если нет - используем любое
        local free_start=$(find_free_space_between_partitions "$disk" "$part_info_file" 1953125)
        
        if [ -n "$free_start" ]; then
            echo "  Найдено свободное место между разделами (сектор $free_start)" | tee -a $LOG
            echo "  Но extroot должен быть первым разделом для загрузки." | tee -a $LOG
            echo "  Требуется полная переразметка." | tee -a $LOG
            return 1
        else
            echo "  Свободное место не найдено." | tee -a $LOG
            echo "  Требуется полная переразметка." | tee -a $LOG
            return 1
        fi
    fi
    
    # Если extroot есть, проверяем остальные разделы
    local parts_to_create=0
    local layout_parts=""
    
    case "$optimal_count" in
        2)
            if [ "$has_swap" -eq 0 ]; then
                parts_to_create=$((parts_to_create + 1))
                layout_parts="$layout_parts swap"
                echo "  ❌ Отсутствует swap раздел" | tee -a $LOG
            fi
            ;;
        3)
            if [ "$has_swap" -eq 0 ]; then
                parts_to_create=$((parts_to_create + 1))
                layout_parts="$layout_parts swap"
                echo "  ❌ Отсутствует swap раздел" | tee -a $LOG
            fi
            if [ "$has_data" -eq 0 ] && [ "$has_extra" -eq 0 ]; then
                parts_to_create=$((parts_to_create + 1))
                layout_parts="$layout_parts data"
                echo "  ❌ Отсутствует data/extra раздел" | tee -a $LOG
            fi
            ;;
        4)
            if [ "$has_swap" -eq 0 ]; then
                parts_to_create=$((parts_to_create + 1))
                layout_parts="$layout_parts swap"
                echo "  ❌ Отсутствует swap раздел" | tee -a $LOG
            fi
            if [ "$has_data" -eq 0 ]; then
                parts_to_create=$((parts_to_create + 1))
                layout_parts="$layout_parts data"
                echo "  ❌ Отсутствует data раздел" | tee -a $LOG
            fi
            if [ "$has_extra" -eq 0 ]; then
                parts_to_create=$((parts_to_create + 1))
                layout_parts="$layout_parts extra"
                echo "  ❌ Отсутствует extra раздел" | tee -a $LOG
            fi
            ;;
    esac
    
    if [ $parts_to_create -eq 0 ]; then
        echo "  ✅ Все необходимые разделы уже существуют" | tee -a $LOG
        echo "$optimal_count"
        rm -f "$part_info_file"
        return 0
    fi
    
    echo "  Нужно создать $parts_to_create недостающих разделов:$layout_parts" | tee -a $LOG
    echo "  Поиск свободного места для создания разделов..." | tee -a $LOG
    
    # Ищем место в конце диска для новых разделов
    local total_needed_sectors=0
    
    # Оцениваем необходимый размер
    for part in $layout_parts; do
        case "$part" in
            "swap") total_needed_sectors=$((total_needed_sectors + 1953125)) ;; # 1GB
            "data") total_needed_sectors=$((total_needed_sectors + 11718750)) ;; # 6GB
            "extra") total_needed_sectors=$((total_needed_sectors + 1953125)) ;; # 1GB минимум
        esac
    done
    
    local free_end_start=$(find_free_space_at_end "$disk" "$part_info_file" $total_needed_sectors)
    
    if [ -n "$free_end_start" ]; then
        echo "  ✅ Найдено свободное место в конце диска (сектор $free_end_start)" | tee -a $LOG
        echo "  Создаю недостающие разделы..." | tee -a $LOG
        
        local current_start=$free_end_start
        local next_part_num=$((existing_parts + 1))
        
        # Создаем разделы в правильном порядке
        for part in $layout_parts; do
            case "$part" in
                "swap")
                    echo "    Создание swap раздела (номер $next_part_num)..." | tee -a $LOG
                    parted -s "$disk" mkpart "swap" linux-swap ${current_start}s $((current_start + 1953125))s || {
                        echo "    ❌ Ошибка создания swap" | tee -a $LOG
                        rm -f "$part_info_file"
                        return 1
                    }
                    sleep 2
                    force_reload_partitions "$disk"
                    mkswap -L "swap" "${disk}${next_part_num}" || echo "    ⚠️  Ошибка создания swap FS" | tee -a $LOG
                    current_start=$((current_start + 1953125 + 1))
                    next_part_num=$((next_part_num + 1))
                    has_swap=1
                    ;;
                "data")
                    echo "    Создание data раздела (номер $next_part_num)..." | tee -a $LOG
                    parted -s "$disk" mkpart "data" ext4 ${current_start}s $((current_start + 11718750))s || {
                        echo "    ❌ Ошибка создания data" | tee -a $LOG
                        rm -f "$part_info_file"
                        return 1
                    }
                    sleep 2
                    force_reload_partitions "$disk"
                    mkfs.ext4 -L "data" "${disk}${next_part_num}" 2>/dev/null || echo "    ⚠️  Ошибка создания data FS" | tee -a $LOG
                    current_start=$((current_start + 11718750 + 1))
                    next_part_num=$((next_part_num + 1))
                    has_data=1
                    ;;
                "extra")
                    echo "    Создание extra раздела (номер $next_part_num)..." | tee -a $LOG
                    # Используем оставшееся место до конца диска
                    local disk_size_sectors=$(cat "/sys/block/${disk##*/}/size" 2>/dev/null)
                    parted -s "$disk" mkpart "extra" ext4 ${current_start}s 100% || {
                        echo "    ❌ Ошибка создания extra" | tee -a $LOG
                        rm -f "$part_info_file"
                        return 1
                    }
                    sleep 2
                    force_reload_partitions "$disk"
                    mkfs.ext4 -L "extra" "${disk}${next_part_num}" 2>/dev/null || echo "    ⚠️  Ошибка создания extra FS" | tee -a $LOG
                    has_extra=1
                    ;;
            esac
        done
        
        echo "  ✅ Недостающие разделы созданы" | tee -a $LOG
        
        # Определяем новое количество разделов
        local new_part_count=$(count_existing_partitions "$disk")
        echo "$new_part_count"
        rm -f "$part_info_file"
        return 0
    else
        echo "  ❌ Недостаточно свободного места в конце диска" | tee -a $LOG
        echo "  Требуется полная переразметка." | tee -a $LOG
        rm -f "$part_info_file"
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
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
    elif [ "$DISK_SIZE_GB" -lt 4 ]; then
        PART_COUNT=2
        echo "Создаю 2 раздела (диск 2-3GB)" | tee -a $LOG
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        sleep 1
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 1GB || error_exit "Ошибка создания extroot"
        sleep 2
        force_reload_partitions "$disk"
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 1GB 100% || error_exit "Ошибка создания swap"
        sleep 2
        force_reload_partitions "$disk"
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        
    elif [ "$DISK_SIZE_GB" -lt 64 ]; then
        PART_COUNT=3
        echo "Создаю 3 раздела (диск 4-32GB)" | tee -a $LOG
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        sleep 1
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 1GB || error_exit "Ошибка создания extroot"
        sleep 2
        force_reload_partitions "$disk"
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 1GB 2GB || error_exit "Ошибка создания swap"
        sleep 2
        force_reload_partitions "$disk"
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        
        parted -s ${disk} mkpart "data" ext4 2GB 100% || error_exit "Ошибка создания data"
        sleep 2
        force_reload_partitions "$disk"
        mkfs.ext4 -L "data" ${disk}3 || error_exit "Ошибка создания файловой системы"
        
    else
        PART_COUNT=4
        echo "Создаю 4 раздела (диск 64GB и более)" | tee -a $LOG
        
        parted -s ${disk} mklabel gpt || error_exit "Ошибка создания GPT таблицы"
        sleep 1
        
        parted -s ${disk} mkpart "extroot" ext4 2048s 1GB || error_exit "Ошибка создания extroot"
        sleep 2
        force_reload_partitions "$disk"
        mkfs.ext4 -L "extroot" ${disk}1 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "swap" linux-swap 1GB 2GB || error_exit "Ошибка создания swap"
        sleep 2
        force_reload_partitions "$disk"
        mkswap -L "swap" ${disk}2 || error_exit "Ошибка создания swap"
        
        parted -s ${disk} mkpart "data" ext4 2GB 8GB || error_exit "Ошибка создания data"
        sleep 2
        force_reload_partitions "$disk"
        mkfs.ext4 -L "data" ${disk}3 || error_exit "Ошибка создания файловой системы"
        
        parted -s ${disk} mkpart "extra" ext4 8GB 100% || error_exit "Ошибка создания extra"
        sleep 2
        force_reload_partitions "$disk"
        mkfs.ext4 -L "extra" ${disk}4 || error_exit "Ошибка создания файловой системы"
    fi
    
    echo "$PART_COUNT" | tee -a $LOG
}

# Функция для удаления старых записей fstab
cleanup_old_fstab_entries() {
    local disk="$1"
    
    echo "Очищаю старые записи fstab..." | tee -a $LOG
    
    local uuids=""
    echo "Поиск разделов на диске $disk:" | tee -a $LOG
    
    if [ ! -b "$disk" ]; then
        echo "  Диск $disk не найден" | tee -a $LOG
        return
    fi
    
    for i in 1 2 3 4 5 6 7 8 9; do
        local partition="${disk}${i}"
        if [ -b "$partition" ]; then
            echo "  Найден раздел: $partition" | tee -a $LOG
            local uuid=$(blkid -s UUID -o value "$partition" 2>/dev/null)
            if [ -n "$uuid" ]; then
                echo "    UUID: $uuid" | tee -a $LOG
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
        local target=$(uci -q get "${config}.target" 2>/dev/null)
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
    
    cleanup_old_fstab_entries "$disk"
    
    eval $(block info | grep -o -e 'MOUNT="\S*/overlay"')
    
    if [ -b "${disk}1" ]; then
        uci set fstab.extroot="mount"
        uci set fstab.extroot.device="${disk}1"
        uci set fstab.extroot.target="${MOUNT}"
        uci set fstab.extroot.enabled="1"
        echo "  Настроен extroot: ${disk}1" | tee -a $LOG
    fi
    
    # Ищем swap раздел (может быть не вторым по счету)
    local swap_found=0
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -b "${disk}${i}" ]; then
            local fs_type=$(blkid -s TYPE -o value "${disk}${i}" 2>/dev/null)
            local label=$(blkid -s LABEL -o value "${disk}${i}" 2>/dev/null)
            if [ "$fs_type" = "swap" ] || [ "$label" = "swap" ]; then
                uci set fstab.swap="swap"
                uci set fstab.swap.device="${disk}${i}"
                uci set fstab.swap.enabled="1"
                echo "  Настроен swap: ${disk}${i}" | tee -a $LOG
                swap_found=1
                break
            fi
        fi
    done
    
    # Ищем data раздел
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -b "${disk}${i}" ] && [ "$i" -ne 1 ]; then
            local label=$(blkid -s LABEL -o value "${disk}${i}" 2>/dev/null)
            if [ "$label" = "data" ] || [ "$label" = "extra" ]; then
                uci set fstab.data="mount"
                uci set fstab.data.device="${disk}${i}"
                uci set fstab.data.target="/mnt/data"
                uci set fstab.data.enabled="1"
                echo "  Настроен data: ${disk}${i}" | tee -a $LOG
                break
            fi
        fi
    done
    
    # Ищем extra раздел
    for i in 1 2 3 4 5 6 7 8 9; do
        if [ -b "${disk}${i}" ] && [ "$i" -ne 1 ]; then
            local label=$(blkid -s LABEL -o value "${disk}${i}" 2>/dev/null)
            if [ "$label" = "extra" ]; then
                uci set fstab.extra="mount"
                uci set fstab.extra.device="${disk}${i}"
                uci set fstab.extra.target="/mnt/extra"
                uci set fstab.extra.enabled="1"
                echo "  Настроен extra: ${disk}${i}" | tee -a $LOG
                break
            fi
        fi
    done
    
    uci commit fstab || error_exit "Ошибка сохранения конфигурации fstab"
    
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
                echo "✅ Extroot раздел найден (${DISK}1)" | tee -a $LOG
            fi
        fi
        
        if [ "$has_extroot" -eq 0 ]; then
            echo "❌ Extroot раздел отсутствует!" | tee -a $LOG
            echo "Пытаюсь создать недостающие разделы без потери данных..." | tee -a $LOG
            
            # Пробуем создать недостающие разделы
            NEW_PART_COUNT=$(create_missing_partitions "$DISK" "$DISK_SIZE_GB" "$EXISTING_PARTS")
            CREATE_RESULT=$?
            
            if [ $CREATE_RESULT -eq 0 ] && [ -n "$NEW_PART_COUNT" ] && [ "$NEW_PART_COUNT" -gt 0 ]; then
                echo "✅ Недостающие разделы успешно созданы" | tee -a $LOG
                PART_COUNT="$NEW_PART_COUNT"
                configure_fstab "$DISK" "$PART_COUNT"
                
                # Проверяем, нужно ли копировать данные в extroot
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
            
            # Пробуем создать недостающие разделы (swap, data, extra)
            NEW_PART_COUNT=$(create_missing_partitions "$DISK" "$DISK_SIZE_GB" "$EXISTING_PARTS")
            CREATE_RESULT=$?
            
            if [ $CREATE_RESULT -eq 0 ] && [ -n "$NEW_PART_COUNT" ] && [ "$NEW_PART_COUNT" -gt 0 ]; then
                echo "✅ Недостающие разделы успешно созданы" | tee -a $LOG
                PART_COUNT="$NEW_PART_COUNT"
            else
                PART_COUNT="$EXISTING_PARTS"
            fi
            
            configure_fstab "$DISK" "$PART_COUNT"
            
            # Проверяем, нужно ли копировать данные в extroot
            OVERLAY_MOUNT=$(block info | grep 'MOUNT="[^"]*/overlay"' | cut -d'"' -f2)
            if [ -n "$OVERLAY_MOUNT" ] && [ -b "${DISK}1" ] && ! mountpoint -q "$OVERLAY_MOUNT" 2>/dev/null; then
                MOUNT="$OVERLAY_MOUNT"
                echo "Extroot еще не настроен. Копирую данные..." | tee -a $LOG
                copy_to_extroot "$DISK"
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
    echo "Настройка fstab завершена успешно!" | tee -a $LOG

    # Автоматическая перезагрузка всегда при изменении разметки
    if [ "$EXISTING_PARTS" -eq 0 ] || [ "$CHECK_RESULT" = "false" ]; then
        echo "Перезагружаюсь для применения изменений..." | tee -a $LOG
        sleep 3
        reboot
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
        fi
    fi

}

# Запускаем основной код
main
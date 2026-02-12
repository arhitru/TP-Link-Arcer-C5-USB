#!/bin/sh
# ============================================================================
# OpenWrt Required Setup Script
# ============================================================================
# Автоматическая установка необходимых пакетов для OpenWrt
# Версия: 2.0
# ============================================================================

set -e  # Прерывать выполнение при ошибке

# ============================================================================
# Конфигурация
# ============================================================================
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$0")
LOG_DIR="/root"
LOG_FILE="${LOG_DIR}/setup_required_$(date +%Y%m%d_%H%M%S).log"
PID_FILE="/var/run/${SCRIPT_NAME}.pid"
LOCK_FILE="/var/lock/${SCRIPT_NAME}.lock"
CONFIG_FILE="${SCRIPT_DIR}/setup_required.conf"
RETRY_COUNT=5

# Режим выполнения (auto/interactive)
if [ "$1" = "--auto" ] || [ "$1" = "-a" ]; then
    AUTO_MODE=1
    export AUTO_MODE
else
    AUTO_MODE=0
    export AUTO_MODE
fi

# ============================================================================
# Функции логирования
# ============================================================================
init_logging() {
    # Создаем директорию для логов если её нет
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR"
    fi
    
    # Перенаправляем весь вывод в лог-файл и в syslog
    exec 3>&1 4>&2
    exec 1> >(tee -a "$LOG_FILE" | logger -t "$SCRIPT_NAME" -p user.info)
    exec 2> >(tee -a "$LOG_FILE" | logger -t "$SCRIPT_NAME" -p user.err)
    
    echo "================================================================================"
    echo "=== Начало установки: $(date) ==="
    echo "=== Режим выполнения: $([ $AUTO_MODE -eq 1 ] && echo "AUTO" || echo "INTERACTIVE") ==="
    echo "=== Лог-файл: $LOG_FILE ==="
    echo "================================================================================"
}

log_info() {
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    printf "\033[32;1m[INFO] %s\033[0m\n" "$1" >&3 2>/dev/null || true
}

log_warn() {
    echo "[WARN] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    printf "\033[33;1m[WARN] %s\033[0m\n" "$1" >&3 2>/dev/null || true
}

log_error() {
    echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    printf "\033[31;1m[ERROR] %s\033[0m\n" "$1" >&3 2>/dev/null || true
}

log_success() {
    echo "[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') - $1"
    printf "\033[34;1m[SUCCESS] %s\033[0m\n" "$1" >&3 2>/dev/null || true
}

log_debug() {
    if [ "$DEBUG" = "1" ]; then
        echo "[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') - $1"
        printf "\033[36;1m[DEBUG] %s\033[0m\n" "$1" >&3 2>/dev/null || true
    fi
}

# ============================================================================
# Функции управления выполнением
# ============================================================================
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Этот скрипт должен выполняться от root"
        exit 1
    fi
}

check_single_instance() {
    if [ -f "$LOCK_FILE" ]; then
        if kill -0 "$(cat "$LOCK_FILE")" 2>/dev/null; then
            log_error "Скрипт уже запущен (PID: $(cat "$LOCK_FILE"))"
            exit 1
        else
            log_warn "Обнаружен устаревший lock-файл, удаляем"
            rm -f "$LOCK_FILE"
        fi
    fi
    
    echo $$ > "$LOCK_FILE"
    trap 'rm -f "$LOCK_FILE" "$PID_FILE"; log_info "Скрипт завершен"; exec 1>&3 2>&4' EXIT
    echo $$ > "$PID_FILE"
}

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        log_info "Загружаем конфигурацию из $CONFIG_FILE"
        # shellcheck source=/dev/null
        . "$CONFIG_FILE"
    else
        log_warn "Файл конфигурации не найден, используем значения по умолчанию"
        # Создаем конфиг по умолчанию
        cat > "$CONFIG_FILE" << 'EOF'
# ============================================================================
# Конфигурация установки пакетов для OpenWrt
# ============================================================================

# Список обязательных пакетов
REQUIRED_PACKAGES="
kmod-leds-gpio
odhcp6c
odhcpd-ipv6only
ppp
ppp-mod-pppoe
kmod-usb-ledtrig-usbport
igmpproxy
"

# Пакеты для замены
REPLACE_PACKAGES="
dnsmasq:dnsmasq-full
wpad-basic-mbedtls:wpad-mesh-openssl
"

# Настройки NTP серверов
NTP_SERVERS="ptbtime1.ptb.de pool.ntp.org"

# Таймаут для операций (секунды)
OPKG_TIMEOUT=300

# Количество попыток при ошибке
RETRY_COUNT=3

# Режим отладки (0/1)
DEBUG=0
EOF
        log_info "Создан файл конфигурации по умолчанию: $CONFIG_FILE"
    fi
}

# ============================================================================
# Функции проверки системы
# ============================================================================
check_system() {
    log_info "=== Проверка системы ==="
    
    # Проверка модели устройства
    if [ -f /tmp/sysinfo/model ]; then
        MODEL=$(cat /tmp/sysinfo/model)
        log_info "Модель устройства: $MODEL"
    else
        MODEL="Unknown"
        log_warn "Не удалось определить модель устройства"
    fi
    
    # Проверка версии OpenWrt
    if [ -f /etc/os-release ]; then
        # shellcheck source=/etc/os-release
        . /etc/os-release
        log_info "Версия OpenWrt: $OPENWRT_RELEASE"
        
        VERSION=$(grep 'VERSION=' /etc/os-release | cut -d'"' -f2)
        VERSION_ID=$(echo "$VERSION" | awk -F. '{print $1}')
        export VERSION_ID
        
        # Проверка совместимости
        if [ "$VERSION_ID" -lt 19 ]; then
            log_warn "Версия OpenWrt ($VERSION_ID) может быть несовместима"
        fi
    else
        VERSION_ID=0
        log_warn "Не удалось определить версию OpenWrt"
    fi
    
    # Проверка свободного места
    check_disk_space
    
    # Проверка интернета
    check_internet
    
    # Проверка синхронизации времени
    check_time_sync
}

check_disk_space() {
    local free_space
    free_space=$(df /overlay | awk 'NR==2 {print $4}')
    local free_space_mb=$((free_space / 1024))
    
    log_info "Свободное место на overlay: ${free_space_mb}MB"
    
    if [ "$free_space_mb" -lt 10 ]; then
        log_error "Недостаточно свободного места (<10MB). Требуется минимум 20MB"
        exit 1
    elif [ "$free_space_mb" -lt 20 ]; then
        log_warn "Мало свободного места (<20MB). Установка может не завершиться успешно"
        if [ $AUTO_MODE -eq 0 ]; then
            echo -n "Продолжить? (y/N): " >&3
            read -r answer
            if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
                exit 1
            fi
        fi
    fi
}

check_internet() {
    log_info "Проверка подключения к интернету..."
    
    local test_hosts="openwrt.org google.com cloudflare.com"
    local connected=0
    
    for host in $test_hosts; do
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
            log_info "Подключение к $host успешно"
            connected=1
            break
        fi
    done
    
    if [ $connected -eq 0 ]; then
        log_error "Нет подключения к интернету"
        return 1
    fi
    
    return 0
}

check_time_sync() {
    log_info "Проверка синхронизации времени..."
    
    local current_year
    current_year=$(date +%Y)
    
    if [ "$current_year" -lt 2023 ]; then
        log_warn "Время не синхронизировано: $(date)"
        
        if [ $AUTO_MODE -eq 1 ]; then
            log_info "Автоматическая синхронизация времени..."
            for ntp_server in $NTP_SERVERS; do
                if ntpd -n -q -p "$ntp_server" >/dev/null 2>&1; then
                    log_success "Время синхронизировано с $ntp_server"
                    break
                fi
            done
        else
            echo -n "Синхронизировать время? (Y/n): " >&3
            read -r answer
            if [ "$answer" != "n" ] && [ "$answer" != "N" ]; then
                for ntp_server in $NTP_SERVERS; do
                    if ntpd -n -q -p "$ntp_server" >/dev/null 2>&1; then
                        log_success "Время синхронизировано с $ntp_server"
                        break
                    fi
                done
            fi
        fi
    else
        log_info "Время синхронизировано: $(date)"
    fi
}

# ============================================================================
# Функции работы с opkg
# ============================================================================
configure_opkg() {
    log_info "Настройка opkg..."
    
    # Сохранение списков пакетов на extroot
    if grep -q "^lists_dir\s*ext\s*/usr/lib/opkg/lists" /etc/opkg.conf 2>/dev/null; then
        log_info "Конфигурация opkg уже настроена"
    else
        sed -i -r -e "s/^(lists_dir\sext\s).*/\1\/usr\/lib\/opkg\/lists/" /etc/opkg.conf
        log_success "Конфигурация opkg обновлена"
    fi
}

update_opkg() {
    log_info "Обновление списков пакетов..."

    local retry=0
    while [ $retry -lt $RETRY_COUNT ]; do
        if opkg update > /tmp/opkg_update.log 2>&1; then
            log_success "Списки пакетов успешно обновлены"
            cat /tmp/opkg_update.log >> "$LOG_FILE"
            rm -f /tmp/opkg_update.log
            return 0
        else
            retry=$((retry + 1))
            log_warn "Попытка $retry из $RETRY_COUNT не удалась"
            sleep 5
        fi
    done
    
    log_error "Не удалось обновить списки пакетов после $RETRY_COUNT попыток"
    cat /tmp/opkg_update.log >> "$LOG_FILE"
    rm -f /tmp/opkg_update.log
    return 1
}

install_package() {
    local pkg=$1
    local retry=0
    
    if opkg list-installed | grep -q "^$pkg "; then
        log_info "Пакет $pkg уже установлен"
        return 0
    fi
    
    log_info "Установка пакета: $pkg"
    
    while [ $retry -lt $RETRY_COUNT ]; do
        if opkg install "$pkg" > /tmp/opkg_install.log 2>&1; then
            cat /tmp/opkg_install.log >> "$LOG_FILE"
            log_success "Пакет $pkg успешно установлен"
            rm -f /tmp/opkg_install.log
            return 0
        else
            retry=$((retry + 1))
            log_warn "Попытка $retry из $RETRY_COUNT установки $pkg не удалась"
            sleep 5
        fi
    done
    
    log_error "Не удалось установить пакет $pkg после $RETRY_COUNT попыток"
    cat /tmp/opkg_install.log >> "$LOG_FILE"
    rm -f /tmp/opkg_install.log
    
    if [ $AUTO_MODE -eq 0 ]; then
        echo -n "Продолжить выполнение? (y/N): " >&3
        read -r answer
        if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
            exit 1
        fi
    fi
    
    return 1
}

replace_package() {
    local old_pkg=$1
    local new_pkg=$2
    
    log_info "Замена пакета $old_pkg на $new_pkg..."
    
    if ! opkg list-installed | grep -q "^$old_pkg "; then
        log_info "Пакет $old_pkg не установлен"
    fi
    
    if opkg list-installed | grep -q "^$new_pkg "; then
        log_info "Пакет $new_pkg уже установлен"
        return 0
    fi
    
    # Создаем временную директорию для кэша
    local tmp_dir="/tmp"
    
    # Скачиваем новый пакет
    if ! opkg download "$new_pkg" --cache /tmp > /tmp/opkg_download.log 2>&1; then
        log_error "Не удалось скачать пакет $new_pkg"
        cat /tmp/opkg_download.log >> "$LOG_FILE"
        rm -rf /tmp/opkg_download.log
        return 1
    fi
    
    # Удаляем старый пакет
    if opkg list-installed | grep -q "^$old_pkg "; then
        log_info "Удаление пакета $old_pkg..."
        if ! opkg remove "$old_pkg" --force-depends > /tmp/opkg_remove.log 2>&1; then
            log_warn "Проблемы при удалении $old_pkg"
            cat /tmp/opkg_remove.log >> "$LOG_FILE"
        fi
        rm -f /tmp/opkg_remove.log
    fi
    
    # Устанавливаем новый пакет
    if opkg install "$new_pkg" --cache /tmp > /tmp/opkg_install.log 2>&1; then
        cat /tmp/opkg_install.log >> "$LOG_FILE"
        log_success "Пакет $new_pkg успешно установлен"
        rm -rf /tmp/opkg_install.log /tmp/opkg_download.log
        return 0
    else
        log_error "Не удалось установить пакет $new_pkg"
        cat /tmp/opkg_install.log >> "$LOG_FILE"
        rm -rf /tmp/opkg_install.log /tmp/opkg_download.log
        return 1
    fi
}

# ============================================================================
# Функции настройки системы
# ============================================================================
setup_firewall_rules() {
    log_info "Настройка правил firewall..."
    
    # Правило для IGMP
    if uci show firewall | grep -q "\.name='Allow-IGMP'"; then
        log_info "Правило 'Allow-IGMP' уже существует"
    else
        log_info "Добавление правила 'Allow-IGMP'"
        uci add firewall rule
        uci set firewall.@rule[-1]=rule
        uci set firewall.@rule[-1].name='Allow-IGMP'
        uci set firewall.@rule[-1].src='wan'
        uci set firewall.@rule[-1].proto='igmp'
        uci set firewall.@rule[-1].target='ACCEPT'
        uci commit firewall
        log_success "Правило 'Allow-IGMP' добавлено"
    fi
    
    # Правило для IGMPPROXY
    if uci show firewall | grep -q "\.name='Allow-IPTV-IGMPPROXY'"; then
        log_info "Правило 'Allow-IPTV-IGMPPROXY' уже существует"
    else
        log_info "Добавление правила 'Allow-IPTV-IGMPPROXY'"
        uci add firewall rule
        uci set firewall.@rule[-1]=rule
        uci set firewall.@rule[-1].name='Allow-IPTV-IGMPPROXY'
        uci set firewall.@rule[-1].src='wan'
        uci set firewall.@rule[-1].dest='lan'
        uci set firewall.@rule[-1].dest_ip='224.0.0.0/4'
        uci set firewall.@rule[-1].proto='udp'
        uci set firewall.@rule[-1].target='ACCEPT'
        uci commit firewall
        log_success "Правило 'Allow-IPTV-IGMPPROXY' добавлено"
    fi
    
    # Перезапуск firewall если были изменения
    if [ -n "$(uci changes firewall)" ]; then
        log_info "Применение изменений firewall..."
        /etc/init.d/firewall reload 2>&1 | tee -a "$LOG_FILE"
        log_success "Firewall перезагружен"
    fi
}

backup_configs() {
    local backup_dir="${LOG_DIR}/backups/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    
    log_info "Создание резервной копии конфигурации в $backup_dir"
    
    # Резервное копирование важных конфигов
    if [ -f /etc/config/dhcp ]; then
        cp /etc/config/dhcp "$backup_dir/dhcp.bak"
    fi
    
    if [ -f /etc/config/firewall ]; then
        cp /etc/config/firewall "$backup_dir/firewall.bak"
    fi
    
    if [ -f /etc/opkg.conf ]; then
        cp /etc/opkg.conf "$backup_dir/opkg.conf.bak"
    fi
    
    # Сохраняем список установленных пакетов
    opkg list-installed | sort > "${backup_dir}/packages.list"
    
    log_success "Резервная копия создана"
}

generate_report() {
    local report_file="${LOG_DIR}/report_$(date +%Y%m%d_%H%M%S).txt"
    
    {
        echo "================================================================================"
        echo "ОТЧЕТ ОБ УСТАНОВКЕ"
        echo "================================================================================"
        echo "Дата и время: $(date)"
        echo "Скрипт: $SCRIPT_NAME"
        echo "Лог-файл: $LOG_FILE"
        echo ""
        echo "СИСТЕМНАЯ ИНФОРМАЦИЯ:"
        echo "  Модель: $MODEL"
        echo "  Версия: $OPENWRT_RELEASE"
        echo "  Свободное место: $(df -h /overlay | awk 'NR==2 {print $4}')"
        echo ""
        echo "УСТАНОВЛЕННЫЕ ПАКЕТЫ:"
        for pkg in $REQUIRED_PACKAGES; do
            if opkg list-installed | grep -q "^$pkg "; then
                echo "  [OK] $pkg"
            else
                echo "  [FAIL] $pkg"
            fi
        done
        echo ""
        echo "ПРАВИЛА FIREWALL:"
        if uci show firewall | grep -q "Allow-IGMP"; then
            echo "  [OK] Allow-IGMP"
        else
            echo "  [FAIL] Allow-IGMP"
        fi
        if uci show firewall | grep -q "Allow-IPTV-IGMPPROXY"; then
            echo "  [OK] Allow-IPTV-IGMPPROXY"
        else
            echo "  [FAIL] Allow-IPTV-IGMPPROXY"
        fi
        echo "================================================================================"
    } > "$report_file"
    
    log_info "Отчет сохранен в $report_file"
}

# ============================================================================
# Основная функция
# ============================================================================
main() {
    # Инициализация
    check_root
    check_single_instance
    init_logging
    
    log_info "=== НАЧАЛО УСТАНОВКИ ==="
    log_info "PID: $$"
    
    # Загрузка конфигурации
    load_config
    
    # Резервное копирование
    backup_configs
    
    # Проверка системы
    if ! check_system; then
        log_error "Проверка системы не пройдена"
        exit 1
    fi
    
    # Настройка opkg
    configure_opkg
    
    # Обновление списков пакетов
    if ! update_opkg; then
        log_error "Не удалось обновить списки пакетов"
        exit 1
    fi
    
    # Установка  пакетов
    log_info "=== УСТАНОВКА ПАКЕТОВ ==="
     echo "пакеты - $REQUIRED_PACKAGES "
    for pkg in $REQUIRED_PACKAGES; do
        install_package "$pkg"
    done
    
    # Замена пакетов
    log_info "=== ЗАМЕНА ПАКЕТОВ ==="
    
    for replace_pair in $REPLACE_PACKAGES; do
        old_pkg=$(echo "$replace_pair" | cut -d: -f1)
        new_pkg=$(echo "$replace_pair" | cut -d: -f2)
        replace_package "$old_pkg" "$new_pkg"
    done
    
    # Настройка IPTV
    log_info "=== НАСТРОЙКА IPTV ==="
    setup_firewall_rules
    
    # Создание отчета
    generate_report
    
    log_success "=== УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА ==="
    log_info "Полный лог доступен в: $LOG_FILE"
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - setup_required.sh завершил работу" >> /root/postboot.log
    
    if [ $AUTO_MODE -eq 0 ]; then
        echo -n "Перезагрузить систему сейчас? (y/N): " >&3
        read -r answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            log_info "Перезагрузка системы..."
            reboot
        fi
    fi
}

# Запуск основной функции
main "$@"
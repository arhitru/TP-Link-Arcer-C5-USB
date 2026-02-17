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
SCRIPT_DIR=/root
LOG_DIR="/root/logs"
LOG_FILE="${LOG_DIR}/setup_$(date +%Y%m%d_%H%M%S).log"
PID_FILE="/var/run/${SCRIPT_NAME}.pid"
LOCK_FILE="/var/lock/${SCRIPT_NAME}.lock"
CONFIG_FILE="${SCRIPT_DIR}/setup_required.conf"
OUTLINE_CONFIG_FILE="${SCRIPT_DIR}/outline.conf"
RETRY_COUNT=5
DEBUG=0
LOG=$LOG_FILE

# Режим выполнения (auto/interactive)
if [ "$1" = "--auto" ] || [ "$1" = "-a" ]; then
    AUTO_MODE=1
else
    AUTO_MODE=0
    # Определяем режим выполнения (интерактивный или автоматический)
    if [ ! -t 0 ]; then
        AUTO_MODE=1
    fi
fi
export AUTO_MODE


echo "=== Начало установки: $(date) ===" > $LOG_FILE

# Проверяем что система загрузилась
echo "Проверка системы:" | tee -a $LOG_FILE
uptime >> $LOG_FILE 2>&1
ifconfig >> $LOG_FILE 2>&1

# Ждем запуска сети
echo "Ожидание сети..." | tee -a $LOG_FILE
for i in $(seq 1 30); do
    if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        echo "Сеть доступна" | tee -a $LOG_FILE
        break
    fi
    sleep 1
done

# ============================================================================
# Импорт функций логирования
# ============================================================================
if [ ! -f "/root/logging_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/logging_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/logging_functions.sh
fi
. /root/logging_functions.sh

# ============================================================================
# Функции управления выполнением
# ============================================================================
if [ ! -f "/root/execution_management_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/execution_management_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/execution_management_functions.sh
fi
. /root/execution_management_functions.sh

load_config() {
    if [! -f "$CONFIG_FILE" ]; then
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
    log_info "Загружаем конфигурацию из $CONFIG_FILE"
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
}

# ============================================================================
# Функции проверки системы
# ============================================================================
if [ ! -f "/root/system_verification_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/system_verification_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/system_verification_functions.sh
fi
. /root/system_verification_functions.sh

# ============================================================================
# Функции работы с opkg
# ============================================================================
if [ ! -f "/root/opkg_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/opkg_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/opkg_functions.sh
fi
. /root/opkg_functions.sh

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
    log_info "пакеты - $REQUIRED_PACKAGES "
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
    
    # --------------------------------------------------
    # ОЧИСТКА: делаем запуск однократным
    # --------------------------------------------------
    log_info "Очистка..."

    # 1. Удаляем вызов из rc.local
    if [ -f /etc/rc.local ]; then
        # Создаем чистую версию без нашего вызова
        grep -v "setup_required2.sh" /etc/rc.local > /root/rc.local.new
        if [ $? -eq 0 ]; then
            mv /root/rc.local.new /etc/rc.local
            chmod +x /etc/rc.local
            log_info "setup_required удален из rc.local"
        fi
    fi

    # 2. Удаляем сам скрипт
    rm -f /root/setup_required2.sh >> $LOG_FILE 2>&1
    log_warn "Скрипт setup_required удален"

    log_info "=== Post-boot завершен: $(date) ==="

    if [ $AUTO_MODE -eq 0 ]; then
        log_question "Перезагрузить систему сейчас? (y/N): "
        read answer
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            log_info "Перезагрузка системы..."
            reboot
        else
            log_info "Перезагрузка отменена пользователем"
        fi
    fi
}

# Запуск основной функции
main "$@"
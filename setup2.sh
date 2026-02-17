#!/bin/sh
# Основной скрипт установки/настройки OpenWRT
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$0")
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

# Инициализируем логирование
init_logging

if [ -t 0 ]; then
    log_question "Do you have the Outline key? [y/N]: "
    read OUTLINE
    if [ "$OUTLINE" = "y" ] || [ "$OUTLINE" = "Y" ]; then
        log_question "Do you want to set up an Outline VPN? [y/N]: "
        read TUN
        if [ "$TUN" = "y" ] || [ "$TUN" = "Y" ]; then
            export TUNNEL="tun2socks"
            # Считывает пользовательскую переменную для конфигурации Outline (Shadowsocks)
            log_question "Enter Outline (Shadowsocks) Config (format ss://base64coded@HOST:PORT/?outline=1): "
            read OUTLINECONF
            export  OUTLINECONF=$OUTLINECONF

            log_question "Configure DNSCrypt2 or Stubby? It does matter if your ISP is spoofing DNS requests"
            log_question "Select:"
            log_question "1) No [Default]"
            log_question "2) DNSCrypt2 (10.7M)"
            log_question "3) Stubby (36K)"

            while true; do
            read -r -p '' DNS_RESOLVER
                case $DNS_RESOLVER in 

                1) 
                    log_info "Skiped"
                    break
                    ;;

                2)
                    log_info "DNSCRYPT"
                    export DNS_RESOLVER="DNSCRYPT"
                    break
                    ;;

                3) 
                    log_info "STUBBY"
                    export DNS_RESOLVER="STUBBY"
                    break
                    ;;

                *)
                    log_warn "Choose from the following options"
                    ;;
                esac
            done

            log_question "Choose you country"
            log_question "Select:"
            log_question "1) Russia inside. You are inside Russia"
            log_question "2) Russia outside. You are outside of Russia, but you need access to Russian resources"
            log_question "3) Ukraine. uablacklist.net list"
            log_question "4) Skip script creation"

            while true; do
            read -r -p '' COUNTRY
                case $COUNTRY in 

                1) 
                    log_info "Russia inside. You are inside Russia"
                    export COUNTRY="russia_inside"
                    break
                    ;;

                2)
                    log_info "Russia outside. You are outside of Russia, but you need access to Russian resources"
                    export COUNTRY="russia_outside"
                    break
                    ;;

                3) 
                    log_info "Ukraine. uablacklist.net list"
                    export COUNTRY="ukraine"
                    break
                    ;;

                4) 
                    log_warn "Skiped"
                    export COUNTRY=0
                    break
                    ;;

                *)
                    log_warn "Choose from the following options"
                    ;;
                esac
            done
            # Ask user to use Outline as default gateway
            # Задает вопрос пользователю о том, следует ли использовать Outline в качестве шлюза по умолчанию
            log_question "Use Outline as default gateway? [y/N]: "
            read DEFAULT_GATEWAY
            if [ "$DEFAULT_GATEWAY" = "y" ] || [ "$DEFAULT_GATEWAY" = "Y" ]; then
                export OUTLINE_DEFAULT_GATEWAY=$DEFAULT_GATEWAY
            fi
            if [! -f "$CONFIG_FILE" ]; then
                log_info "Файл конфигурации Outline"
                cat > "$CONFIG_FILE" << 'EOF'
# ============================================================================
# Конфигурация outline_vpn
# ============================================================================

TUNNEL="tun2socks"
OUTLINECONF=$OUTLINECONF
DNS_RESOLVER=$DNS_RESOLVER
COUNTRY=$COUNTRY
OUTLINE_DEFAULT_GATEWAY=$DEFAULT_GATEWAY
VERSION_ID=$VERSION_ID

# Список обязательных пакетов
REQUIRED_PACKAGES="
curl
nano
kmod-tun
ip-full
"

# Пакеты для замены
REPLACE_PACKAGES="
dnsmasq:dnsmasq-full
"

# Таймаут для операций (секунды)
OPKG_TIMEOUT=300

# Количество попыток при ошибке
RETRY_COUNT=3

# Режим отладки (0/1)
DEBUG=0
EOF
                log_info "Создан файл конфигурации по умолчанию: $CONFIG_FILE"
                cd /root && wget https://raw.githubusercontent.com/arhitru/install_outline/refs/heads/main/install_outline_for_getdomains.sh && chmod +x install_outline_for_getdomains.sh

            fi
        fi
    fi
fi

# --------------------------------------------------
# ШАГ 1: Предварительные настройки
# --------------------------------------------------
log_info "1. Настройка системы..."

# Разметка и подключение USB
if [ ! -f "/root/mount_usb.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/mount_usb2.sh >> $LOG_FILE 2>&1 && chmod +x mount_usb2.sh
fi
. /root/mount_usb2.sh

# Установка недостающих пакетов
if [ ! -f "/root/postboot.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/postboot.sh >> $LOG_FILE 2>&1
fi
if [ ! -f "/root/setup_required.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required.sh >> $LOG_FILE 2>&1 && chmod +x setup_required.sh
fi
if [ ! -f "/root/setup_required.conf" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required.conf >> $LOG_FILE 2>&1
fi

# --------------------------------------------------
# ШАГ 2: Подготовка пост-перезагрузочного скрипта
# --------------------------------------------------
log_info "2. Подготовка пост-перезагрузки..."

# Создаем скрипт
if [ ! -f "/root/postboot.sh" ]; then
    cat << 'EOF' > /root/postboot.sh
#!/bin/sh
# Этот скрипт выполнится один раз после перезагрузки

LOG="/root/postboot.log"
echo "=== Post-boot начат: $(date) ===" > $LOG

# Ждем полной загрузки
sleep 60

# Проверяем что система загрузилась
echo "Проверка системы:" >> $LOG
uptime >> $LOG 2>&1
ifconfig >> $LOG 2>&1

# Ждем запуска сети
echo "Ожидание сети..."
for i in $(seq 1 30); do
    if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        echo "Сеть доступна"  >> $LOG
        break
    fi
    sleep 1
done

# ФИНАЛЬНЫЕ НАСТРОЙКИ:
echo "Выполняю финальные настройки..." >> $LOG

if [ ! -f "/root/setup_required.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required.sh >> $LOG 2>&1 && chmod +x setup_required.sh
fi

/root/setup_required.sh

# --------------------------------------------------
# ОЧИСТКА: делаем запуск однократным
# --------------------------------------------------
echo "Очистка..." >> $LOG

# 1. Удаляем вызов из rc.local
if [ -f /etc/rc.local ]; then
    # Создаем чистую версию без нашего вызова
    grep -v "postboot.sh" /etc/rc.local > /root/rc.local.new
    if [ $? -eq 0 ]; then
        mv /root/rc.local.new /etc/rc.local
        chmod +x /etc/rc.local
        echo "Удалено из rc.local" >> $LOG
    fi
fi

# 2. Удаляем сам скрипт
rm -f /root/postboot.sh
echo "Скрипт удален" >> $LOG

# 3. Создаем флаг завершения
echo "COMPLETED_AT_$(date +%s)" > /root/.postboot_done

echo "=== Post-boot завершен: $(date) ===" >> $LOG
exit 0
EOF
fi

chmod +x /root/postboot.sh

# --------------------------------------------------
# ШАГ 3: Настройка автозапуска
# --------------------------------------------------
log_info "3. Настройка автозапуска..."

# Создаем или обновляем rc.local
if [ ! -f /etc/rc.local ]; then
    echo '#!/bin/sh' > /etc/rc.local
    echo '' >> /etc/rc.local
fi

# Проверяем, не добавлен ли уже наш скрипт
if ! grep -q "postboot.sh" /etc/rc.local; then
    # Добавляем вызов в конец (но перед exit если есть)
    if grep -q "^exit" /etc/rc.local; then
        # Вставляем перед exit
        sed -i '/^exit/i # Auto-generated post-boot script (will self-remove)\n/root/postboot.sh &' /etc/rc.local
    else
        # Добавляем в конец
        echo '' >> /etc/rc.local
        echo '# Auto-generated post-boot script (will self-remove)' >> /etc/rc.local
        echo '/root/postboot.sh' >> /etc/rc.local
    fi
    
    log_info "Добавлено в автозагрузку"
else
    log_info "Уже в автозагрузке"
fi
if [ "$TUN" = "y" ] || [ "$TUN" = "Y" ]; then
    log_info "Установка автозапуска настройки Outline VPN"
    # Проверяем, не добавлен ли уже наш скрипт
    if ! grep -q "install_outline_for_getdomains.sh" /etc/rc.local; then
        # Добавляем вызов в конец (но перед exit если есть)
        if grep -q "^exit" /etc/rc.local; then
            # Вставляем перед exit
            sed -i '/^exit/i # Auto-generated post-boot script (will self-remove)\n/root/install_outline_for_getdomains.sh &' /etc/rc.local
        else
            # Добавляем в конец
            echo '' >> /etc/rc.local
            echo '# Auto-generated post-boot script (will self-remove)' >> /etc/rc.local
            echo '/root/install_outline_for_getdomains.sh' >> /etc/rc.local
        fi
        
        log_info "install_outline_for_getdomains добавлен в автозагрузку"
    else
        log_info "install_outline_for_getdomains уже в автозагрузке"
    fi
fi

# Показываем итог
log_info "Итоговый rc.local:"
cat /etc/rc.local | tee -a $LOG

# --------------------------------------------------
# ШАГ 4: Настройка USB
# --------------------------------------------------
log_info "4. Настройка USB"
mount_usb_main

# --------------------------------------------------
# ШАГ 5: Перезагрузка
# --------------------------------------------------
log_info "5. Подготовка к перезагрузке..."
log_info "Все настройки сохранены."
log_info "После перезагрузки скрипт выполнится автоматически."
log_info "Лог будет в /root/postboot.log"

# Удаляем сам скрипт
rm -f /root/setup.sh
log_info "Скрипт удален"

# Перезагрузка
    if [ -t 0 ]; then
        log_question "Перезагрузить сейчас? [y/N]: "
        read REBOOT_NOW
        if [ "$REBOOT_NOW" = "y" ] || [ "$REBOOT_NOW" = "Y" ]; then
            log_info "Перезагружаюсь..."
            sleep 3
            reboot
        else
            log_warn "Перезагрузка отложена. Рекомендуется перезагрузить систему вручную."
        fi
    else
        log_info "=== Начинаю перезагрузку ==="
        sync
        reboot
    fi
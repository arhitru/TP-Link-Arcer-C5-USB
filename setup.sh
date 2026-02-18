#!/bin/sh
# Основной скрипт установки/настройки OpenWRT
DISK="/dev/sda"
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=/root
LOG_DIR="/root"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
PID_FILE="/var/run/${SCRIPT_NAME}.pid"
LOCK_FILE="/var/lock/${SCRIPT_NAME}.lock"
CONFIG_FILE="${SCRIPT_DIR}/setup_required.conf"
OUTLINE_CONFIG_FILE="${SCRIPT_DIR}/outline.conf"
RETRY_COUNT=5
DEBUG=0
LOG=$LOG_FILE

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

# ============================================================================
# Функции проверки системы
# ============================================================================
if [ ! -f "/root/system_verification_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/system_verification_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/system_verification_functions.sh
fi

# ============================================================================
# Функции работы с opkg
# ============================================================================
if [ ! -f "/root/opkg_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/opkg_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/opkg_functions.sh
fi

# ============================================================================
#  Функции настройки USB
# ============================================================================
if [ ! -f "/root/mount_usb_function.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/mount_usb_function.sh >> $LOG_FILE 2>&1 && chmod +x mount_usb_function.sh
fi


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

if [ -t 0 ]; then
    read -p "Do you have the Outline key? [y/N]: " OUTLINE
    if [ "$OUTLINE" = "y" ] || [ "$OUTLINE" = "Y" ]; then
        read -p "Do you want to set up an Outline VPN? [y/N]: " TUN
        if [ ! -f "/root/install_outline_settings.sh" ]; then
            cd /root && wget https://raw.githubusercontent.com/arhitru/install_outline/refs/heads/main/install_outline_settings.sh >> $LOG_FILE 2>&1 && chmod +x /root/install_outline_settings.sh
        fi
        if [ ! -f "/root/install_outline_for_getdomains.sh" ]; then
            cd /root && wget https://raw.githubusercontent.com/arhitru/install_outline/refs/heads/main/install_outline_for_getdomains.sh >> $LOG_FILE 2>&1 && chmod +x /root/install_outline_for_getdomains.sh
        fi
        if [ ! -f "/root/get_outline_settings.sh" ]; then
            cd /root && wget https://raw.githubusercontent.com/arhitru/install_outline/refs/heads/main/get_outline_settings.sh >> $LOG_FILE 2>&1 && chmod +x /root/get_outline_settings.sh
        fi
        ./get_outline_settings.sh

        if [ "$TUN" = "y" ] || [ "$TUN" = "Y" ]; then
            export TUNNEL="tun2socks"
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

            # Считывает пользовательскую переменную для конфигурации Outline (Shadowsocks)
            read -p "Enter Outline (Shadowsocks) Config (format ss://base64coded@HOST:PORT/?outline=1): " OUTLINECONF
            export  OUTLINECONF=$OUTLINECONF

            printf "\033[33mConfigure DNSCrypt2 or Stubby? It does matter if your ISP is spoofing DNS requests\033[0m\n"
            echo "Select:"
            echo "1) No [Default]"
            echo "2) DNSCrypt2 (10.7M)"
            echo "3) Stubby (36K)"

            while true; do
            read -r -p '' DNS_RESOLVER
                case $DNS_RESOLVER in 

                1) 
                    echo "Skiped"
                    break
                    ;;

                2)
                    export DNS_RESOLVER="DNSCRYPT"
                    break
                    ;;

                3) 
                    export DNS_RESOLVER="STUBBY"
                    break
                    ;;

                *)
                    echo "Choose from the following options"
                    ;;
                esac
            done

            printf "\033[33mChoose you country\033[0m\n"
            echo "Select:"
            echo "1) Russia inside. You are inside Russia"
            echo "2) Russia outside. You are outside of Russia, but you need access to Russian resources"
            echo "3) Ukraine. uablacklist.net list"
            echo "4) Skip script creation"

            while true; do
            read -r -p '' COUNTRY
                case $COUNTRY in 

                1) 
                    export COUNTRY="russia_inside"
                    break
                    ;;

                2)
                    export COUNTRY="russia_outside"
                    break
                    ;;

                3) 
                    export COUNTRY="ukraine"
                    break
                    ;;

                4) 
                    echo "Skiped"
                    export COUNTRY=0
                    break
                    ;;

                *)
                    echo "Choose from the following options"
                    ;;
                esac
            done
            # Ask user to use Outline as default gateway
            # Задает вопрос пользователю о том, следует ли использовать Outline в качестве шлюза по умолчанию
            read -p "Use Outline as default gateway? [y/N]: " DEFAULT_GATEWAY
            if [ "$DEFAULT_GATEWAY" = "y" ] || [ "$DEFAULT_GATEWAY" = "Y" ]; then
                export OUTLINE_DEFAULT_GATEWAY=$DEFAULT_GATEWAY
            fi
            if [ ! -f "$OUTLINE_CONFIG_FILE" ]; then
                echo "Файл конфигурации Outline" | tee -a $LOG
                cat > "$OUTLINE_CONFIG_FILE" << 'EOF'
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
                echo "Создан файл конфигурации по умолчанию: $OUTLINE_CONFIG_FILE" | tee -a $LOG
            fi
        fi
    fi
fi

# --------------------------------------------------
# ШАГ 1: Предварительные настройки
# --------------------------------------------------
echo "1. Настройка системы..." | tee -a $LOG

# Разметка и подключение USB
if [ ! -f "/root/mount_usb.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/mount_usb.sh >> $LOG 2>&1 && chmod +x mount_usb.sh
fi

# Установка недостающих пакетов
if [ ! -f "/root/postboot.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/postboot.sh >> $LOG 2>&1
fi
if [ ! -f "/root/setup_required.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required.sh >> $LOG 2>&1 && chmod +x setup_required.sh
fi
if [ ! -f "/root/setup_required.conf" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required.conf >> $LOG 2>&1
fi

# --------------------------------------------------
# ШАГ 2: Подготовка пост-перезагрузочного скрипта
# --------------------------------------------------
echo "2. Подготовка пост-перезагрузки..." | tee -a $LOG

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
echo "3. Настройка автозапуска..." | tee -a $LOG

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
        sed -i '/^exit/i # Auto-generated post-boot script (will self-remove)\n/root/postboot.sh' /etc/rc.local
    else
        # Добавляем в конец
        echo '' >> /etc/rc.local
        echo '# Auto-generated post-boot script (will self-remove)' >> /etc/rc.local
        echo '/root/postboot.sh' >> /etc/rc.local
    fi
    
    echo "Добавлено в автозагрузку" | tee -a $LOG
else
    echo "Уже в автозагрузке" | tee -a $LOG
fi

# Показываем итог
echo "Итоговый rc.local:" | tee -a $LOG
cat /etc/rc.local | tee -a $LOG

# --------------------------------------------------
# ШАГ 4: Настройка USB
# --------------------------------------------------
echo "4. Настройка USB" | tee -a $LOG
/root/mount_usb.sh

# --------------------------------------------------
# ШАГ 5: Перезагрузка
# --------------------------------------------------
echo "5. Подготовка к перезагрузке..." | tee -a $LOG
echo "Все настройки сохранены." | tee -a $LOG
echo "После перезагрузки скрипт выполнится автоматически." | tee -a $LOG
echo "Лог будет в /root/postboot.log" | tee -a $LOG

# Удаляем сам скрипт
rm -f /root/setup.sh
echo "Скрипт удален" >> $LOG

# Перезагрузка
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
        echo "=== Начинаю перезагрузку ===" | tee -a $LOG
        sync
        reboot
    fi
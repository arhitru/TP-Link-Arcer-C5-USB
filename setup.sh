#!/bin/sh
# Основной скрипт установки/настройки OpenWRT
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$0")
LOG_DIR="/root"
LOG_FILE="${LOG_DIR}/setup.log"
PID_FILE="/var/run/${SCRIPT_NAME}.pid"
LOCK_FILE="/var/lock/${SCRIPT_NAME}.lock"
RETRY_COUNT=5

CONFIG_FILE="${SCRIPT_DIR}/outline.conf"
LOG="/root/setup.log"

if [ ! -f "/root/logging_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/logging_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/logging_functions.sh
fi
. /root/logging_functions.sh
init_logging

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
        if [ "$TUN" = "y" ] || [ "$TUN" = "Y" ]; then
            if [ ! -f "/root/install_outline_settings.sh" ]; then
                cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/install_outline_settings.sh >> $LOG_FILE 2>&1 && chmod +x /root/install_outline_settings.sh
            fi
            . /root/install_outline_settings.sh
        fi
    fi
fi

# --------------------------------------------------
# ШАГ 1: Предварительные настройки
# --------------------------------------------------
echo "1. Настройка системы..." | tee -a $LOG_FILE

# Разметка и подключение USB
if [ ! -f "/root/mount_usb.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/mount_usb.sh >> $LOG_FILE 2>&1 && chmod +x mount_usb.sh
fi

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
echo "2. Подготовка пост-перезагрузки..." | tee -a $LOG_FILE

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
echo "3. Настройка автозапуска..." | tee -a $LOG_FILE

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
    
    echo "Добавлено в автозагрузку" | tee -a $LOG_FILE
else
    echo "Уже в автозагрузке" | tee -a $LOG_FILE
fi
if [ "$TUN" = "y" ] || [ "$TUN" = "Y" ]; then
    echo "Настройка автозапуска настройки Outline VPN" | tee -a $LOG_FILE
    # Проверяем, не добавлен ли уже наш скрипт
    if ! grep -q "outline_vpn.sh" /etc/rc.local; then
        # Добавляем вызов в конец (но перед exit если есть)
        if grep -q "^exit" /etc/rc.local; then
            # Вставляем перед exit
            sed -i '/^exit/i # Auto-generated post-boot script (will self-remove)\n/root/outline_vpn.sh &' /etc/rc.local
        else
            # Добавляем в конец
            echo '' >> /etc/rc.local
            echo '# Auto-generated post-boot script (will self-remove)' >> /etc/rc.local
            echo '/root/outline_vpn.sh' >> /etc/rc.local
        fi
        
        echo "Добавлено в автозагрузку" | tee -a $LOG_FILE
    else
        echo "Уже в автозагрузке" | tee -a $LOG_FILE
    fi
fi

# Показываем итог
echo "Итоговый rc.local:" | tee -a $LOG_FILE
cat /etc/rc.local | tee -a $LOG_FILE

# --------------------------------------------------
# ШАГ 4: Настройка USB
# --------------------------------------------------
echo "4. Настройка USB" | tee -a $LOG_FILE
/root/mount_usb.sh

# --------------------------------------------------
# ШАГ 5: Перезагрузка
# --------------------------------------------------
echo "5. Подготовка к перезагрузке..." | tee -a $LOG_FILE
echo "Все настройки сохранены." | tee -a $LOG_FILE
echo "После перезагрузки скрипт выполнится автоматически." | tee -a $LOG_FILE
echo "Лог будет в /root/postboot.log" | tee -a $LOG_FILE

# Удаляем сам скрипт
rm -f /root/setup.sh
echo "Скрипт удален" | tee -a $LOG_FILE

# Перезагрузка
    if [ -t 0 ]; then
        read -p "Перезагрузить сейчас? [y/N]: " REBOOT_NOW
        if [ "$REBOOT_NOW" = "y" ] || [ "$REBOOT_NOW" = "Y" ]; then
            echo "Перезагружаюсь..." | tee -a $LOG_FILE
            sleep 3
            reboot
        else
            echo "Перезагрузка отложена. Рекомендуется перезагрузить систему вручную." | tee -a $LOG_FILE
        fi
    else
        echo "=== Начинаю перезагрузку ===" | tee -a $LOG_FILE
        sync
        reboot
    fi
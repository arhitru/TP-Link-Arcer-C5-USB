#!/bin/sh
# Основной скрипт установки/настройки OpenWRT
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$0")
LOG_DIR="/root"
LOG_FILE="${LOG_DIR}/setup.log"
PID_FILE="/var/run/${SCRIPT_NAME}.pid"
LOCK_FILE="/var/lock/${SCRIPT_NAME}.lock"
RETRY_COUNT=5

if [ ! -f "/root/logging_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/logging_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/logging_functions.sh
fi
. /root/logging_functions.sh
init_logging

log_info "=== Начало установки: $(date) ==="

# Проверяем что система загрузилась
log_info "Проверка системы:"
uptime >> $LOG_FILE 2>&1
ifconfig >> $LOG_FILE 2>&1

# Ждем запуска сети
log_info "Ожидание сети..."
for i in $(seq 1 30); do
    if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        log_success "Сеть доступна"
        break
    fi
    sleep 1
done

if [ -t 0 ]; then
    # Если скрипт запущен из консоли, то спрашиваем пользователя
    log_warn "Do you have the Outline key? [y/N]: "
    read -p "Do you have the Outline key? [y/N]: " OUTLINE
    if [ "$OUTLINE" = "y" ] || [ "$OUTLINE" = "Y" ]; then
        log_warn "Do you want to set up an Outline VPN? [y/N]: "
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
log_info "1. Настройка системы..."

# Разметка и подключение USB
if [ ! -f "/root/mount_usb.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/mount_usb.sh >> $LOG_FILE 2>&1 && chmod +x mount_usb.sh
    . /root/mount_usb.sh
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
    log_info "Настройка автозапуска настройки Outline VPN"
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
        
        log_info "Добавлено в автозагрузку"
    else
        log_info "Уже в автозагрузке"
    fi
fi

# Показываем итог
log_info "Итоговый rc.local:"
cat /etc/rc.local | tee -a $LOG_FILE

# --------------------------------------------------
# ШАГ 4: Настройка USB
# --------------------------------------------------
log_info "4. Настройка USB"
main_mount_usb
#/root/mount_usb.sh

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
        log_warn "Перезагрузить сейчас? [y/N]: "
        read -p "Перезагрузить сейчас? [y/N]: " REBOOT_NOW
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
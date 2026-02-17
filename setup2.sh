#!/bin/sh
# Основной скрипт установки/настройки OpenWRT
DISK="/dev/sda"
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

# Инициализируем логирование
init_logging

# Настраиваем Outline
if [ -t 0 ]; then
    log_question "Do you have the Outline key? [y/N]: "
    read OUTLINE
    if [ "$OUTLINE" = "y" ] || [ "$OUTLINE" = "Y" ]; then
        log_question "Do you want to set up an Outline VPN? [y/N]: "
        read TUN
        if [ "$TUN" = "y" ] || [ "$TUN" = "Y" ]; then
            if [ ! -f "/root/install_outline_settings2.sh" ]; then
                cd /root && wget https://raw.githubusercontent.com/arhitru/install_outline/refs/heads/main/install_outline_settings.sh >> $LOG_FILE 2>&1 && chmod +x /root/install_outline_settings.sh
            fi
            . /root/install_outline_settings.sh
            install_outline_settings
        fi
    fi
fi

# --------------------------------------------------
# ШАГ 1: Предварительные настройки
# --------------------------------------------------
log_info "1. Настройка системы..."

# Разметка и подключение USB
if [ ! -f "/root/mount_usb.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/mount_usb_function.sh >> $LOG_FILE 2>&1 && chmod +x mount_usb_function.sh
fi
. /root/mount_usb_function.sh

# Установка недостающих пакетов
if [ ! -f "/root/setup_required.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required2.sh >> $LOG_FILE 2>&1 && chmod +x setup_required2.sh
fi
if [ ! -f "/root/setup_required.conf" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required.conf >> $LOG_FILE 2>&1
fi

# --------------------------------------------------
# ШАГ 2: Настройка автозапуска
# --------------------------------------------------
log_info "2. Настройка автозапуска..."

# Создаем или обновляем rc.local
if [ ! -f /etc/rc.local ]; then
    echo '#!/bin/sh' > /etc/rc.local
    echo '' >> /etc/rc.local
fi

# Проверяем, не добавлен ли уже наш скрипт
if ! grep -q "setup_required2.sh" /etc/rc.local; then
    # Добавляем вызов в конец (но перед exit если есть)
    if grep -q "^exit" /etc/rc.local; then
        # Вставляем перед exit
        sed -i '/^exit/i # Auto-generated post-boot script (will self-remove)\n/root/setup_required2.sh &' /etc/rc.local
    else
        # Добавляем в конец
        echo '' >> /etc/rc.local
        echo '# Auto-generated post-boot script (will self-remove)' >> /etc/rc.local
        echo '/root/setup_required2.sh' >> /etc/rc.local
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
# ШАГ 3: Настройка USB
# --------------------------------------------------
log_info "3. Настройка USB"
mount_usb_main

# --------------------------------------------------
# ШАГ 4: Перезагрузка
# --------------------------------------------------
log_info "4. Подготовка к перезагрузке..."
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
            reboot
        else
            log_warn "Перезагрузка отложена. Рекомендуется перезагрузить систему вручную."
        fi
    else
        log_info "=== Начинаю перезагрузку ==="
        sync
        reboot
    fi
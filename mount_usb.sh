#!/bin/sh
# ============================================================================
# Основные переменные
# ============================================================================
DISK="/dev/sda"
SCRIPT_NAME=$(basename "$0")
LOG_DIR="/root"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
DEBUG=0
AUTO_MODE=0

# Определяем режим выполнения (интерактивный или автоматический)
if [ ! -t 0 ]; then
    AUTO_MODE=1
fi

# ============================================================================
# Импорт функций логирования
# ============================================================================
if [ ! -f "/root/logging_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/logging_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/logging_functions.sh
fi
. /root/logging_functions.sh

# Инициализируем логирование
init_logging

#  Импорт функций настройки USB
if [ ! -f "/root/mount_usb_function.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/mount_usb_function.sh >> $LOG_FILE 2>&1 && chmod +x mount_usb_function.sh
fi
. /root/mount_usb_function.sh

# Инициализируем настройки USB
mount_usb_main

# Автоматическая перезагрузка всегда при изменении разметки
if [ "$EXISTING_PARTS" -eq 0 ] || [ "$CHECK_RESULT" = "false" ]; then
    if [ $AUTO_MODE -eq 0 ] && [ -t 0 ]; then
        log_info "Для применения изменений требуется перезагрузка."
        log_question "Перезагрузить сейчас? [y/N]: "
        read REBOOT_NOW
        if [ "$REBOOT_NOW" = "y" ] || [ "$REBOOT_NOW" = "Y" ]; then
            log_info "Перезагружаюсь..."
            reboot
        else
            log_info "Перезагрузка отменена пользователем."
        fi
    else
        log_info "Перезагружаюсь..."
        sleep 3
        reboot
    fi
else
    log_info "Изменения применены без переразметки."
    log_info "Для полного применения изменений в extroot может потребоваться перезагрузка."
    if [ $AUTO_MODE -eq 0 ] && [ -t 0 ]; then
        log_question "Перезагрузить сейчас? [y/N]: "
        read REBOOT_NOW
        if [ "$REBOOT_NOW" = "y" ] || [ "$REBOOT_NOW" = "Y" ]; then
            log_info "Перезагружаюсь..."
            reboot
        else
            log_info "Перезагрузка отменена пользователем."
        fi
    else
        log_info "Перезагружаюсь..."
        sleep 3
        reboot
    fi
fi

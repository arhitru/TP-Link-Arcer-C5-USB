#!/bin/sh
# Этот скрипт выполнится один раз после перезагрузки
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$0")
LOG_DIR="/root"
LOG_FILE="${LOG_DIR}/postboot.log"
PID_FILE="/var/run/${SCRIPT_NAME}.pid"
LOCK_FILE="/var/lock/${SCRIPT_NAME}.lock"
RETRY_COUNT=5

if [ ! -f "/root/logging_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/logging_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/logging_functions.sh
fi
. /root/logging_functions.sh
init_logging

log_info "=== Post-boot начат: $(date) ==="

# Ждем полной загрузки
log_info "Ожидание полной загрузки..."
sleep 150

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

# ФИНАЛЬНЫЕ НАСТРОЙКИ:
log_info "Выполняю финальные настройки..."

if [ ! -f "/root/setup_required.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required.sh >> $LOG_FILE 2>&1 && chmod +x setup_required.sh
fi

log_info "Запускаю setup_required.sh"
/root/setup_required.sh

if [ -f "/root/install_outline_for_getdomains.sh" ]; then
    log_info "Запускаю outline_vpn.sh"
    /root/install_outline_for_getdomains.sh
fi

# --------------------------------------------------
# ОЧИСТКА: делаем запуск однократным
# --------------------------------------------------
log_info "Очистка..."

# 1. Удаляем вызов из rc.local
if [ -f /etc/rc.local ]; then
    # Создаем чистую версию без нашего вызова
    grep -v "postboot.sh" /etc/rc.local > /root/rc.local.new
    if [ $? -eq 0 ]; then
        mv /root/rc.local.new /etc/rc.local
        chmod +x /etc/rc.local
        echo "Удалено из rc.local"
    fi
fi

# 2. Удаляем сам скрипт
rm -f /root/postboot.sh
rm -f /root/*.sh
log_info "Скрипт удален"

# 3. Создаем флаг завершения
log_info "COMPLETED_AT_$(date +%s)" > /root/.postboot_done

log_info "=== Post-boot завершен: $(date) ==="

# Перезагрузка
    if [ -t 0 ]; then
        log_question "Перезагрузить сейчас? [y/N]:"
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
exit 0
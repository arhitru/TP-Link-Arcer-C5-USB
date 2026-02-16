#!/bin/sh
# Этот скрипт выполнится один раз после перезагрузки
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$0")
LOG_DIR="/root"
LOG_FILE="${LOG_DIR}/postboot.log"
PID_FILE="/var/run/${SCRIPT_NAME}.pid"
LOCK_FILE="/var/lock/${SCRIPT_NAME}.lock"
RETRY_COUNT=5

CONFIG_FILE="${SCRIPT_DIR}/outline.conf"
LOG="/root/postboot.log"
echo "=== Post-boot начат: $(date) ===" > $LOG_FILE

# Ждем полной загрузки
sleep 60

# Проверяем что система загрузилась
echo "Проверка системы:" >> $LOG_FILE
uptime >> $LOG_FILE 2>&1
ifconfig >> $LOG_FILE 2>&1

# Ждем запуска сети
echo "Ожидание сети..."
for i in $(seq 1 30); do
    if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        echo "Сеть доступна"  >> $LOG_FILE
        break
    fi
    sleep 1
done

# ФИНАЛЬНЫЕ НАСТРОЙКИ:
echo "Выполняю финальные настройки..." >> $LOG_FILE

if [ ! -f "/root/setup_required.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required.sh >> $LOG_FILE 2>&1 && chmod +x setup_required.sh
fi

echo "Запускаю setup_required.sh" >> $LOG_FILE
/root/setup_required.sh

# --------------------------------------------------
# ОЧИСТКА: делаем запуск однократным
# --------------------------------------------------
echo "Очистка..." >> $LOG_FILE

# 1. Удаляем вызов из rc.local
if [ -f /etc/rc.local ]; then
    # Создаем чистую версию без нашего вызова
    grep -v "postboot.sh" /etc/rc.local > /root/rc.local.new
    if [ $? -eq 0 ]; then
        mv /root/rc.local.new /etc/rc.local
        chmod +x /etc/rc.local
        echo "Удалено из rc.local" >> $LOG_FILE
    fi
fi

# 2. Удаляем сам скрипт
rm -f /root/postboot.sh
echo "Скрипт удален" >> $LOG_FILE

# 3. Создаем флаг завершения
echo "COMPLETED_AT_$(date +%s)" > /root/.postboot_done

echo "=== Post-boot завершен: $(date) ===" >> $LOG_FILE
exit 0
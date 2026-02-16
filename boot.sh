#!/bin/sh

LOG="/root/boot.log"
test_hosts="openwrt.org google.com cloudflare.com"
echo "=== Начало установки: $(date) ===" > $LOG

echo "Проверка системы:" >> $LOG
uptime >> $LOG 2>&1
ifconfig >> $LOG 2>&1

echo "Ожидание сети..." >> $LOG
for i in $(seq 1 120); do
    if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        echo "Сеть доступна"  
        for host in $test_hosts; do
            if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
                echo "Подключение к $host успешно" >> $LOG
                break 2
            fi
        done
    fi
    sleep 1
done

echo "Loading..." >> $LOG
cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup.sh >> $LOG 2>&1 && chmod +x setup.sh && ./setup.sh
#  sh <(wget -O - https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup.sh)

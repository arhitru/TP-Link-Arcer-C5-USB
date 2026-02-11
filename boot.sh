LOG="/root/install.log"
echo "=== Начало установки: $(date) ===" > $LOG

echo "Проверка системы:" >> $LOG
uptime >> $LOG 2>&1
ifconfig >> $LOG 2>&1

echo "Ожидание сети..." >> $LOG
for i in $(seq 1 120); do
    if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        echo "Сеть доступна"  >> $LOG
        break
    fi
    sleep 1
done
cd /tmp && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup.sh && chmod +x setup.sh && ./setup.sh
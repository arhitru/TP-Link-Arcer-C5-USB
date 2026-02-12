#!/bin/sh
# Основной скрипт установки/настройки OpenWRT

LOG="/root/setup.log"
echo "=== Начало установки: $(date) ===" > $LOG

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

# --------------------------------------------------
# ШАГ 1: Предварительные настройки
# --------------------------------------------------
echo "1. Настройка системы..." | tee -a $LOG

# Разметка и подключение USB
cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/mount_usb.sh >> $LOG 2>&1 && chmod +x mount_usb.sh

# Установка недостающих пакетов
cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/postboot.sh >> $LOG 2>&1 && chmod +x postboot.sh
cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup_required.sh >> $LOG 2>&1 && chmod +x setup_required.sh

/root/mount_usb.sh

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
        sed -i '/^exit/i # Auto-generated post-boot script (will self-remove)\n/root/postboot.sh &' /etc/rc.local
    else
        # Добавляем в конец
        echo '' >> /etc/rc.local
        echo '# Auto-generated post-boot script (will self-remove)' >> /etc/rc.local
        echo '/root/postboot.sh &' >> /etc/rc.local
    fi
    
    echo "Добавлено в автозагрузку" | tee -a $LOG
else
    echo "Уже в автозагрузке" | tee -a $LOG
fi

# Показываем итог
echo "Итоговый rc.local:" | tee -a $LOG
cat /etc/rc.local | tee -a $LOG

# --------------------------------------------------
# ШАГ 4: Перезагрузка
# --------------------------------------------------
echo "4. Подготовка к перезагрузке..." | tee -a $LOG
echo "Все настройки сохранены." | tee -a $LOG
echo "После перезагрузки скрипт выполнится автоматически." | tee -a $LOG
echo "Лог будет в /root/postboot.log" | tee -a $LOG

# Пауза для проверки
echo "Перезагрузка через 5 секунд..." | tee -a $LOG
sleep 5

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
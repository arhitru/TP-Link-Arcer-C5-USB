#!/bin/sh
## **Сохранение списков программных пакетов при загрузке**
# Сохранение статуса установленных пакетов opkg в /usr/lib/opkg/lists хранящемся в extroot, а не в RAM, экономит некоторую оперативную память и сохраняет списки пакетов доступными после перезагрузки.

sed -i -r -e "s/^(lists_dir\sext\s).*/\1\/usr\/lib\/opkg\/lists/" /etc/opkg.conf
opkg update

# Check for kmod-leds-gpio
# Проверяет наличие kmod-leds-gpio
opkg list-installed | grep kmod-leds-gpio > /dev/null
if [ $? -ne 0 ]; then
    echo "kmod-leds-gpio is not installed."
    opkg install kmod-leds-gpio
    echo 'kmod-leds-gpio installed'
fi

# Check for odhcp6c
# Проверяет наличие odhcp6c
opkg list-installed | grep odhcp6c > /dev/null
if [ $? -ne 0 ]; then
    echo "odhcp6c is not installed."
    opkg install odhcp6c
    echo 'odhcp6c installed'
fi

# Check for odhcpd-ipv6only
# Проверяет наличие odhcpd-ipv6only
opkg list-installed | grep odhcpd-ipv6only > /dev/null
if [ $? -ne 0 ]; then
    echo "odhcpd-ipv6only is not installed."
    opkg install odhcpd-ipv6only
    echo 'odhcpd-ipv6only installed'
fi

# Check for ppp
# Проверяет наличие ppp
opkg list-installed | grep ppp > /dev/null
if [ $? -ne 0 ]; then
    echo "ppp is not installed."
    opkg install ppp
    echo 'ppp installed'
fi

# Check for ppp-mod-pppoe
# Проверяет наличие ppp-mod-pppoe
opkg list-installed | grep ppp-mod-pppoe > /dev/null
if [ $? -ne 0 ]; then
    echo "ppp-mod-pppoe is not installed."
    opkg install ppp-mod-pppoe
    echo 'ppp-mod-pppoe installed'
fi

# Check for kmod-usb-ledtrig-usbport
# Проверяет наличие kmod-usb-ledtrig-usbport
opkg list-installed | grep kmod-usb-ledtrig-usbport > /dev/null
if [ $? -ne 0 ]; then
    echo "kmod-usb-ledtrig-usbport is not installed."
    opkg install kmod-usb-ledtrig-usbport
    echo 'kmod-usb-ledtrig-usbport installed'
fi

# Установим пакет dnsmasq-full. По дефолту в OpenWrt идёт урезанный dnsmasq для экономии места.
cd /tmp/ && opkg download dnsmasq-full
opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/
mv /etc/config/dhcp-opkg /etc/config/dhcp
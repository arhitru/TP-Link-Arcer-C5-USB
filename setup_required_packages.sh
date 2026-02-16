#!/bin/sh
SCRIPT_NAME=$(basename "$0")
SCRIPT_DIR=$(dirname "$0")
LOG_DIR="/root"
LOG_FILE="${LOG_DIR}/setup.log"
PID_FILE="/var/run/${SCRIPT_NAME}.pid"
LOCK_FILE="/var/lock/${SCRIPT_NAME}.lock"
RETRY_COUNT=5

CONFIG_FILE="${SCRIPT_DIR}/setup_required.conf"
LOG="/root/setup.log"

if [ ! -f "/root/logging_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/logging_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/logging_functions.sh
fi
if [ ! -f "/root/opkg_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/opkg_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/opkg_functions.sh
fi
if [ ! -f "/root/system_verification_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/system_verification_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/system_verification_functions.sh
fi
if [ ! -f "/root/execution_management_functions.sh" ]; then
    cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/execution_management_functions.sh >> $LOG_FILE 2>&1 && chmod +x /root/execution_management_functions.sh
fi
. /root/logging_functions.sh
. /root/opkg_functions.sh
. /root/system_verification_functions.sh
. /root/execution_management_functions.sh
init_logging


# System Details
MODEL=$(cat /tmp/sysinfo/model)
source /etc/os-release
printf "\033[34;1mModel: $MODEL\033[0m\n"
printf "\033[34;1mVersion: $OPENWRT_RELEASE\033[0m\n"

if [ -f /etc/os-release ]; then
    VERSION=$(grep 'VERSION=' /etc/os-release | cut -d'"' -f2)
    VERSION_ID=$(echo $VERSION | awk -F. '{print $1}')
else
    VERSION_ID=0  # Значение по умолчанию для старых версий
fi
export VERSION_ID=$VERSION_ID

printf "\033[31;1mAll actions performed here cannot be rolled back automatically.\033[0m\n"

read -p "Install MESH package? [y/N]: " MESH
if [ -t 0 ]; then
    read -p "Do you have the Outline key? [y/N]: " OUTLINE
    if [ "$OUTLINE" = "y" ] || [ "$OUTLINE" = "Y" ]; then
        read -p "Do you want to set up an Outline VPN? [y/N]: " TUN
        if [ "$TUN" = "y" ] || [ "$TUN" = "Y" ]; then
            if [ ! -f "/root/install_outline_settings.sh" ]; then
                cd /root && wget https://raw.githubusercontent.com/arhitru/fuctions_bash/refs/heads/main/install_outline_settings.sh >> $LOG_FILE 2>&1 && chmod +x /root/install_outline_settings.sh
            fi
            . /root/install_outline_settings.sh
            install_outline_settings
        fi
    fi
fi

## **Сохранение списков программных пакетов при загрузке**
# Сохранение статуса установленных пакетов opkg в /usr/lib/opkg/lists хранящемся в extroot, а не в RAM, экономит некоторую оперативную память и сохраняет списки пакетов доступными после перезагрузки.
sed -i -r -e "s/^(lists_dir\sext\s).*/\1\/usr\/lib\/opkg\/lists/" /etc/opkg.conf
printf "\033[32;1mChecking OpenWrt repo availability...\033[0m\n"
opkg update | grep -q "Failed to download" && printf "\033[32;1mopkg failed. Check internet or date. Command for force ntp sync: ntpd -p ptbtime1.ptb.de\033[0m\n" && exit 1

# Check for kmod-leds-gpio
# Проверяет наличие kmod-leds-gpio
if opkg list-installed | grep -q kmod-leds-gpio; then
    printf "\033[32;1mkmod-leds-gpio already installed\033[0m\n"
else
    echo "Installed kmod-leds-gpio"
    opkg install kmod-leds-gpio
fi

# Check for odhcp6c
# Проверяет наличие odhcp6c
if opkg list-installed | grep -q odhcp6c; then
    printf "\033[32;1modhcp6c already installed\033[0m\n"
else
    echo "Installed odhcp6c"
    opkg install odhcp6c
fi

# Check for odhcpd-ipv6only
# Проверяет наличие odhcpd-ipv6only
if opkg list-installed | grep -q odhcpd-ipv6only; then
    printf "\033[32;1modhcpd-ipv6only already installed\033[0m\n"
else
    echo "Installed odhcpd-ipv6only"
    opkg install odhcpd-ipv6only
fi

# Check for ppp
# Проверяет наличие ppp
if opkg list-installed | grep -q ppp; then
    printf "\033[32;1mppp already installed\033[0m\n"
else
    echo "Installed ppp"
    opkg install ppp
fi

# Check for ppp-mod-pppoe
# Проверяет наличие ppp-mod-pppoe
if opkg list-installed | grep -q ppp-mod-pppoe; then
    printf "\033[32;1mppp-mod-pppoe already installed\033[0m\n"
else
    echo "Installed ppp-mod-pppoe"
    opkg install ppp-mod-pppoe
fi

# Check for kmod-usb-ledtrig-usbport
# Проверяет наличие kmod-usb-ledtrig-usbport
if opkg list-installed | grep -q kmod-usb-ledtrig-usbport; then
    printf "\033[32;1mkmod-usb-ledtrig-usbportc already installed\033[0m\n"
else
    echo "Installed kmod-usb-ledtrig-usbport"
    opkg install kmod-usb-ledtrig-usbport
fi

# Установим пакет dnsmasq-full. По дефолту в OpenWrt идёт урезанный dnsmasq для экономии места.
if opkg list-installed | grep -q dnsmasq-full; then
    printf "\033[32;1mdnsmasq-full already installed\033[0m\n"
else
    echo "Installed dnsmasq-full"
    cd /tmp/ && opkg download dnsmasq-full
    opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/
    mv /etc/config/dhcp-opkg /etc/config/dhcp
fi

# Установим пакет для создания Mesh-сети.
if [ "$MESH" = "y" ] || [ "$MESH" = "Y" ]; then
    if opkg list-installed | grep -q wpad-mesh-openssl; then
        printf "\033[32;1mwpad-mesh-openssl already installed\033[0m\n"
    else
        cd /tmp/ && opkg download wpad-mesh-openssl
        if opkg list-installed | grep -q wpad-basic-mbedtls; then
            opkg remove wpad-basic-mbedtls
        fi
        opkg install wpad-mesh-openssl --cache /tmp/
    fi
fi

# Настройка IPTV
if ! uci show firewall | grep -q "\.name='Allow-IGMP'"; then
    echo "Adding firewall rule for IGMP..."
    uci add firewall rule
    uci set firewall.@rule[-1]=rule
    uci set firewall.@rule[-1].name='Allow-IGMP'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].proto='igmp'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
else
    printf "\033[32;1mRule 'Allow-IGMP' already exists, skipping...\033[0m\n"
fi
if ! uci show firewall | grep -q "\.name='Allow-IPTV-IGMPPROXY'"; then
    echo "Adding firewall rule for IGMPPROXY..."
    uci add firewall rule
    uci set firewall.@rule[-1]=rule
    uci set firewall.@rule[-1].name='Allow-IPTV-IGMPPROXY'
    uci set firewall.@rule[-1].src='wan'
    uci set firewall.@rule[-1].dest='lan'
    uci set firewall.@rule[-1].dest_ip='224.0.0.0/4'
    uci set firewall.@rule[-1].proto='udp'
    uci set firewall.@rule[-1].target='ACCEPT'
    uci commit firewall
else
    printf "\033[32;1mRule 'Allow-IPTV-IGMPPROXY' already exists, skipping...\033[0m\n"
fi
if opkg list-installed | grep -q igmpproxy; then
    printf "\033[32;1migmpproxy already installed\033[0m\n"
else
    echo "Installed igmpproxy"
    opkg install igmpproxy
fi

# Tunnel
if [ "$TUN" = "y" ] || [ "$TUN" = "Y" ]; then
    cd /tmp
    wget https://raw.githubusercontent.com/arhitru/install_outline/refs/heads/main/getdomains-install-outline.sh -O getdomains-install-outline.sh
    chmod +x getdomains-install-outline.sh
    ./getdomains-install-outline.sh
fi

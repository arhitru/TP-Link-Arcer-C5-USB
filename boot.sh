#!/bin/sh

sleep 150

cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup.sh >> $LOG 2>&1 && chmod +x setup.sh && ./setup.sh

# base-files dnsmasq dropbear fstools libc libgcc mtd netifd opkg procd-ujail uci uclient-fetch kmod-usb2 kmod-switch-rtl8367b block-mount kmod-fs-ext4 e2fsprogs parted kmod-usb-storage
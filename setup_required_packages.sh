#!/bin/sh

opkg update
opkg install kmod-leds-gpio kmod odhcp6c odhcpd-ipv6only ppp ppp-mod-pppoe kmod-usb-ledtrig-usbport 
cd /tmp/ && opkg download dnsmasq-full
opkg remove dnsmasq && opkg install dnsmasq-full --cache /tmp/
mv /etc/config/dhcp-opkg /etc/config/dhcp

opkg install curl
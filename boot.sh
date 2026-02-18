#!/bin/sh

sleep 150

cd /root && wget https://raw.githubusercontent.com/arhitru/TP-Link-Arcer-C5-USB/main/setup.sh >> $LOG 2>&1 && chmod +x setup.sh && ./setup.sh

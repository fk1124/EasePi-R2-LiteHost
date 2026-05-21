#!/bin/bash
set -e

TTY_DEV="${TTY_DEV:-/dev/ttyS9}"
BT_SPEED="${BT_SPEED:-1500000}"

rfkill unblock bluetooth 2>/dev/null || true

if find /sys/firmware/devicetree/base -maxdepth 3 -type d -name bluetooth -path '*/serial@*/*' 2>/dev/null | grep -q .; then
    echo "Bluetooth controller is described by device-tree serdev; let kernel manage ${TTY_DEV}."
    exit 0
fi

if [ -d /sys/class/bluetooth/hci0 ]; then
    echo "Bluetooth HCI already present; kernel serdev owns ${TTY_DEV}."
    exit 0
fi

modprobe hci_uart 2>/dev/null || true
modprobe hci_uart_bcm 2>/dev/null || true
modprobe btqca 2>/dev/null || true

if [ ! -e "${TTY_DEV}" ]; then
    echo "Bluetooth UART not found: ${TTY_DEV}"
    exit 0
fi

if command -v btattach >/dev/null 2>&1; then
    exec /usr/bin/btattach -B "${TTY_DEV}" -P bcm -S "${BT_SPEED}" -N
fi

if command -v hciattach >/dev/null 2>&1; then
    exec /usr/bin/hciattach "${TTY_DEV}" bcm43xx "${BT_SPEED}" flow - "${BT_SPEED}"
fi

echo "Neither btattach nor hciattach was found. Please install bluez."
exit 0

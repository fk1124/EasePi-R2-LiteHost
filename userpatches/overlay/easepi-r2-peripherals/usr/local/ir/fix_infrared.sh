#!/bin/bash
set -e

modprobe gpio_ir_recv 2>/dev/null || true
modprobe rc_core 2>/dev/null || true

if command -v ir-keytable >/dev/null 2>&1 && [ -f /etc/rc_keymaps/easepi_remote ]; then
    ir-keytable -w /etc/rc_keymaps/easepi_remote || true
fi

#!/bin/bash
# EasePi-R2 image customization entry point.
#
# This build kit keeps board-specific customization in Armbian extensions.
# Currently used extension:
#   - easepi-r2-peripherals.sh  IR + AP6255 Bluetooth support
#
# Keep this file minimal so the base image remains clean and reproducible.

Main() {
    echo "EasePi-R2: image customization is handled by extensions."
}

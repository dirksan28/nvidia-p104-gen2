#!/bin/bash
# Restore the stock NVIDIA source tree and rebuild the unpatched module.
set -euo pipefail

SRC=/usr/src/nvidia-srv-580.178.04
VER=580.178.04
KREL=$(uname -r)

echo "== restoring backups =="
restore() {
    local rel=$1
    if [ -f "$SRC/$rel.bak" ]; then
        sudo cp -a "$SRC/$rel.bak" "$SRC/$rel"
        echo "  restored $rel"
    elif [ -f "/root/p104-backup/$(basename "$rel")" ]; then
        sudo cp -a "/root/p104-backup/$(basename "$rel")" "$SRC/$rel"
        echo "  restored $rel from /root/p104-backup"
    else
        echo "  MISSING backup for $rel" >&2
        return 1
    fi
}
restore nvidia/nv-pci.c
restore nvidia/nv.c
restore common/inc/nv-pci.h

echo "== rebuild =="
sudo dkms build   -m nvidia-srv -v "$VER" -k "$KREL" --force
sudo dkms install -m nvidia-srv -v "$VER" -k "$KREL" --force
sudo update-initramfs -u -k "$KREL"

echo "== reload =="
sudo systemctl stop nvidia-persistenced
sudo modprobe -r nvidia_uvm nvidia_drm nvidia_modeset nvidia || true
sudo modprobe nvidia
sudo systemctl start nvidia-persistenced

sleep 3
sudo lspci -s 01:00.0 -vv | grep -E 'LnkCap:|LnkSta:'
echo "rollback complete (expect 2.5GT/s for both)"

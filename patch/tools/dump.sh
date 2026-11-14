#!/bin/bash
# Read-only baseline capture.
set -u
OUT=${1:-/tmp/p104-gen2/state-$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"

{
  date -u
  uname -a
  echo
  dkms status
  echo
  lsmod | grep -E '^nvidia'
  echo
  systemctl is-active nvidia-persistenced
} > "$OUT/system.txt" 2>&1

nvidia-smi --query-gpu=name,pci.bus_id,pcie.link.gen.current,pcie.link.gen.max,\
pcie.link.width.current,pcie.link.width.max,persistence_mode \
  --format=csv > "$OUT/nvidia-smi.csv" 2>&1

for d in 01:00.0 00:01.0; do
  sudo -n lspci -s "$d" -vv > "$OUT/lspci-${d//:/_}.txt" 2>&1
done

for d in 0000:01:00.0 0000:00:01.0; do
  for f in current_link_speed current_link_width max_link_speed max_link_width; do
    printf '%-22s %s\n' "$f" "$(cat /sys/bus/pci/devices/$d/$f 2>&1)"
  done > "$OUT/sysfs-${d//:/_}.txt"
done

sudo -n dmesg | tail -40 > "$OUT/dmesg-tail.txt"

echo "baseline written to $OUT"
grep -H . "$OUT"/lspci-*.txt | grep -E 'LnkCap:|LnkSta:' || true

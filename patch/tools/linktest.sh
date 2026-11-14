#!/bin/bash
# Config-space-only control: request 5.0 GT/s and retrain.
#   linktest.sh           set TLS=5.0GT/s on GPU+root port, retrain, sample LNKSTA
#   linktest.sh restore   put TLS back to "auto" (0) on both, retrain
#   linktest.sh status    read-only
set -u
GPU=01:00.0
RP=00:01.0

rd()  { setpci -s "$1" "CAP_EXP+${2}.w"; }

set_tls() { # bdf value
  local cur new
  cur=$(rd "$1" 30) || return 1
  new=$(printf '%04x' $(( (0x$cur & ~0x000f) | ($2 & 0x000f) )))
  echo "  $1 LNKCTL2 0x$cur -> 0x$new"
  setpci -s "$1" "CAP_EXP+30.w=$new"
}

retrain() { # bdf
  local cur new
  cur=$(rd "$1" 10) || return 1
  new=$(printf '%04x' $(( 0x$cur | 0x0020 )))
  echo "  $1 LNKCTL 0x$cur -> 0x$new (RL)"
  setpci -s "$1" "CAP_EXP+10.w=$new"
}

status() {
  for d in "$GPU" "$RP"; do
    printf '%s  LNKCTL2=0x%s  LNKCTL=0x%s  LNKSTA=0x%s\n' \
      "$d" "$(rd "$d" 30)" "$(rd "$d" 10)" "$(rd "$d" 12)"
    sudo -n lspci -s "$d" -vv | grep -E 'LnkCap:|LnkSta:'
  done
}

case "${1:-apply}" in
  status)
    status
    ;;
  restore)
    echo "restoring TLS to auto:"
    set_tls "$GPU" 0
    set_tls "$RP"  0
    retrain "$RP"
    sleep 0.1
    status
    ;;
  apply)
    echo "== before =="
    status
    echo "== requesting 5.0 GT/s =="
    set_tls "$GPU" 2
    set_tls "$RP"  2
    retrain "$GPU"
    retrain "$RP"
    sleep 0.2
    echo "== after =="
    status
    echo "NOTE: leaving TLS at 5.0GT/s; run '$0 restore' to revert"
    ;;
  *)
    echo "usage: $0 [apply|restore|status]" >&2
    exit 1
    ;;
esac

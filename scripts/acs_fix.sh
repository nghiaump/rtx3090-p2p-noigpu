#!/usr/bin/env bash
# Chan doan + tat ACS tren tat ca bridge (de cho phep P2P qua root port)
# Chay: sudo bash ~/acs_fix.sh
exec > >(tee /tmp/acs_fix.log) 2>&1

echo "==================== NVRM loi gan nhat (sau khi map fail) ===================="
dmesg | grep -iE "nvrm|nvidia|peer|bar1|p2p|fail" | tail -15

echo; echo "==================== BAR1 mem decode (Control: Mem+) ===================="
for g in 0000:17:00.0 0000:65:00.0; do echo -n "$g  "; lspci -vs $g | grep -i "Control:"; done

echo; echo "==================== ACS state TRUOC ===================="
for d in $(lspci -D | awk '{print $1}'); do
  cur=$(setpci -s "$d" ECAP_ACS+0x6.w 2>/dev/null)
  if [ -n "$cur" ]; then
     name=$(lspci -s "$d" | cut -d' ' -f2-)
     echo "$d ACSCtl=$cur  ($name)"
  fi
done

echo; echo "==================== Tat ACS (ECAP_ACS+0x6.w = 0000) ===================="
n=0
for d in $(lspci -D | awk '{print $1}'); do
  cur=$(setpci -s "$d" ECAP_ACS+0x6.w 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" != "0000" ]; then
     setpci -s "$d" ECAP_ACS+0x6.w=0000 && { echo "cleared $d (was $cur)"; n=$((n+1)); }
  fi
done
echo "Da clear ACS tren $n device"

echo; echo "==================== ACS state SAU ===================="
for d in $(lspci -D | awk '{print $1}'); do
  cur=$(setpci -s "$d" ECAP_ACS+0x6.w 2>/dev/null)
  [ -n "$cur" ] && echo "$d ACSCtl=$cur"
done
echo; echo ">>> XONG"

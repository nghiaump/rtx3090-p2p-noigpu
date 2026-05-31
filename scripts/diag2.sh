#!/usr/bin/env bash
# Chay: sudo bash ~/diag2.sh
exec > >(tee /tmp/diag2.log) 2>&1
echo "==================== NVRM loi P2P moi nhat ===================="
dmesg | grep -iE "nvrm|aligned|iommu|p2p|bar1|peer" | tail -20

echo; echo "==================== IOMMU domain cua 2 GPU ===================="
for g in 0000:17:00.0 0000:65:00.0; do
  echo -n "$g  iommu_group="
  basename "$(readlink -f /sys/bus/pci/devices/$g/iommu_group 2>/dev/null)" 2>/dev/null
  cat /sys/bus/pci/devices/$g/iommu_group/type 2>/dev/null | sed 's/^/    type=/'
done

echo; echo "==================== intel_iommu / pt trang thai ===================="
dmesg | grep -iE "DMAR.*enabled|Intel-IOMMU|iommu: |passthrough|identity" | head -8
echo "cmdline:"; cat /proc/cmdline
#!/usr/bin/env bash
# Resume: tat gdm -> cai userspace 570.148.08 -> depmod/initramfs/grub
# Chay: sudo bash ~/install_p2p_570b.sh
exec > >(tee /tmp/install_p2p_570b.log) 2>&1
set -uo pipefail

KREL=6.8.0-124-generic
RUN=/home/nghia/NVIDIA-Linux-x86_64-570.148.08.run

echo "==================== 0) Tat gdm (X server) ===================="
systemctl stop gdm 2>/dev/null || systemctl stop gdm3 2>/dev/null || true
sleep 2
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 2>/dev/null || true
echo "gnome-shell con chay khong:"; pgrep -a gnome-shell || echo "  (da tat)"
echo "Xorg/Xwayland:"; pgrep -a Xorg; pgrep -a Xwayland; echo "  (xong check)"

echo "==================== 1) Cai userspace 570.148.08 ===================="
sh "$RUN" --no-kernel-modules --silent --no-nouveau-check
rc=$?; echo "run installer rc=$rc"
[ $rc -eq 0 ] || { echo "!! VAN FAIL — xem /var/log/nvidia-installer.log"; exit 1; }

echo "==================== 2) blacklist nouveau + depmod + initramfs + modules-load ===================="
printf 'blacklist nouveau\noptions nouveau modeset=0\n' > /etc/modprobe.d/blacklist-nouveau.conf
printf 'nvidia\nnvidia_uvm\n' > /etc/modules-load.d/nvidia-p2p.conf
depmod -a "$KREL"
update-initramfs -u -k "$KREL"
echo "depmod+initramfs done"

echo "==================== 3) Dat GRUB default = 6.8 ===================="
sed -i 's#^GRUB_DEFAULT=.*#GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-124-generic"#' /etc/default/grub
update-grub
echo "grub default -> 6.8"

echo "==================== XONG ===================="
modinfo nvidia 2>/dev/null | grep -E '^version|^filename' | head -2
echo ">>> Neu OK: sudo reboot   (van vao 6.8)"
echo ">>> Sau reboot: nvidia-smi -L && nvidia-smi topo -p2p rw"

#!/usr/bin/env bash
# Cài driver NVIDIA 570.148.08 + patch P2P (tinygrad) trên kernel 6.8
# Chạy: sudo bash ~/install_p2p_570.sh
exec > >(tee /tmp/install_p2p_570.log) 2>&1
set -uo pipefail

KREL=6.8.0-124-generic
FORK=/home/nghia/open-gpu-kernel-modules
RUN=/home/nghia/NVIDIA-Linux-x86_64-570.148.08.run

echo "==================== SANITY ===================="
[ "$(uname -r)" = "$KREL" ] || { echo "!! Khong o $KREL (dang o $(uname -r)). DUNG."; exit 1; }
[ -f "$FORK/kernel-open/nvidia.ko" ] || { echo "!! Thieu module patch da build. DUNG."; exit 1; }
[ -f "$RUN" ] || { echo "!! Thieu file .run userspace. DUNG."; exit 1; }
echo "OK: kernel=$KREL, modules + run installer present"

echo "==================== 1) PURGE apt nvidia 580 ===================="
PKGS=$(dpkg -l 2>/dev/null | awk '/^ii/ && /nvidia/ {print $2}' | tr '\n' ' ')
echo "Purging: $PKGS"
[ -n "$PKGS" ] && apt-get purge -y $PKGS
apt-get autoremove -y
echo "purge done (rc=$?)"

echo "==================== 2) Cai module patch (570.148.08-p2p) ===================="
cd "$FORK" || exit 1
make modules_install -j"$(nproc)"
rc=$?; echo "modules_install rc=$rc"; [ $rc -eq 0 ] || { echo "!! modules_install FAIL. DUNG."; exit 1; }

echo "==================== 3) Cai userspace 570.148.08 (khong kernel module) ===================="
sh "$RUN" --no-kernel-modules --silent --no-nouveau-check
rc=$?; echo "run installer rc=$rc"; [ $rc -eq 0 ] || { echo "!! userspace install FAIL (xem /var/log/nvidia-installer.log). DUNG."; exit 1; }

echo "==================== 4) nouveau blacklist + depmod + initramfs + modules-load ===================="
printf 'blacklist nouveau\noptions nouveau modeset=0\n' > /etc/modprobe.d/blacklist-nouveau.conf
printf 'nvidia\nnvidia_uvm\n' > /etc/modules-load.d/nvidia-p2p.conf
depmod -a "$KREL"
update-initramfs -u -k "$KREL"
echo "depmod+initramfs done"

echo "==================== 5) Dat GRUB default = 6.8 ===================="
sed -i 's#^GRUB_DEFAULT=.*#GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-124-generic"#' /etc/default/grub
update-grub
echo "grub default -> 6.8"

echo "==================== XONG ===================="
echo "Kiem tra version module da cai:"
modinfo nvidia 2>/dev/null | grep -E '^version|^filename' | head -2
echo
echo ">>> Review log o tren. Neu OK thi: sudo reboot"
echo ">>> Sau reboot (van 6.8): nvidia-smi -L  &&  nvidia-smi topo -p2p rw"

# Hướng dẫn bật PCIe P2P cho 2× RTX 3090 trên main X299 (không iGPU/BMC)

> **[English version below](#english-version) — scroll to the bottom of this file for the full English guide.**

Tài liệu này ghi lại **toàn bộ quá trình** bật và **kiểm chứng dữ liệu** P2P (peer-to-peer DMA)
giữa 2 card RTX 3090 trên host `rtx` — ASUS PRIME X299-A II, Intel i9-10900X (Cascade Lake-X,
**không có iGPU**), không có cầu NVLink. Hoàn thành 2026-05-31.

> **Kết quả:** GPU0↔GPU1 ~**10.3 GB/s** mỗi chiều, **roundtrip bit-exact** (đúng từng phần tử).
> P2P BAR1 thật, không phải staging qua RAM hệ thống.

Điểm cốt lõi khiến việc này khó hơn các hướng dẫn 4090 trên mạng: **main không có iGPU/BMC nên
một GPU buộc phải gánh console boot**, làm hỏng patch P2P gốc theo 2 cách (xem phần "Hai fix code"
và "Những điểm dễ làm sai"). Các bộ patch gốc chạy ngon trên server AMD EPYC (có VGA của BMC, GPU
không bao giờ làm console) nên không gặp lỗi này.

---

## 0. TL;DR — cấu hình cuối cùng đang chạy

| Hạng mục | Giá trị |
|---|---|
| Kernel | `6.8.0-124-generic` (GRUB default; **không** dùng ≥6.13) |
| Driver | NVIDIA **570.148.08** open module, **có 2 fix tự viết** |
| Userspace | 570.148.08 từ bản **tesla/datacenter** (`.run --no-kernel-modules`) |
| Kernel cmdline | `intel_iommu=on iommu=pt pci=realloc=on` |
| BIOS | Above 4G Decoding = ON, Resizable BAR = ON |
| Hiển thị | headless (`multi-user.target`, `nvidia-drm modeset=0`) |
| Secure Boot | OFF (để load module tự build, chưa ký) |
| Source patch | tinygrad `570.148.08-p2p` (aikitoria "Simplified p2p mod") + 2 fix iGPU-less |

---

## 1. Bối cảnh / phần cứng

- 2× MSI RTX 3090, mỗi card BAR1 resize được tới 32GB (đủ phủ 24GB VRAM).
- 2 GPU nằm trên **2 PCIe host bridge khác nhau** của CPU: `0000:17:00.0` (qua bridge `16`) và
  `0000:65:00.0` (qua bridge `64`). `nvidia-smi topo -m` = **NODE** (không chung PCIe switch).
- **Không NVLink** (không mua được cầu), nên buộc đi đường **PCIe BAR1 P2P**.
- i9-10900X **không có iGPU**; X299 không có BMC → **GPU0 (slot đầu) buộc làm primary display/console**.

P2P qua 2 host bridge trên Intel đi xuyên IIO của CPU → băng thông ~10 GB/s (thấp hơn nếu 2 GPU
chung 1 PCIe switch), nhưng vẫn là P2P thật và đúng dữ liệu.

---

## 2. Kiến trúc giải pháp — 3 tầng vấn đề

1. **Platform**: cho phép 2 BAR1 = 32GB và đảm bảo cả 2 GPU lên đủ.
2. **Driver**: build & cài được patch P2P trên kernel hợp lệ.
3. **Bo mạch không iGPU**: xử lý việc GPU0 chiếm 24MB đầu BAR1 cho console (2 fix code).

---

## 3. Các bước chi tiết (tái lập từ đầu)

### Bước 1 — BIOS
ASUS PRIME X299-A II → Advanced / PCI Subsystem:
- **Above 4G Decoding = Enabled** (bắt buộc — cần ~64GB MMIO cho 2 BAR 32GB)
- **Re-Size BAR Support = Enabled**

Sau reboot kiểm tra: `nvidia-smi -q -d MEMORY | grep -A1 BAR1` → cả 2 card **32768 MiB**.

### Bước 2 — Kernel cmdline
```bash
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 intel_iommu=on iommu=pt pci=realloc=on"/' /etc/default/grub
sudo update-grub
```
- `iommu=pt`: passthrough — đường patch `_kbusCreateStaticBar1IOMMUMapping` cần IOMMU hiện diện.
  **KHÔNG dùng `intel_iommu=off`** (xem pitfalls).
- `pci=realloc=on`: nếu thiếu, BAR0 16MB của GPU2 không được cấp sau ReBAR → GPU2 biến mất
  (`NVRM: BAR0 is 0M @ 0x0`, probe fail).

### Bước 3 — Cài kernel 6.8 (nếu đang ở kernel ≥6.13)
```bash
sudo apt-get install -y linux-image-6.8.0-124-generic linux-headers-6.8.0-124-generic
sudo update-grub
# đặt GRUB default = 6.8
sudo sed -i 's#^GRUB_DEFAULT=.*#GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-124-generic"#' /etc/default/grub
sudo update-grub && sudo reboot
```
Lý do: driver 570 **không build được trên kernel ≥6.13** (kernel đổi xử lý `$(src)` trong Kbuild →
`os-interface.h: No such file or directory`).

### Bước 4 — Lấy source patch + build module
```bash
cd ~
git clone --branch 570.148.08-p2p https://github.com/tinygrad/open-gpu-kernel-modules
cd open-gpu-kernel-modules
# >>> ÁP 2 FIX (xem patches/p2p-igpuless-fixes.patch) <<<
git apply /home/nghia/data/p2p_guide/patches/p2p-igpuless-fixes.patch
make modules -j"$(nproc)"          # ~1 phút trên 6.8; nếu fail headers => sai kernel
```
> Hoặc dùng thẳng source đã patch trong `source/` của bộ archive này.

### Bước 5 — Cài driver
```bash
# userspace KHỚP version (bản tesla, vì URL GeForce 404)
wget https://us.download.nvidia.com/tesla/570.148.08/NVIDIA-Linux-x86_64-570.148.08.run

# Gỡ driver cũ (vd 580 từ apt) để tránh xung đột version
sudo apt-get purge -y $(dpkg -l | awk '/^ii/ && /nvidia/ {print $2}'); sudo apt-get autoremove -y

# Module patch
cd ~/open-gpu-kernel-modules && sudo make modules_install -j"$(nproc)"

# Userspace — PHẢI tắt gdm trước (xem pitfalls), rồi:
sudo systemctl stop gdm
sudo sh ~/NVIDIA-Linux-x86_64-570.148.08.run --no-kernel-modules --silent --no-nouveau-check

# Hoàn tất
printf 'blacklist nouveau\noptions nouveau modeset=0\n' | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
printf 'nvidia\nnvidia_uvm\n' | sudo tee /etc/modules-load.d/nvidia-p2p.conf
sudo depmod -a 6.8.0-124-generic
sudo update-initramfs -u -k 6.8.0-124-generic
sudo reboot
```

### Bước 6 — (tùy chọn) headless
Không bắt buộc sau khi đã có fix offset, nhưng gọn cho box compute:
```bash
echo 'options nvidia-drm modeset=0 fbdev=0' | sudo tee /etc/modprobe.d/nvidia-headless.conf
sudo systemctl set-default multi-user.target
sudo update-initramfs -u -k 6.8.0-124-generic && sudo reboot
```

### Bước 7 — Kiểm chứng
```bash
nvidia-smi topo -p2p rw       # GPU0/GPU1 phải = OK (trước fix = CNS)
python3 ~/p2p_guide/scripts/p2p_test2.py   # PHẢI: cả 2 chiều "OK ... khop tuyet doi"
python3 ~/p2p_guide/scripts/p2p_test.py    # băng thông + roundtrip True
```

---

## 4. Hai fix code (phần khó nhất — đặc thù bo mạch không iGPU)

Vì không có iGPU/BMC, **GPU0 gánh console boot**, chiếm ~24MB đầu BAR1. Hàm
`kbusEnableStaticBar1Mapping_TU102` đặt vùng map VRAM tĩnh vào BAR1 tại `bar1Offset` (=24MB trên
GPU0, =0 trên GPU2 không màn hình). Điều này phá 2 thứ:

**Fix 1 — Alignment** `src/nvidia/src/kernel/gpu/bus/arch/hopper/kern_bus_gh100.c`
(hàm `_kbusCreateStaticBar1IOMMUMapping`):
```c
- if (!NV_IS_ALIGNED64(peerDmaAddr, RM_PAGE_SIZE_512M))   // Hopper-only: 512MB page
+ if (!NV_IS_ALIGNED64(peerDmaAddr, RM_PAGE_SIZE_HUGE))   // Ampere thực dùng 2MB page
```
Trước fix: `NVRM: peer DMA address 0x13001800000 is not aligned at 0x20000000` →
`cudaErrorMapBufferObjectFailed`. Ampere không có page 512MB (đó là tính năng Hopper); static
mapping của Ampere dùng `RM_PAGE_SIZE_HUGE` (2MB) — mà 24MB **đã căn 2MB**, nên đổi check sang 2MB.

**Fix 2 — Offset (QUAN TRỌNG: chống sai dữ liệu thầm lặng)**
`src/nvidia/src/kernel/rmapi/nv_gpu_ops.c` (~dòng 4399):
```c
- bar1BusAddr = gpumgrGetGpuPhysFbAddr(pAdjustedMemDesc->pGpu);                 // chỉ BAR1 base
+ bar1BusAddr = gpumgrGetGpuPhysFbAddr(pAdjustedMemDesc->pGpu) +
+               GPU_GET_KERNEL_BUS(pAdjustedMemDesc->pGpu)->bar1[GPU_GFID_PF].staticBar1.startOffset;
```
`gpumgrGetGpuPhysFbAddr` chỉ trả BAR1 base, nhưng vùng VRAM map tĩnh bắt đầu ở `base + 24MB`. Thiếu
`startOffset` → ghi vào GPU có console **lệch đúng 24MB** → **sai dữ liệu im lặng** (chỉ chiều ghi
vào GPU0 sai; chiều kia đúng). Chỉ test bit-exact mới bắt được.

→ Cả 2 fix nằm trong `patches/p2p-igpuless-fixes.patch`.

---

## 5. ⚠️ Những điểm DỄ LÀM SAI (đọc kỹ!)

1. **Tưởng `topo -p2p = OK` / `can_device_access_peer = True` là xong.** SAI. Đó chỉ là driver
   *quảng bá* khả năng P2P. **Bắt buộc test truyền dữ liệu bit-exact 2 chiều.** Suýt nghiệm thu
   nhầm khi map thành công nhưng 1 chiều sai 100% dữ liệu.

2. **iGPU-less = GPU0 chiếm 24MB BAR1.** Đây là gốc rễ. Patch gốc chỉ chạy nơi GPU không làm console
   (server có BMC). Trên main thường (1 GPU phải xuất hình) sẽ dính → cần 2 fix code ở mục 4.

3. **Headless bằng `nvidia-drm modeset=0` KHÔNG giải phóng 24MB.** Sau khi tắt nvidia-drm, console
   chuyển sang **simpledrm/efifb (GOP của UEFI)** vẫn nằm ở đầu BAR1 GPU0 → offset 24MB vẫn còn.
   Vì vậy **fix code mới là lời giải**, không phải headless. (Đã thử headless, offset không đổi.)

4. **`intel_iommu=off` (theo README cũ của tinygrad) → sai cho nhánh này.** Nhánh aikitoria dùng
   đường `_kbusCreateStaticBar1IOMMUMapping` cần IOMMU hiện diện → dùng **`iommu=pt`** (passthrough).
   `translating` (intel_iommu=on không pt) thì DMA dữ liệu đi qua page table IOMMU → fail.

5. **Kernel ≥6.13 không build được driver 570** (đổi `$(src)` Kbuild → "os-interface.h not found").
   Phải dùng kernel ≤6.12 (ở đây 6.8). Bản 580 build được trên 6.17 nhưng 580 **chưa có** nhánh
   p2p (nhánh cao nhất của tinygrad là 570.148.08).

6. **Userspace và kernel module PHẢI cùng version chính xác** (570.148.08). Trộn module 570 với
   userspace 580 → "Driver/library version mismatch". Vì vậy phải gỡ hẳn driver 580 cũ.

7. **URL GeForce của 570.148.08 trả 404** — đây là bản **datacenter/tesla**:
   `https://us.download.nvidia.com/tesla/570.148.08/NVIDIA-Linux-x86_64-570.148.08.run`

8. **`.run --silent` fail nếu đang chạy X/gdm** (mặc định chọn "Abort"). Phải `systemctl stop gdm`
   trước (SSH qua Cloudflare tunnel không bị ảnh hưởng).

9. **Thiếu `pci=realloc=on`** → sau khi BIOS ReBAR set 2 BAR1 32GB, kernel không nhét nổi BAR0 16MB
   (vùng 32-bit dưới 4G) của GPU2 → GPU2 mất tích (`NVRM: BAR0 is 0M @ 0x0`).

10. **Secure Boot phải OFF** (hoặc tự ký MOK), nếu không module tự build không load được.

11. **Module tự build KHÔNG qua DKMS** → kernel mới (vd 6.8.0-125) sẽ không có module. Phải
    `make modules_install` lại cho kernel đó, hoặc set DKMS.

---

## 6. Test / verify

- `scripts/p2p_test2.py` — so sánh **bit-exact từng chiều** (đây là test "thật").
- `scripts/p2p_test.py` — roundtrip 1GiB + băng thông 2 chiều + tốc độ/độ rộng link PCIe.
- `nvidia-smi topo -p2p rw` — ma trận khả năng (OK/CNS).
- `scripts/acs_fix.sh` — tắt ACS runtime + dump trạng thái (ACS mặc định đã off trên main này).
- `scripts/diag2.sh` — dump lỗi NVRM, IOMMU domain, cmdline.

Kết quả mong đợi: `GPU0->GPU1 OK | GPU1->GPU0 OK`, ~10.3 GB/s mỗi chiều, link `8.0 GT/s x16`.

---

## 7. Rebuild khi đổi kernel
```bash
cd ~/open-gpu-kernel-modules            # (hoặc giải nén source/*.tar.gz)
make modules -j"$(nproc)"
sudo make modules_install
sudo depmod -a <kernel-release>
sudo reboot
```

## 8. Rollback về driver gốc 580 / kernel 6.17
```bash
sudo apt-get install --reinstall nvidia-driver-580-open
sudo sed -i 's#^GRUB_DEFAULT=.*#GRUB_DEFAULT=0#' /etc/default/grub   # quay lại kernel mới nhất
sudo update-grub && sudo reboot
```

---

## 9. Cấu trúc thư mục archive này

```
p2p_guide/
├── README.md                     # tài liệu này
├── memory/
│   └── rtx-gpu-p2p.md            # ghi chú memory (bản tóm tắt)
├── scripts/
│   ├── install_p2p_570.sh        # purge 580 + cài module patch + userspace (bản đầu)
│   ├── install_p2p_570b.sh       # resume: tắt gdm rồi cài userspace
│   ├── acs_fix.sh                # tắt ACS + chẩn đoán
│   ├── diag2.sh                  # dump NVRM/IOMMU/cmdline
│   ├── p2p_test.py               # roundtrip + bandwidth
│   └── p2p_test2.py              # bit-exact từng chiều (test chính)
├── patches/
│   └── p2p-igpuless-fixes.patch  # 2 fix (alignment 2MB + startOffset)
├── driver/
│   └── NVIDIA-Linux-x86_64-570.148.08.run   # userspace tesla (phòng URL chết)
└── source/
    ├── open-gpu-kernel-modules-570.148.08-p2p+rtxfixes.bundle  # git bundle ĐẦY ĐỦ history+fix
    ├── open-gpu-kernel-modules-570.148.08-p2p+rtxfixes.tar.gz  # source sạch build-được-ngay
    ├── nvidia-580.159.03.tar.gz                  # tham khảo: NVIDIA open 580 (clean)
    └── aikitoria-595.71.05-p2p.tar.gz            # tham khảo: nhánh 595 (README có cảnh báo iommu=pt)
```

Khôi phục fork từ bundle (kể cả khi repo gốc bị xoá):
```bash
git clone source/open-gpu-kernel-modules-570.148.08-p2p+rtxfixes.bundle open-gpu-kernel-modules
# nhánh 570.148.08-p2p, commit cuối = 2 fix iGPU-less
```

---

## 10. Tham khảo
- tinygrad/open-gpu-kernel-modules (nhánh `570.148.08-p2p`)
- aikitoria/open-gpu-kernel-modules (nhánh `595.71.05-p2p`) — README nêu yêu cầu `iommu=pt` và
  mục "Forcing 3090s to use PCIe instead of NVLink"
- NVIDIA open-gpu-kernel-modules tag `580.159.03`
- Issue tinygrad #26 (P2P trên Intel chậm hơn AMD ~20%), #16/#33 ("mapping of buffer object failed")

---
---

# English version

# Enabling PCIe P2P on 2× RTX 3090 on an X299 consumer board (no iGPU / no BMC)

This document records the **full process** of enabling and **data-verifying** PCIe P2P
(peer-to-peer DMA) between two RTX 3090 cards on host `rtx` — ASUS PRIME X299-A II,
Intel i9-10900X (Cascade Lake-X, **no iGPU**), no NVLink bridge. Completed 2026-05-31.

> **Result:** GPU0↔GPU1 ~**10.3 GB/s** each direction, **roundtrip bit-exact** (every
> element matches). Real BAR1 P2P — not staged through system RAM.

The core reason this is harder than the 4090 guides floating around online: **the board
has no iGPU/BMC, so one GPU is forced to host the boot console**, which breaks the
upstream P2P patch in 2 ways (see "Two code fixes" and "Common pitfalls"). The original
patch sets work fine on AMD EPYC servers (BMC handles VGA, GPUs never act as console),
which is why those guides don't hit this bug.

---

## 0. TL;DR — final working configuration

| Item | Value |
|---|---|
| Kernel | `6.8.0-124-generic` (GRUB default; **do not** use ≥6.13) |
| Driver | NVIDIA **570.148.08** open module, **with 2 custom fixes** |
| Userspace | 570.148.08 from the **tesla/datacenter** `.run` (`--no-kernel-modules`) |
| Kernel cmdline | `intel_iommu=on iommu=pt pci=realloc=on` |
| BIOS | Above 4G Decoding = ON, Resizable BAR = ON |
| Display | headless (`multi-user.target`, `nvidia-drm modeset=0`) |
| Secure Boot | OFF (so the self-built unsigned module can load) |
| Patch source | tinygrad `570.148.08-p2p` (aikitoria "Simplified p2p mod") + 2 iGPU-less fixes |

---

## 1. Context / hardware

- 2× MSI RTX 3090, each BAR1 resizable up to 32 GB (covers the 24 GB VRAM).
- The 2 GPUs sit on **2 different CPU PCIe host bridges**: `0000:17:00.0` (under bridge
  `16`) and `0000:65:00.0` (under bridge `64`). `nvidia-smi topo -m` = **NODE** (not on a
  shared PCIe switch).
- **No NVLink bridge** (couldn't source one), so the only path is **PCIe BAR1 P2P**.
- The i9-10900X has **no iGPU**; X299 has no BMC → **GPU0 (first slot) is forced to be
  the primary display / console**.

P2P across 2 host bridges on Intel goes through the CPU's IIO → bandwidth tops out around
~10 GB/s (lower than two GPUs sharing one PCIe switch), but it is real P2P and the data
is correct.

---

## 2. Solution architecture — 3 layers of problem

1. **Platform**: allow both BAR1 = 32 GB and make sure both GPUs come up.
2. **Driver**: build & install the P2P patch on a valid kernel.
3. **No-iGPU board**: deal with GPU0 holding the first 24 MB of BAR1 for the console
   (the 2 code fixes).

---

## 3. Detailed steps (full reproduction)

### Step 1 — BIOS
ASUS PRIME X299-A II → Advanced / PCI Subsystem:
- **Above 4G Decoding = Enabled** (mandatory — need ~64 GB MMIO for two 32 GB BARs)
- **Re-Size BAR Support = Enabled**

After reboot verify: `nvidia-smi -q -d MEMORY | grep -A1 BAR1` → both cards
**32768 MiB**.

### Step 2 — Kernel cmdline
```bash
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 intel_iommu=on iommu=pt pci=realloc=on"/' /etc/default/grub
sudo update-grub
```
- `iommu=pt`: passthrough — the patched path `_kbusCreateStaticBar1IOMMUMapping` requires
  the IOMMU to be present. **DO NOT use `intel_iommu=off`** (see pitfalls).
- `pci=realloc=on`: without it, GPU2's 16 MB BAR0 doesn't get assigned after ReBAR →
  GPU2 disappears (`NVRM: BAR0 is 0M @ 0x0`, probe fails).

### Step 3 — Install kernel 6.8 (if you're on kernel ≥6.13)
```bash
sudo apt-get install -y linux-image-6.8.0-124-generic linux-headers-6.8.0-124-generic
sudo update-grub
# pin GRUB default to 6.8
sudo sed -i 's#^GRUB_DEFAULT=.*#GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-124-generic"#' /etc/default/grub
sudo update-grub && sudo reboot
```
Reason: the 570 driver **will not build on kernel ≥6.13** (the kernel changed how `$(src)`
is handled in Kbuild → `os-interface.h: No such file or directory`).

### Step 4 — Get the patch source + build the module
```bash
cd ~
git clone --branch 570.148.08-p2p https://github.com/tinygrad/open-gpu-kernel-modules
cd open-gpu-kernel-modules
# >>> APPLY THE 2 FIXES (see patches/p2p-igpuless-fixes.patch) <<<
git apply /home/nghia/data/p2p_guide/patches/p2p-igpuless-fixes.patch
make modules -j"$(nproc)"          # ~1 min on 6.8; if headers fail => wrong kernel
```
> Or use the already-patched source under `source/` in this archive.

### Step 5 — Install the driver
```bash
# userspace MUST match the version (tesla build, since the GeForce URL 404s)
wget https://us.download.nvidia.com/tesla/570.148.08/NVIDIA-Linux-x86_64-570.148.08.run

# Remove the old driver (e.g. 580 from apt) to avoid version conflicts
sudo apt-get purge -y $(dpkg -l | awk '/^ii/ && /nvidia/ {print $2}'); sudo apt-get autoremove -y

# Patched module
cd ~/open-gpu-kernel-modules && sudo make modules_install -j"$(nproc)"

# Userspace — MUST stop gdm first (see pitfalls), then:
sudo systemctl stop gdm
sudo sh ~/NVIDIA-Linux-x86_64-570.148.08.run --no-kernel-modules --silent --no-nouveau-check

# Finishing touches
printf 'blacklist nouveau\noptions nouveau modeset=0\n' | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
printf 'nvidia\nnvidia_uvm\n' | sudo tee /etc/modules-load.d/nvidia-p2p.conf
sudo depmod -a 6.8.0-124-generic
sudo update-initramfs -u -k 6.8.0-124-generic
sudo reboot
```

### Step 6 — (optional) headless
Not required once the offset fix is in, but cleaner on a compute box:
```bash
echo 'options nvidia-drm modeset=0 fbdev=0' | sudo tee /etc/modprobe.d/nvidia-headless.conf
sudo systemctl set-default multi-user.target
sudo update-initramfs -u -k 6.8.0-124-generic && sudo reboot
```

### Step 7 — Verify
```bash
nvidia-smi topo -p2p rw       # GPU0/GPU1 must be OK (before fix = CNS)
python3 ~/p2p_guide/scripts/p2p_test2.py   # MUST: both directions "OK ... exact match"
python3 ~/p2p_guide/scripts/p2p_test.py    # bandwidth + roundtrip True
```

---

## 4. The two code fixes (the hardest part — specific to no-iGPU boards)

Because there's no iGPU/BMC, **GPU0 hosts the boot console** and reserves the first ~24 MB
of BAR1. `kbusEnableStaticBar1Mapping_TU102` places the static VRAM mapping into BAR1 at
`bar1Offset` (=24 MB on GPU0, =0 on the GPU without a display). That breaks two things:

**Fix 1 — Alignment** `src/nvidia/src/kernel/gpu/bus/arch/hopper/kern_bus_gh100.c`
(function `_kbusCreateStaticBar1IOMMUMapping`):
```c
- if (!NV_IS_ALIGNED64(peerDmaAddr, RM_PAGE_SIZE_512M))   // Hopper-only: 512 MB page
+ if (!NV_IS_ALIGNED64(peerDmaAddr, RM_PAGE_SIZE_HUGE))   // Ampere actually uses 2 MB pages
```
Before the fix: `NVRM: peer DMA address 0x13001800000 is not aligned at 0x20000000` →
`cudaErrorMapBufferObjectFailed`. Ampere has no 512 MB pages (that's a Hopper feature);
Ampere's static mapping uses `RM_PAGE_SIZE_HUGE` (2 MB) — and 24 MB **is** 2 MB-aligned,
so we relax the check to 2 MB.

**Fix 2 — Offset (CRITICAL: prevents silent data corruption)**
`src/nvidia/src/kernel/rmapi/nv_gpu_ops.c` (~line 4399):
```c
- bar1BusAddr = gpumgrGetGpuPhysFbAddr(pAdjustedMemDesc->pGpu);                 // BAR1 base only
+ bar1BusAddr = gpumgrGetGpuPhysFbAddr(pAdjustedMemDesc->pGpu) +
+               GPU_GET_KERNEL_BUS(pAdjustedMemDesc->pGpu)->bar1[GPU_GFID_PF].staticBar1.startOffset;
```
`gpumgrGetGpuPhysFbAddr` returns only the BAR1 base, but the statically mapped VRAM
region starts at `base + 24 MB`. Missing the `startOffset` → writes targeted at the
console GPU land **exactly 24 MB off** → **silent data corruption** (only writes *to*
GPU0 are wrong; the other direction is fine). Only a bit-exact test catches this.

→ Both fixes live in `patches/p2p-igpuless-fixes.patch`.

---

## 5. ⚠️ Common pitfalls (read carefully!)

1. **Thinking `topo -p2p = OK` / `can_device_access_peer = True` means you're done.** WRONG.
   That's just the driver *advertising* P2P capability. **You MUST run a bit-exact data
   transfer test in both directions.** I almost shipped a "working" setup where mapping
   succeeded but one direction was 100% corrupt.

2. **No iGPU = GPU0 takes 24 MB of BAR1.** This is the root cause. The upstream patch
   only works where the GPU never acts as console (servers with BMC). On a normal
   desktop board (one GPU must drive video) you'll hit this → you need the 2 code fixes
   from section 4.

3. **Going headless via `nvidia-drm modeset=0` does NOT free those 24 MB.** Once
   nvidia-drm is off the console switches to **simpledrm/efifb (UEFI GOP)**, which still
   occupies the start of GPU0's BAR1 → the 24 MB offset is still there. So **the code
   fix is the real solution**, not headless. (Tested headless — offset doesn't move.)

4. **`intel_iommu=off` (per the old tinygrad README) is wrong on this branch.** The
   aikitoria branch uses `_kbusCreateStaticBar1IOMMUMapping`, which requires the IOMMU
   to be present → use **`iommu=pt`** (passthrough). `translating` mode (intel_iommu=on
   without pt) routes data DMA through IOMMU page tables → fail.

5. **Kernel ≥6.13 won't build the 570 driver** (the `$(src)` Kbuild change →
   "os-interface.h not found"). Must use kernel ≤6.12 (here 6.8). The 580 driver builds
   on 6.17, but 580 **doesn't have** the p2p branch (tinygrad's latest p2p branch is
   570.148.08).

6. **Userspace and kernel module MUST be the exact same version** (570.148.08). Mixing a
   570 module with 580 userspace → "Driver/library version mismatch". So you really do
   have to purge the old 580 driver.

7. **The GeForce URL for 570.148.08 returns 404** — it's the **datacenter/tesla** build:
   `https://us.download.nvidia.com/tesla/570.148.08/NVIDIA-Linux-x86_64-570.148.08.run`

8. **`.run --silent` fails while X/gdm is running** (it defaults to "Abort"). Run
   `systemctl stop gdm` first (SSH via Cloudflare tunnel is unaffected).

9. **Missing `pci=realloc=on`** → after BIOS ReBAR sets two 32 GB BAR1s, the kernel can't
   place GPU2's 16 MB BAR0 (the 32-bit region below 4 GB) → GPU2 vanishes
   (`NVRM: BAR0 is 0M @ 0x0`).

10. **Secure Boot must be OFF** (or you must MOK-sign yourself), otherwise the
    self-built module won't load.

11. **The self-built module does NOT go through DKMS** → a new kernel (e.g. 6.8.0-125)
    won't have the module. You must `make modules_install` again for that kernel, or set
    up DKMS yourself.

---

## 6. Tests / verification

- `scripts/p2p_test2.py` — **bit-exact** per-direction comparison (this is the "real" test).
- `scripts/p2p_test.py` — 1 GiB roundtrip + 2-way bandwidth + PCIe link speed/width.
- `nvidia-smi topo -p2p rw` — capability matrix (OK/CNS).
- `scripts/acs_fix.sh` — disable ACS at runtime + status dump (ACS is off by default on
  this board).
- `scripts/diag2.sh` — dump NVRM errors, IOMMU domain, kernel cmdline.

Expected result: `GPU0->GPU1 OK | GPU1->GPU0 OK`, ~10.3 GB/s each direction, link
`8.0 GT/s x16`.

---

## 7. Rebuilding after a kernel change
```bash
cd ~/open-gpu-kernel-modules            # (or extract source/*.tar.gz)
make modules -j"$(nproc)"
sudo make modules_install
sudo depmod -a <kernel-release>
sudo reboot
```

## 8. Rollback to stock driver 580 / kernel 6.17
```bash
sudo apt-get install --reinstall nvidia-driver-580-open
sudo sed -i 's#^GRUB_DEFAULT=.*#GRUB_DEFAULT=0#' /etc/default/grub   # back to the newest kernel
sudo update-grub && sudo reboot
```

---

## 9. Layout of this archive

```
p2p_guide/
├── README.md                     # this document
├── memory/
│   └── rtx-gpu-p2p.md            # memory notes (summary)
├── scripts/
│   ├── install_p2p_570.sh        # purge 580 + install patched module + userspace (first pass)
│   ├── install_p2p_570b.sh       # resume: stop gdm then install userspace
│   ├── acs_fix.sh                # disable ACS + diagnostics
│   ├── diag2.sh                  # NVRM / IOMMU / cmdline dump
│   ├── p2p_test.py               # roundtrip + bandwidth
│   └── p2p_test2.py              # bit-exact per direction (the main test)
├── patches/
│   └── p2p-igpuless-fixes.patch  # the 2 fixes (2 MB alignment + startOffset)
├── driver/
│   └── NVIDIA-Linux-x86_64-570.148.08.run   # tesla userspace (in case the URL dies)
└── source/
    ├── open-gpu-kernel-modules-570.148.08-p2p+rtxfixes.bundle  # FULL git bundle (history + fixes)
    ├── open-gpu-kernel-modules-570.148.08-p2p+rtxfixes.tar.gz  # clean ready-to-build source
    ├── nvidia-580.159.03.tar.gz                  # reference: NVIDIA open 580 (clean)
    └── aikitoria-595.71.05-p2p.tar.gz            # reference: 595 branch (its README warns about iommu=pt)
```

Restore the fork from the bundle (even if the upstream repo gets deleted):
```bash
git clone source/open-gpu-kernel-modules-570.148.08-p2p+rtxfixes.bundle open-gpu-kernel-modules
# branch 570.148.08-p2p, last commit = the 2 iGPU-less fixes
```

---

## 10. References
- tinygrad/open-gpu-kernel-modules (branch `570.148.08-p2p`)
- aikitoria/open-gpu-kernel-modules (branch `595.71.05-p2p`) — README mentions the
  `iommu=pt` requirement and the section "Forcing 3090s to use PCIe instead of NVLink"
- NVIDIA open-gpu-kernel-modules tag `580.159.03`
- tinygrad issue #26 (P2P on Intel ~20% slower than AMD), #16/#33 ("mapping of buffer
  object failed")


# Bật PCIe P2P cho 2× RTX 3090 trên board không iGPU/BMC — TRX40/Threadripper (và X299)

> **[English version below](#english-version) — scroll to the bottom for the full English guide.**

Tài liệu này ghi lại **toàn bộ quá trình** bật và **kiểm chứng dữ liệu** P2P (peer-to-peer DMA)
giữa 2 card RTX 3090 trên host `rtx`, không có cầu NVLink. Đã chạy trên **2 nền tảng**; nền tảng
**hiện tại (ưu tiên) là AMD Threadripper**.

> **Kết quả hiện tại (TRX40 / Threadripper 3960X, PCIe 4.0):** GPU0↔GPU1 **~26 GB/s** mỗi chiều,
> **roundtrip bit-exact**. P2P BAR1 thật, không staging qua RAM.
> *(Nền tảng gốc X299/i9-10900X (PCIe 3.0) trước đó: ~10 GB/s — cùng driver patch.)*

Điểm cốt lõi khiến việc này khó hơn các hướng dẫn 4090 trên mạng: **board không có iGPU/BMC nên một
GPU buộc phải gánh console boot**, làm hỏng patch P2P gốc theo 2 cách (xem "Hai fix code" và "Dễ làm
sai"). Patch gốc chạy ngon trên **server AMD EPYC có BMC** (GPU không bao giờ làm console) nên không
gặp lỗi này — cả Threadripper lẫn HEDT Intel đều **không có iGPU** nên đều dính.

---

## ⭐ Hai nền tảng đã kiểm chứng (ưu tiên TRX40)

| Hạng mục | **TRX40 — hiện tại (ưu tiên)** | X299 — ban đầu |
|---|---|---|
| Mainboard | **Gigabyte TRX40 AORUS PRO WIFI** | ASUS PRIME X299-A II |
| CPU | **AMD Ryzen Threadripper 3960X** (24C/48T) | Intel i9-10900X (10C/20T) |
| Socket / chipset | **sTRX4 / TRX40** | LGA2066 / X299 |
| PCIe | **4.0** | 3.0 |
| **Băng thông P2P** | **~26 GB/s** mỗi chiều | ~10 GB/s |
| cmdline IOMMU | **`amd_iommu=on iommu=pt`** | `intel_iommu=on iommu=pt` |
| `pci=realloc=on` | **không cần** | **cần** (không thì GPU2 mất BAR0) |
| GPU PCI addr | `0000:21:00.0` / `0000:48:00.0` | `0000:17:00.0` / `0000:65:00.0` |
| `nvidia-smi topo` | NODE | NODE |
| Chip quạt (ngoài lề) | ITE **IT8688E** (`it87` DKMS) | Nuvoton **NCT6798D** (`nct6775`) |
| **Driver patch + 2 fix** | **GIỐNG HỆT** ✓ | giống hệt ✓ |

**Kết luận quan trọng:** đổi mainboard **KHÔNG cần** patch/ build lại — kernel module độc lập board.
Chỉ khác: cmdline (`intel_iommu`↔`amd_iommu`) và một vài tiểu tiết BIOS. AMD (TRX40/EPYC) **nhanh hơn
nhiều và ít trục trặc** (PCIe 4.0 + route peer tốt).

---

## 0. TL;DR — cấu hình đang chạy (TRX40 / 3960X)

| Hạng mục | Giá trị |
|---|---|
| Mainboard / CPU | Gigabyte TRX40 AORUS PRO WIFI / Threadripper 3960X (sTRX4) |
| Kernel | `6.8.0-124-generic` (GRUB default; **không** dùng ≥6.13) |
| Driver | NVIDIA **570.148.08** open module, **có 2 fix tự viết** |
| Userspace | 570.148.08 từ bản **tesla/datacenter** (`.run --no-kernel-modules`) |
| Kernel cmdline | `amd_iommu=on iommu=pt` *(X299 dùng `intel_iommu=on iommu=pt pci=realloc=on`)* |
| BIOS | Above 4G Decoding = ON, Resizable BAR = ON → BAR1 = 32768 MiB mỗi card |
| Hiển thị | GUI bật bình thường (graphical.target, modeset=1) — fix offset xử lý console BAR1 |
| Secure Boot | OFF (để load module tự build, chưa ký) |
| Source patch | tinygrad `570.148.08-p2p` (aikitoria "Simplified p2p mod") + 2 fix iGPU-less |

---

## 1. Bối cảnh / phần cứng

**Hiện tại — TRX40 / Threadripper 3960X (sTRX4):**
- 2× RTX 3090 ở `0000:21:00.0` và `0000:48:00.0`, **PCIe 4.0 x16** (idle tụt Gen1 2.5GT/s, train lên
  16 GT/s khi tải — đừng nhầm là lỗi). `nvidia-smi topo -m` = NODE.
- Threadripper **không có iGPU** → GPU0 (slot đầu) buộc làm console (giống X299) → vẫn cần 2 fix code.
- AMD route P2P qua Infinity Fabric tốt → **~26 GB/s** bit-exact (gấp ~2.5× X299 Gen3).

**Ban đầu — X299 / i9-10900X (tham chiếu Intel):**
- 2× MSI RTX 3090 ở `0000:17:00.0` / `0000:65:00.0`, PCIe 3.0. P2P qua 2 host bridge xuyên IIO Intel →
  ~10 GB/s, chậm hơn AMD ~20% và kén hơn (nhưng vẫn đúng dữ liệu).
- Mỗi card BAR1 resize được tới 32GB (đủ phủ 24GB VRAM); không NVLink.

---

## 2. Kiến trúc giải pháp — 3 tầng vấn đề (chung cho cả 2 nền tảng)

1. **Platform**: BIOS cho 2 BAR1 = 32GB và cả 2 GPU lên đủ (X299 cần `pci=realloc=on`; TRX40 không).
2. **Driver**: build & cài patch P2P trên kernel hợp lệ (≤6.12).
3. **Bo mạch không iGPU**: xử lý GPU0 chiếm 24MB đầu BAR1 cho console (2 fix code).

---

## 3. Các bước chi tiết (tái lập từ đầu)

### Bước 1 — BIOS
- **Above 4G Decoding = Enabled** và **Re-Size BAR Support = Enabled**.
  - TRX40 AORUS: `Settings → AMD CBS / PCIe`; thường thân thiện sẵn.
  - X299 ASUS: `Advanced → PCI Subsystem`.
- Kiểm tra sau reboot: `nvidia-smi -q -d MEMORY | grep -A1 BAR1` → cả 2 card **32768 MiB**.

### Bước 2 — Kernel cmdline
```bash
# AMD (TRX40 — hiện tại):
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amd_iommu=on iommu=pt"/' /etc/default/grub
# Intel (X299): thay bằng  intel_iommu=on iommu=pt pci=realloc=on
sudo update-grub
```
- `iommu=pt` (passthrough) **bắt buộc** — đường patch `_kbusCreateStaticBar1IOMMUMapping` cần IOMMU hiện
  diện. **KHÔNG dùng `iommu=off`** (xem pitfalls). `iommu=pt` là generic, AMD & Intel đều nhận.
- `pci=realloc=on`: chỉ **X299** cần (BAR0 16MB của GPU2 không cấp được sau ReBAR → `NVRM: BAR0 is 0M @
  0x0`). TRX40 không cần.

### Bước 3 — Cài kernel 6.8 (nếu đang ở kernel ≥6.13)
```bash
sudo apt-get install -y linux-image-6.8.0-124-generic linux-headers-6.8.0-124-generic
sudo sed -i 's#^GRUB_DEFAULT=.*#GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-124-generic"#' /etc/default/grub
sudo update-grub && sudo reboot
```
Lý do: driver 570 **không build trên kernel ≥6.13** (đổi `$(src)` Kbuild → `os-interface.h: No such file`).

### Bước 4 — Lấy source patch + build module
```bash
git clone --branch 570.148.08-p2p https://github.com/tinygrad/open-gpu-kernel-modules
cd open-gpu-kernel-modules
git apply <repo>/patches/p2p-igpuless-fixes.patch     # 2 fix; hoặc giải nén source/*.tar.gz đã patch sẵn
make modules -j"$(nproc)"          # ~1 phút trên 6.8; fail headers => sai kernel
```

### Bước 5 — Cài driver
```bash
wget https://us.download.nvidia.com/tesla/570.148.08/NVIDIA-Linux-x86_64-570.148.08.run  # GeForce URL 404
sudo apt-get purge -y $(dpkg -l | awk '/^ii/ && /nvidia/ {print $2}'); sudo apt-get autoremove -y
cd open-gpu-kernel-modules && sudo make modules_install -j"$(nproc)"
sudo systemctl stop gdm                          # .run --silent FAIL nếu X/gdm đang chạy
sudo sh NVIDIA-Linux-x86_64-570.148.08.run --no-kernel-modules --silent --no-nouveau-check
printf 'nvidia\nnvidia_uvm\n' | sudo tee /etc/modules-load.d/nvidia-p2p.conf
sudo depmod -a 6.8.0-124-generic
sudo update-initramfs -u -k 6.8.0-124-generic
sudo reboot
```

### Bước 6 — Kiểm chứng (BẮT BUỘC — `topo=OK` chưa đủ!)
```bash
nvidia-smi topo -p2p rw                  # GPU0/GPU1 = OK (trước fix = CNS)
python3 <repo>/scripts/p2p_test2.py      # PHẢI: cả 2 chiều "OK ... khop tuyet doi"
python3 <repo>/scripts/p2p_test.py       # roundtrip True + băng thông + link (auto-detect addr)
```
Kỳ vọng: bit-exact 2 chiều. TRX40 ~26 GB/s @ 16 GT/s x16; X299 ~10 GB/s @ 8 GT/s x16.

> Desktop GUI có thể **bật bình thường** — fix offset xử lý động vùng console BAR1, P2P vẫn đúng (đã
> kiểm chứng). Headless không bắt buộc.

---

## 4. Hai fix code (phần khó nhất — cần cho MỌI board không iGPU/BMC, cả AMD lẫn Intel)

Không có iGPU/BMC → **GPU0 gánh console boot**, chiếm ~24MB đầu BAR1. Hàm
`kbusEnableStaticBar1Mapping_TU102` đặt vùng map VRAM tĩnh tại `bar1Offset` (=24MB trên GPU có console,
=0 trên GPU không màn hình) → phá 2 thứ:

**Fix 1 — Alignment** `src/nvidia/src/kernel/gpu/bus/arch/hopper/kern_bus_gh100.c`
(`_kbusCreateStaticBar1IOMMUMapping`):
```c
- if (!NV_IS_ALIGNED64(peerDmaAddr, RM_PAGE_SIZE_512M))   // Hopper-only: page 512MB
+ if (!NV_IS_ALIGNED64(peerDmaAddr, RM_PAGE_SIZE_HUGE))   // Ampere thực dùng page 2MB
```
Trước fix: `NVRM: peer DMA address 0x..1800000 is not aligned at 0x20000000` → `cudaErrorMapBufferObjectFailed`.

**Fix 2 — Offset (QUAN TRỌNG: chống sai dữ liệu thầm lặng)** `src/nvidia/src/kernel/rmapi/nv_gpu_ops.c`:
```c
- bar1BusAddr = gpumgrGetGpuPhysFbAddr(pAdjustedMemDesc->pGpu);
+ bar1BusAddr = gpumgrGetGpuPhysFbAddr(pAdjustedMemDesc->pGpu) +
+               GPU_GET_KERNEL_BUS(pAdjustedMemDesc->pGpu)->bar1[GPU_GFID_PF].staticBar1.startOffset;
```
Thiếu `startOffset` → ghi vào GPU-có-console **lệch 24MB → sai dữ liệu im lặng** (chỉ chiều ghi vào GPU0
sai; checksum/sum vẫn trùng → dễ nghiệm thu nhầm). Chỉ test **bit-exact** mới bắt. Cả 2 fix trong
`patches/p2p-igpuless-fixes.patch`.

---

## 5. ⚠️ Những điểm DỄ LÀM SAI

1. **`topo -p2p = OK` / `can_device_access_peer = True` KHÔNG phải xong** — chỉ là driver quảng bá. Bắt
   buộc test **bit-exact 2 chiều**. (Sum/checksum trùng vẫn có thể sai 100% 1 chiều — suýt nghiệm thu nhầm.)
2. **Board không iGPU → GPU0 chiếm 24MB BAR1** = gốc rễ → cần 2 fix code (mục 4). Cả Threadripper lẫn
   HEDT Intel đều dính (server có BMC thì không).
3. **Headless `nvidia-drm modeset=0` KHÔNG giải phóng 24MB** — simpledrm/efifb (GOP UEFI) vẫn giữ đầu
   BAR1. Fix code mới là lời giải, không phải headless.
4. **`iommu=off` sai cho nhánh này** → dùng **`iommu=pt`** (passthrough). `translating` (on mà không pt)
   thì DMA dữ liệu đi qua page table IOMMU → fail.
5. **Kernel ≥6.13 không build được 570** (`$(src)` Kbuild → "os-interface.h not found") → dùng ≤6.12 (6.8).
   580 build được trên 6.17 nhưng 580 **chưa có** nhánh p2p (cao nhất là 570.148.08).
6. **Userspace ↔ kernel module phải cùng version** (570.148.08), không thì "Driver/library version mismatch".
7. **URL GeForce 570.148.08 = 404** → bản **tesla**: `…/tesla/570.148.08/NVIDIA-Linux-x86_64-570.148.08.run`.
8. **`.run --silent` fail nếu X/gdm đang chạy** → `systemctl stop gdm` trước (SSH không bị ảnh hưởng).
9. **Thiếu `pci=realloc=on` (chỉ X299)** → GPU2 mất BAR0 (`NVRM: BAR0 is 0M @ 0x0`). TRX40 không cần.
10. **Secure Boot phải OFF** (hoặc tự ký MOK).
11. **Module không qua DKMS** → kernel mới phải `make modules_install` lại (nên pin/đóng băng kernel).
12. **Đổi mainboard KHÔNG cần patch lại** — chỉ chỉnh cmdline `intel_iommu`↔`amd_iommu`, BIOS Above-4G/ReBAR,
    rồi verify bit-exact. (Chip cảm biến/quạt đổi theo board: X299=NCT6798D/`nct6775`, TRX40=IT8688E/`it87`
    DKMS — không liên quan P2P.)

---

## 6. Test / verify
- `scripts/p2p_test2.py` — **bit-exact từng chiều** (test "thật").
- `scripts/p2p_test.py` — roundtrip 1GiB + băng thông 2 chiều + link PCIe (tự dò địa chỉ GPU, board-independent).
- `nvidia-smi topo -p2p rw` — ma trận OK/CNS.
- `scripts/acs_fix.sh`, `scripts/diag2.sh` — tắt ACS / dump NVRM-IOMMU-cmdline.

## 7. Rebuild khi đổi kernel
```bash
cd open-gpu-kernel-modules            # (hoặc giải nén source/*.tar.gz)
make modules -j"$(nproc)" && sudo make modules_install && sudo depmod -a <kernel-release> && sudo reboot
```

## 8. Rollback về driver gốc 580
```bash
sudo apt-get install --reinstall nvidia-driver-580-open
sudo sed -i 's#^GRUB_DEFAULT=.*#GRUB_DEFAULT=0#' /etc/default/grub && sudo update-grub && sudo reboot
```

---

## 9. Cấu trúc repo này
```
rtx3090-p2p-noigpu/
├── README.md                     # tài liệu này
├── memory/rtx-gpu-p2p.md         # ghi chú tóm tắt (TRX40 + X299)
├── scripts/                      # p2p_test.py, p2p_test2.py, install_p2p_570*.sh, acs_fix.sh, diag2.sh
├── patches/p2p-igpuless-fixes.patch        # 2 fix (alignment 2MB + startOffset)
└── source/
    ├── open-gpu-kernel-modules-570.148.08-p2p+rtxfixes.bundle   # git bundle ĐẦY ĐỦ history + 2 fix
    ├── open-gpu-kernel-modules-570.148.08-p2p+rtxfixes.tar.gz   # source sạch build-được-ngay
    ├── nvidia-580.159.03.tar.gz             # tham khảo: NVIDIA open 580 (clean)
    └── aikitoria-595.71.05-p2p.tar.gz       # tham khảo: nhánh 595 (README cảnh báo iommu=pt)
```
> `driver/` (file `.run` 375MB) bị `.gitignore` — tải lại từ URL tesla ở Bước 5.

Khôi phục fork từ bundle (kể cả khi repo gốc bị xoá):
```bash
git clone source/open-gpu-kernel-modules-570.148.08-p2p+rtxfixes.bundle open-gpu-kernel-modules
```

## 10. Tham khảo
- tinygrad/open-gpu-kernel-modules (`570.148.08-p2p`); aikitoria/open-gpu-kernel-modules (`595.71.05-p2p`,
  README nêu `iommu=pt` + "Forcing 3090s to use PCIe instead of NVLink").
- NVIDIA open-gpu-kernel-modules tag `580.159.03`.
- Issue tinygrad #26 (Intel chậm hơn AMD ~20%), #16/#33 ("mapping of buffer object failed").

---
---

# English version

# Enabling PCIe P2P on 2× RTX 3090 on no-iGPU/BMC boards — TRX40/Threadripper (and X299)

Records the **full process** of enabling and **data-verifying** PCIe P2P (peer-to-peer DMA) between two
RTX 3090s on host `rtx`, no NVLink bridge. Done on **two platforms**; the **current (primary) one is AMD
Threadripper**.

> **Current result (TRX40 / Threadripper 3960X, PCIe 4.0):** GPU0↔GPU1 **~26 GB/s** each direction,
> **roundtrip bit-exact**. Real BAR1 P2P — not staged through system RAM.
> *(Original X299/i9-10900X (PCIe 3.0): ~10 GB/s — same patched driver.)*

The core reason this is harder than the 4090 guides online: **no iGPU/BMC, so one GPU is forced to host
the boot console**, which breaks the upstream P2P patch in 2 ways (see "Two code fixes" / "Pitfalls").
The upstream patch works on **AMD EPYC servers with BMC** (GPUs never act as console) — both Threadripper
and Intel HEDT lack an iGPU, so both hit this.

## ⭐ Two verified platforms (TRX40 prioritized)

| Item | **TRX40 — current (primary)** | X299 — original |
|---|---|---|
| Mainboard | **Gigabyte TRX40 AORUS PRO WIFI** | ASUS PRIME X299-A II |
| CPU | **AMD Threadripper 3960X** (24C/48T) | Intel i9-10900X (10C/20T) |
| Socket / chipset | **sTRX4 / TRX40** | LGA2066 / X299 |
| PCIe | **4.0** | 3.0 |
| **P2P bandwidth** | **~26 GB/s** each way | ~10 GB/s |
| cmdline IOMMU | **`amd_iommu=on iommu=pt`** | `intel_iommu=on iommu=pt` |
| `pci=realloc=on` | **not needed** | **needed** (else GPU2 loses BAR0) |
| GPU PCI addrs | `0000:21:00.0` / `0000:48:00.0` | `0000:17:00.0` / `0000:65:00.0` |
| Fan chip (aside) | ITE **IT8688E** (`it87` DKMS) | Nuvoton **NCT6798D** (`nct6775`) |
| **Patched driver + 2 fixes** | **IDENTICAL** ✓ | identical ✓ |

**Key takeaway:** swapping the motherboard needs **no re-patch/rebuild** — the kernel module is
board-independent. Only the cmdline (`intel_iommu`↔`amd_iommu`) and a few BIOS bits differ. AMD
(TRX40/EPYC) is **much faster and less finicky** (PCIe 4.0 + good peer routing).

## 0. TL;DR — running config (TRX40 / 3960X)

| Item | Value |
|---|---|
| Board / CPU | Gigabyte TRX40 AORUS PRO WIFI / Threadripper 3960X (sTRX4) |
| Kernel | `6.8.0-124-generic` (GRUB default; **do not** use ≥6.13) |
| Driver | NVIDIA **570.148.08** open module, **with 2 custom fixes** |
| Userspace | 570.148.08 from the **tesla/datacenter** `.run` (`--no-kernel-modules`) |
| Kernel cmdline | `amd_iommu=on iommu=pt` *(X299: `intel_iommu=on iommu=pt pci=realloc=on`)* |
| BIOS | Above 4G Decoding = ON, Resizable BAR = ON → BAR1 = 32768 MiB per card |
| Display | GUI on normally (graphical, modeset=1) — the offset fix handles the console BAR1 |
| Secure Boot | OFF (so the self-built unsigned module loads) |
| Patch source | tinygrad `570.148.08-p2p` (aikitoria "Simplified p2p mod") + 2 no-iGPU fixes |

## 1. Context / hardware

**Current — TRX40 / Threadripper 3960X (sTRX4):** 2× RTX 3090 at `0000:21:00.0` / `0000:48:00.0`,
**PCIe 4.0 x16** (idle drops to Gen1 2.5 GT/s, trains to 16 GT/s under load — not a fault).
`nvidia-smi topo -m` = NODE. Threadripper has **no iGPU** → GPU0 hosts the console → still needs the 2
fixes. AMD routes P2P over Infinity Fabric well → **~26 GB/s** bit-exact (~2.5× the X299 Gen3).

**Original — X299 / i9-10900X (Intel reference):** 2× RTX 3090 at `0000:17:00.0` / `0000:65:00.0`,
PCIe 3.0. P2P across two host bridges via Intel's IIO → ~10 GB/s, ~20% slower than AMD and pickier (but
data-correct). Each BAR1 resizable to 32 GB; no NVLink.

## 2. Solution architecture — 3 layers (same on both)

1. **Platform**: BIOS allows both BAR1 = 32 GB and both GPUs come up (X299 needs `pci=realloc=on`; TRX40 doesn't).
2. **Driver**: build & install the P2P patch on a valid kernel (≤6.12).
3. **No-iGPU board**: handle GPU0 holding the first 24 MB of BAR1 for the console (the 2 code fixes).

## 3. Detailed steps

**Step 1 — BIOS:** Above 4G Decoding = Enabled, Resizable BAR = Enabled (TRX40 AORUS: AMD CBS/PCIe;
X299 ASUS: Advanced → PCI Subsystem). Verify: `nvidia-smi -q -d MEMORY | grep -A1 BAR1` → both 32768 MiB.

**Step 2 — Kernel cmdline:** AMD → add `amd_iommu=on iommu=pt`; Intel → `intel_iommu=on iommu=pt pci=realloc=on`.
`iommu=pt` (passthrough) is **mandatory** (`_kbusCreateStaticBar1IOMMUMapping` needs the IOMMU present);
**never `iommu=off`**. `pci=realloc=on` only on X299 (else GPU2 loses its BAR0: `NVRM: BAR0 is 0M @ 0x0`).

**Step 3 — Install kernel 6.8 if on ≥6.13** (570 won't build on ≥6.13: `$(src)` Kbuild →
"os-interface.h: No such file"):
```bash
sudo apt-get install -y linux-image-6.8.0-124-generic linux-headers-6.8.0-124-generic
sudo sed -i 's#^GRUB_DEFAULT=.*#GRUB_DEFAULT="Advanced options for Ubuntu>Ubuntu, with Linux 6.8.0-124-generic"#' /etc/default/grub
sudo update-grub && sudo reboot
```

**Step 4 — Source + build:**
```bash
git clone --branch 570.148.08-p2p https://github.com/tinygrad/open-gpu-kernel-modules
cd open-gpu-kernel-modules && git apply <repo>/patches/p2p-igpuless-fixes.patch
make modules -j"$(nproc)"
```

**Step 5 — Install driver:**
```bash
wget https://us.download.nvidia.com/tesla/570.148.08/NVIDIA-Linux-x86_64-570.148.08.run  # GeForce URL 404s
sudo apt-get purge -y $(dpkg -l | awk '/^ii/ && /nvidia/ {print $2}'); sudo apt-get autoremove -y
cd open-gpu-kernel-modules && sudo make modules_install -j"$(nproc)"
sudo systemctl stop gdm                          # .run --silent fails if X/gdm is running
sudo sh NVIDIA-Linux-x86_64-570.148.08.run --no-kernel-modules --silent --no-nouveau-check
printf 'nvidia\nnvidia_uvm\n' | sudo tee /etc/modules-load.d/nvidia-p2p.conf
sudo depmod -a 6.8.0-124-generic; sudo update-initramfs -u -k 6.8.0-124-generic; sudo reboot
```

**Step 6 — Verify (mandatory — `topo=OK` is not enough!):**
```bash
nvidia-smi topo -p2p rw                  # GPU0/GPU1 = OK (before fix = CNS)
python3 <repo>/scripts/p2p_test2.py      # MUST: both directions "OK ... exact match"
python3 <repo>/scripts/p2p_test.py       # roundtrip True + bandwidth + link
```
Expect bit-exact both ways. TRX40 ~26 GB/s @ 16 GT/s x16; X299 ~10 GB/s @ 8 GT/s x16. Desktop GUI can stay
on — the offset fix handles the console BAR1 dynamically.

## 4. The two code fixes (hardest part — needed on ANY no-iGPU/BMC board, AMD or Intel)

No iGPU/BMC → **GPU0 hosts the console**, reserving the first ~24 MB of BAR1.
`kbusEnableStaticBar1Mapping_TU102` places the static VRAM mapping at `bar1Offset` (=24 MB on the console
GPU, =0 on the display-less one). That breaks two things:

**Fix 1 — Alignment** `kern_bus_gh100.c` (`_kbusCreateStaticBar1IOMMUMapping`):
```c
- if (!NV_IS_ALIGNED64(peerDmaAddr, RM_PAGE_SIZE_512M))   // Hopper-only 512 MB page
+ if (!NV_IS_ALIGNED64(peerDmaAddr, RM_PAGE_SIZE_HUGE))   // Ampere actually uses 2 MB pages
```
Before: `NVRM: peer DMA address 0x..1800000 is not aligned at 0x20000000` → `cudaErrorMapBufferObjectFailed`.

**Fix 2 — Offset (CRITICAL: prevents silent data corruption)** `nv_gpu_ops.c`:
```c
- bar1BusAddr = gpumgrGetGpuPhysFbAddr(pAdjustedMemDesc->pGpu);
+ bar1BusAddr = gpumgrGetGpuPhysFbAddr(pAdjustedMemDesc->pGpu) +
+               GPU_GET_KERNEL_BUS(pAdjustedMemDesc->pGpu)->bar1[GPU_GFID_PF].staticBar1.startOffset;
```
Missing `startOffset` → writes to the console GPU land **24 MB off** → **silent corruption** (only writes
*to* GPU0; the sum/checksum still matches → easy to wrongly accept). Only a **bit-exact** test catches it.

## 5. ⚠️ Pitfalls

1. **`topo=OK` / `can_access_peer=True` ≠ done** — driver only advertises. Run a **bit-exact both-way** test
   (a matching sum can still hide a 100% corrupt direction).
2. **No iGPU → GPU0 takes 24 MB of BAR1** = root cause → the 2 fixes. Both Threadripper and Intel HEDT hit
   it (BMC servers don't).
3. **Headless `modeset=0` does NOT free those 24 MB** (simpledrm/efifb keeps them). The code fix is the fix.
4. **`iommu=off` is wrong here** → use **`iommu=pt`**. `translating` (on without pt) routes data DMA through
   IOMMU page tables → fail.
5. **Kernel ≥6.13 won't build 570** → use ≤6.12 (6.8). 580 builds on 6.17 but has **no** p2p branch.
6. **Userspace ↔ module must match exactly** (570.148.08).
7. **GeForce URL 404** → tesla build `…/tesla/570.148.08/…`.
8. **`.run --silent` fails with X/gdm running** → `systemctl stop gdm` first.
9. **Missing `pci=realloc=on` (X299 only)** → GPU2 loses BAR0. Not needed on TRX40.
10. **Secure Boot OFF** (or MOK-sign).
11. **Self-built module is not DKMS** → re-run `make modules_install` per new kernel (so pin the kernel).
12. **Board swap needs no re-patch** — just cmdline `intel_iommu`↔`amd_iommu` + BIOS + re-verify. (Sensor/fan
    chip changes per board: X299=NCT6798D/`nct6775`, TRX40=IT8688E/`it87` DKMS — unrelated to P2P.)

## 6–10
Tests: `scripts/p2p_test2.py` (bit-exact per direction — the real test), `scripts/p2p_test.py` (roundtrip +
bandwidth + auto-detected PCIe link). Rebuild on kernel change: `make modules && sudo make modules_install &&
sudo depmod -a <rel> && reboot`. Rollback: `sudo apt-get install --reinstall nvidia-driver-580-open`.
Repo layout: `memory/`, `scripts/`, `patches/p2p-igpuless-fixes.patch`, `source/` (bundle + tarballs);
`driver/*.run` is gitignored (re-download from the tesla URL). Restore the fork:
`git clone source/open-gpu-kernel-modules-570.148.08-p2p+rtxfixes.bundle`. References: tinygrad
`570.148.08-p2p`, aikitoria `595.71.05-p2p` (warns about `iommu=pt`), NVIDIA tag `580.159.03`, tinygrad
issues #26/#16/#33.

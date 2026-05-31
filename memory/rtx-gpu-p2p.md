---
name: rtx-gpu-p2p
description: "How PCIe P2P was enabled on the 2x RTX 3090 on host rtx (X299) — patched driver, kernel, the two custom code fixes, and the iGPU-less board gotcha"
metadata: 
  node_type: memory
  type: project
  originSessionId: 5c578003-dad0-4adc-9c19-d99a5f5c2043
---

PCIe P2P is enabled and **data-verified** between the 2x RTX 3090 on host `rtx` (ASUS PRIME X299-A II, i9-10900X, no iGPU/BMC). Done 2026-05-31. See [[rtx-hardware-monitoring]], [[rtx-gpu-vbios]].

**Why P2P at all:** no NVLink bridge (can't buy one), 2 cards on separate CPU PCIe host bridges (`nvidia-smi topo` = NODE: bus 17 via bridge 16, bus 65 via bridge 64). Result: GPU0↔GPU1 ~10.3 GB/s each way, roundtrip bit-exact. Real BAR1 P2P, not host-staged.

**Working config (all required):**
- Kernel **6.8.0-124-generic** (GRUB default pinned to it). The tinygrad/aikitoria patch will NOT build on kernel ≥6.13 (the `$(src)` Kbuild change → "os-interface.h not found"); 6.8 is fine. 6.17 still installed as fallback (GPU won't work there — userspace is 570).
- Driver **570.148.08** open module, built from `~/open-gpu-kernel-modules` (tinygrad `570.148.08-p2p` branch = NVIDIA base `af31543a` + aikitoria "Simplified p2p mod"). Userspace from the **tesla/datacenter** `.run` (the GeForce URL 404s): `https://us.download.nvidia.com/tesla/570.148.08/NVIDIA-Linux-x86_64-570.148.08.run`, installed `--no-kernel-modules`; kernel module via `make modules_install`. Secure Boot is OFF so unsigned module loads.
- Kernel cmdline: `intel_iommu=on iommu=pt pci=realloc=on`. **iommu=pt (passthrough), NOT off** — the patch path `_kbusCreateStaticBar1IOMMUMapping` needs the IOMMU present. `pci=realloc=on` was needed so the 2nd GPU's 16MB BAR0 got assigned after BIOS ReBAR (without it GPU1 vanished: "NVRM: BAR0 is 0M @ 0x0").
- BIOS: **Above 4G Decoding + Resizable BAR ON** → both BAR1 = 32GB (covers 24GB VRAM). Verified `nvidia-smi -q -d MEMORY` BAR1 Total = 32768 MiB on both.
- Display: **GUI desktop is ON** (`graphical.target`, gdm, nvidia-drm modeset=1, GPU0 hosts the console). P2P verified bit-exact both directions WITH the desktop running — the offset fix (#2 below) handles the console's BAR1 reservation dynamically, so headless is NOT needed. (Headless `multi-user.target` + `nvidia-drm modeset=0` was tried during debugging; it does NOT free the console BAR1 region because simpledrm/efifb still maps it, which is why the code fix — not headless — was the real solution.)

**Two CUSTOM code fixes (on top of the tinygrad patch) — the hard part, specific to iGPU-less boards:**
On boards with no iGPU/BMC, a GPU is forced to host the boot console, which reserves the first ~24MB of its BAR1. The static-BAR1 P2P mapping then starts at BAR1_base+24MB instead of +0 (server boards with BMC give offset 0, which is why the stock patch "just works" there). This broke two things:
1. `src/.../bus/arch/hopper/kern_bus_gh100.c` `_kbusCreateStaticBar1IOMMUMapping`: alignment check `RM_PAGE_SIZE_512M` → changed to `RM_PAGE_SIZE_HUGE` (2MB). Ampere static mapping uses 2MB pages, not 512M (Hopper-only); 24MB offset is 2MB-aligned. Symptom before fix: `NVRM: peer DMA address 0x13001800000 not aligned at 0x20000000` → cudaErrorMapBufferObjectFailed.
2. `src/.../rmapi/nv_gpu_ops.c` (~line 4399): `bar1BusAddr = gpumgrGetGpuPhysFbAddr(pAdjustedMemDesc->pGpu)` → added `+ GPU_GET_KERNEL_BUS(pAdjustedMemDesc->pGpu)->bar1[GPU_GFID_PF].staticBar1.startOffset`. Without this the mapping succeeds but writes TO the console GPU land 24MB off → **silent data corruption** (only the direction writing to GPU0 was wrong; checksum/exact test caught it).

**Rebuild after a code change:** `cd ~/open-gpu-kernel-modules && make modules -j$(nproc)` (incremental ~5-16s) → `sudo make modules_install` → `sudo depmod -a 6.8.0-124-generic` → reboot.

**Test:** `~/p2p_test.py` (roundtrip + bandwidth) and `~/p2p_test2.py` (per-direction bit-exact). torch 2.10+cu128 already installed. `nvidia-smi topo -p2p rw` shows OK (was CNS before).

**Caveats / not-done:** self-built module is not DKMS, so a new 6.8 kernel won't auto-rebuild it. ACS was already disabled (0000) by BIOS default. Bandwidth limited to ~10 GB/s by Intel IIO cross-root-port routing (both GPUs on separate host bridges).

**Rollback to stock 580/6.17:** `sudo apt-get install --reinstall nvidia-driver-580-open`, set GRUB_DEFAULT back to 6.17, reboot.

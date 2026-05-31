import torch, time

print("torch", torch.__version__, "| GPUs:", torch.cuda.device_count())
for i in range(torch.cuda.device_count()):
    print(f"  cuda:{i}", torch.cuda.get_device_name(i))

# 1) CUDA runtime P2P capability (cudaDeviceCanAccessPeer)
ac01 = torch.cuda.can_device_access_peer(0, 1)
ac10 = torch.cuda.can_device_access_peer(1, 0)
print("\n[1] can_device_access_peer  0->1:", ac01, " 1->0:", ac10)

# 2) Correctness: pattern on GPU0 -> GPU1 -> back to GPU0, must match exactly
N = 256 * 1024 * 1024            # 256M float32 = 1.0 GiB
a0 = torch.arange(N, dtype=torch.float32, device='cuda:0')
a0 = a0 * 1.000001 + 7.0          # non-trivial pattern
b1 = torch.empty(N, dtype=torch.float32, device='cuda:1')
b1.copy_(a0)                      # GPU0 -> GPU1 (P2P if enabled)
back = torch.empty(N, dtype=torch.float32, device='cuda:0')
back.copy_(b1)                    # GPU1 -> GPU0
torch.cuda.synchronize()
exact = torch.equal(back, a0)
print(f"[2] correctness roundtrip (1GiB exact match): {exact}")
print(f"    checksum src={a0.double().sum().item():.3f}  dst(on gpu1)={b1.double().sum().item():.3f}")

# 3) Bandwidth each direction
bytes_ = a0.element_size() * a0.numel()
def bw(dst, src, iters=30):
    for _ in range(5):           # warmup
        dst.copy_(src)
    torch.cuda.synchronize()
    t0 = time.perf_counter()
    for _ in range(iters):
        dst.copy_(src)
    torch.cuda.synchronize()
    dt = time.perf_counter() - t0
    return bytes_ * iters / dt / 1e9

gb01 = bw(b1, a0)                 # 0 -> 1
gb10 = bw(back, b1)              # 1 -> 0
print(f"\n[3] P2P bandwidth (1GiB/transfer):")
print(f"    GPU0 -> GPU1 : {gb01:5.1f} GB/s")
print(f"    GPU1 -> GPU0 : {gb10:5.1f} GB/s")

# PCIe link state under load
import subprocess
for g in ('0000:17:00.0', '0000:65:00.0'):
    try:
        sp = open(f'/sys/bus/pci/devices/{g}/current_link_speed').read().strip()
        wd = open(f'/sys/bus/pci/devices/{g}/current_link_width').read().strip()
        print(f"    {g}: {sp} x{wd}")
    except Exception as e:
        print("   link?", e)

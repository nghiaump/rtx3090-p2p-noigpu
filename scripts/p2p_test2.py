import torch

def test_dir(src, dst, N=64*1024*1024):
    g = torch.Generator(device=f'cuda:{src}').manual_seed(1234+src)
    a = torch.rand(N, device=f'cuda:{src}', generator=g)
    b = torch.empty(N, device=f'cuda:{dst}')
    b.copy_(a)                       # peer copy src->dst
    torch.cuda.synchronize()
    ac = a.to('cpu'); bc = b.to('cpu')
    diff = (ac != bc)
    n = int(diff.sum())
    if n == 0:
        print(f"  GPU{src}->GPU{dst}: OK  ({N} phan tu khop tuyet doi)")
    else:
        idx = int(diff.nonzero()[0])
        print(f"  GPU{src}->GPU{dst}: SAI {n}/{N} ({100*n/N:.2f}%)  vi tri dau={idx}")
        print(f"     src[{idx}]={float(ac[idx]):.6f}  dst[{idx}]={float(bc[idx]):.6f}")
        # xem pattern lech: dst co khop voi src dich xa khong (offset bug?)
        for off_mb in (24, -24, 12, 8):
            shift = off_mb*1024*1024//4   # float32
            if 0 < shift < N:
                m = int((ac[:N-shift] != bc[shift:]).sum())
                if m < n//2:
                    print(f"     -> dst khop src DICH {off_mb}MB (offset bug!) mismatch={m}")
    return n == 0

print("=== Correctness tung chieu (random 64M float32 = 256MB) ===")
ok01 = test_dir(0,1)
ok10 = test_dir(1,0)
print(f"\nKET QUA: GPU0->GPU1 {'OK' if ok01 else 'SAI'} | GPU1->GPU0 {'OK' if ok10 else 'SAI'}")

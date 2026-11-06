#!/usr/bin/env python3
"""Generate ALU test vectors and a performance report for the ysyx lab."""
import argparse
import random
import sys

MASK = 0xFFFFFFFF
MEM_WORDS = 1024
EDGE = [0, 1, 2, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000, 0x55555555, 0xAAAAAAAA, 31, 32]
OP_NAMES = {0x0: "add", 0x8: "sub", 0x1: "sll", 0x2: "slt", 0x3: "sltu",
            0x4: "xor", 0x5: "srl", 0xD: "sra", 0x6: "or", 0x7: "and"}


def sext(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


def alu_ref(a, b, op):
    a &= MASK; b &= MASK
    sh = b & 0x1F
    f3, alt = op & 7, (op >> 3) & 1
    if f3 == 0:
        r = a - b if alt else a + b
    elif f3 == 1:
        r = a << sh
    elif f3 == 2:
        r = int(sext(a, 32) < sext(b, 32))
    elif f3 == 3:
        r = int(a < b)
    elif f3 == 4:
        r = a ^ b
    elif f3 == 5:
        r = (sext(a, 32) >> sh) if alt else (a >> sh)
    elif f3 == 6:
        r = a | b
    else:
        r = a & b
    return r & MASK


def gen_vectors(path, seed, count):
    rng = random.Random(seed)
    ops = list(OP_NAMES)
    n = 0
    with open(path, "w") as f:
        for a in EDGE:
            for b in EDGE:
                for op in ops:
                    f.write(f"{a:08x} {b:08x} {op:08x} {alu_ref(a, b, op):08x}\n")
                    n += 1
        for _ in range(count):
            a = rng.getrandbits(32)
            b = rng.choice([rng.getrandbits(32), rng.choice(EDGE), rng.randint(0, 31)])
            op = rng.choice(ops)
            f.write(f"{a:08x} {b:08x} {op:08x} {alu_ref(a, b, op):08x}\n")
            n += 1
    print(f"generated {n} ALU vectors (seed={seed})")


# ---- performance analysis over an executed program ----
def classify(inst):
    opc = inst & 0x7F
    return {0x37: "lui", 0x17: "auipc", 0x6F: "jump", 0x67: "jump", 0x63: "branch",
            0x03: "load", 0x23: "store", 0x13: "alu-imm", 0x33: "alu-reg",
            0x73: "system"}.get(opc, "other")


def perf(hex_path, trace_path):
    mem = [int(x, 16) for x in open(hex_path)]
    commits = [l for l in open(trace_path).read().splitlines()]
    retired = [l for l in commits if l[:8].isalnum() and " " in l and not l.startswith(("HALT", "ILLEGAL", "TIMEOUT"))]
    last = commits[-1]
    mix = {}
    branches = taken = 0
    prev_pc = None
    for i, line in enumerate(retired):
        pc = int(line.split()[0], 16)
        inst = mem[(pc >> 2) % MEM_WORDS]
        cls = classify(inst)
        mix[cls] = mix.get(cls, 0) + 1
        if cls == "branch":
            branches += 1
            nxt = retired[i + 1] if i + 1 < len(retired) else None
            if nxt and int(nxt.split()[0], 16) != pc + 4:
                taken += 1
    instret = len(retired)
    # single-cycle core: cycles = instret + 1 halt cycle
    cycles = instret + 1
    return {
        "instret": instret, "cycles": cycles, "cpi": cycles / instret if instret else 0,
        "mix": mix, "branches": branches, "taken": taken,
        "taken_ratio": taken / branches if branches else 0, "final": last,
    }


def report(programs):
    classes = ["alu-reg", "alu-imm", "branch", "load", "store", "jump", "lui", "auipc"]
    print(f"{'program':14}{'instret':>9}{'cycles':>8}{'CPI':>6}  "
          + "".join(f"{c:>9}" for c in classes) + f"{'br_taken%':>11}")
    for name, hexf, tracef in programs:
        s = perf(hexf, tracef)
        row = f"{name:14}{s['instret']:>9}{s['cycles']:>8}{s['cpi']:>6.2f}  "
        row += "".join(f"{s['mix'].get(c, 0):>9}" for c in classes)
        row += f"{s['taken_ratio'] * 100:>10.1f}%"
        print(row)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("vectors"); g.add_argument("out"); g.add_argument("--seed", type=int, default=1)
    g.add_argument("--count", type=int, default=100000)
    r = sub.add_parser("report"); r.add_argument("triples", nargs="+",
        help="name:hex:trace triples")
    a = p.parse_args()
    if a.cmd == "vectors":
        gen_vectors(a.out, a.seed, a.count)
    else:
        programs = []
        for t in a.triples:
            name, hexf, tracef = t.split(":")
            programs.append((name, hexf, tracef))
        report(programs)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Mini assembler, RV32E reference model and trace difftest for the ysyx_lab_core experiment."""
import argparse
import random
import re
import sys

ABI = {"zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4, "t0": 5, "t1": 6, "t2": 7,
       "s0": 8, "fp": 8, "s1": 9, "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15}
MASK = 0xFFFFFFFF
MEM_WORDS = 1024

R_OPS = {"add": (0, 0), "sub": (0, 0x20), "sll": (1, 0), "slt": (2, 0), "sltu": (3, 0),
         "xor": (4, 0), "srl": (5, 0), "sra": (5, 0x20), "or": (6, 0), "and": (7, 0)}
I_OPS = {"addi": 0, "slti": 2, "sltiu": 3, "xori": 4, "ori": 6, "andi": 7}
SHIFT_I = {"slli": (1, 0), "srli": (5, 0), "srai": (5, 0x20)}
B_OPS = {"beq": 0, "bne": 1, "blt": 4, "bge": 5, "bltu": 6, "bgeu": 7}


def reg(name):
    name = name.strip()
    if name in ABI:
        return ABI[name]
    m = re.fullmatch(r"x(\d+)", name)
    if m and int(m.group(1)) < 16:
        return int(m.group(1))
    raise ValueError(f"RV32E register expected, got {name!r}")


def sext(value, bits):
    value &= (1 << bits) - 1
    return value - (1 << bits) if value >> (bits - 1) else value


def signed(value):
    return sext(value, 32)


def check_range(value, bits, what):
    if not -(1 << (bits - 1)) <= value < (1 << (bits - 1)):
        raise ValueError(f"{what} {value} out of {bits}-bit signed range")


def li_parts(value):
    value = signed(value & MASK)
    if -2048 <= value < 2048:
        return None, value
    lo = sext(value, 12)
    hi = ((value - lo) >> 12) & 0xFFFFF
    return hi, lo


def expand(op, args):
    """Expand pseudo instructions into base instructions (sizes depend only on source text)."""
    if op == "nop":
        return [("addi", ["zero", "zero", "0"])]
    if op == "mv":
        return [("addi", [args[0], args[1], "0"])]
    if op == "j":
        return [("jal", ["zero", args[0]])]
    if op == "ret":
        return [("jalr", ["zero", "ra", "0"])]
    if op == "beqz":
        return [("beq", [args[0], "zero", args[1]])]
    if op == "bnez":
        return [("bne", [args[0], "zero", args[1]])]
    if op == "call":
        return [("jal", ["ra", args[0]])]
    if op == "li":
        hi, lo = li_parts(int(args[1], 0))
        if hi is None:
            return [("addi", [args[0], "zero", str(lo)])]
        out = [("lui", [args[0], str(hi)])]
        if lo:
            out.append(("addi", [args[0], args[0], str(lo)]))
        return out
    if op == "la":
        return [("auipc", [args[0], "0"]), ("addi_label", [args[0], args[0], args[1]])]
    if op == "halt":
        return [("ebreak", [])]
    return [(op, args)]


def parse(path):
    items, labels, words = [], {}, 0
    with open(path) as source:
        for lineno, raw in enumerate(source, 1):
            line = raw.split("#")[0].strip()
            while ":" in line:
                label, line = line.split(":", 1)
                labels[label.strip()] = words * 4
                line = line.strip()
            if not line:
                continue
            if line.startswith(".word"):
                for value in line[5:].split(","):
                    items.append((lineno, ".word", [value.strip()]))
                    words += 1
                continue
            op, _, rest = line.partition(" ")
            args = [a.strip() for a in rest.split(",")] if rest.strip() else []
            for base in expand(op.lower(), args):
                items.append((lineno, base[0], base[1]))
                words += 1
    return items, labels


def target(text, labels, pc):
    return labels[text] - pc if text in labels else int(text, 0)


def mem_operand(text):
    m = re.fullmatch(r"\s*(-?\w+)\((\w+)\)\s*", text)
    if not m:
        raise ValueError(f"memory operand expected, got {text!r}")
    return int(m.group(1), 0), reg(m.group(2))


def encode(op, a, labels, pc):
    if op == ".word":
        return int(a[0], 0) & MASK
    if op in R_OPS:
        f3, f7 = R_OPS[op]
        return f7 << 25 | reg(a[2]) << 20 | reg(a[1]) << 15 | f3 << 12 | reg(a[0]) << 7 | 0x33
    if op in I_OPS:
        imm = int(a[2], 0); check_range(imm, 12, op)
        return (imm & 0xFFF) << 20 | reg(a[1]) << 15 | I_OPS[op] << 12 | reg(a[0]) << 7 | 0x13
    if op == "addi_label":
        imm = labels[a[2]] - (pc - 4); check_range(imm, 12, "la")
        return (imm & 0xFFF) << 20 | reg(a[1]) << 15 | reg(a[0]) << 7 | 0x13
    if op in SHIFT_I:
        f3, f7 = SHIFT_I[op]; sh = int(a[2], 0)
        if not 0 <= sh < 32:
            raise ValueError("shift amount out of range")
        return f7 << 25 | sh << 20 | reg(a[1]) << 15 | f3 << 12 | reg(a[0]) << 7 | 0x13
    if op in ("lui", "auipc"):
        imm = int(a[1], 0) & 0xFFFFF
        return imm << 12 | reg(a[0]) << 7 | (0x37 if op == "lui" else 0x17)
    if op == "jal":
        off = target(a[1], labels, pc); check_range(off, 21, op)
        o = off & 0x1FFFFF
        return ((o >> 20) & 1) << 31 | ((o >> 1) & 0x3FF) << 21 | ((o >> 11) & 1) << 20 | \
               ((o >> 12) & 0xFF) << 12 | reg(a[0]) << 7 | 0x6F
    if op == "jalr":
        imm = int(a[2], 0); check_range(imm, 12, op)
        return (imm & 0xFFF) << 20 | reg(a[1]) << 15 | reg(a[0]) << 7 | 0x67
    if op in B_OPS:
        off = target(a[2], labels, pc); check_range(off, 13, op)
        o = off & 0x1FFF
        return ((o >> 12) & 1) << 31 | ((o >> 5) & 0x3F) << 25 | reg(a[1]) << 20 | reg(a[0]) << 15 | \
               B_OPS[op] << 12 | ((o >> 1) & 0xF) << 8 | ((o >> 11) & 1) << 7 | 0x63
    if op == "lw":
        imm, base = mem_operand(a[1]); check_range(imm, 12, op)
        return (imm & 0xFFF) << 20 | base << 15 | 2 << 12 | reg(a[0]) << 7 | 0x03
    if op == "sw":
        imm, base = mem_operand(a[1]); check_range(imm, 12, op); i = imm & 0xFFF
        return (i >> 5) << 25 | reg(a[0]) << 20 | base << 15 | 2 << 12 | (i & 0x1F) << 7 | 0x23
    if op == "ebreak":
        return 0x00100073
    raise ValueError(f"unsupported instruction {op!r}")


def assemble(src, out):
    items, labels = parse(src)
    words = []
    for index, (lineno, op, args) in enumerate(items):
        try:
            words.append(encode(op, args, labels, index * 4))
        except (ValueError, KeyError) as err:
            sys.exit(f"{src}:{lineno}: {err}")
    if len(words) > MEM_WORDS:
        sys.exit("program exceeds memory")
    with open(out, "w") as f:
        f.writelines(f"{w:08x}\n" for w in words)
    return len(words)


def run_reference(hex_path, trace_path, max_steps=200000):
    mem = [0] * MEM_WORDS
    with open(hex_path) as f:
        for i, line in enumerate(f):
            mem[i] = int(line, 16)
    x = [0] * 16
    pc = 0
    out = []
    for _ in range(max_steps):
        inst = mem[(pc >> 2) % MEM_WORDS]
        opc, rd, f3 = inst & 0x7F, (inst >> 7) & 0x1F, (inst >> 12) & 7
        rs1, rs2, f7 = (inst >> 15) & 0x1F, (inst >> 20) & 0x1F, inst >> 25
        if inst == 0x00100073:
            out.append(f"HALT {x[10]:08x}")
            break
        writes_rd = opc in (0x37, 0x17, 0x6F, 0x67, 0x03, 0x13, 0x33)
        uses_rs1 = opc in (0x67, 0x63, 0x03, 0x23, 0x13, 0x33)
        uses_rs2 = opc in (0x63, 0x23, 0x33)
        if (writes_rd and rd > 15) or (uses_rs1 and rs1 > 15) or (uses_rs2 and rs2 > 15):
            out.append(f"ILLEGAL {pc:08x}")
            break
        a, b = (x[rs1] if rs1 < 16 else 0), (x[rs2] if rs2 < 16 else 0)
        imm_i = sext(inst >> 20, 12)
        wen, val, npc = False, 0, (pc + 4) & MASK
        legal = True
        if opc == 0x37:
            wen, val = True, inst & 0xFFFFF000
        elif opc == 0x17:
            wen, val = True, (pc + (inst & 0xFFFFF000)) & MASK
        elif opc == 0x6F:
            off = sext(((inst >> 31) << 20) | (((inst >> 12) & 0xFF) << 12) | (((inst >> 20) & 1) << 11) |
                       (((inst >> 21) & 0x3FF) << 1), 21)
            wen, val, npc = True, (pc + 4) & MASK, (pc + off) & MASK
        elif opc == 0x67 and f3 == 0:
            wen, val, npc = True, (pc + 4) & MASK, ((a + imm_i) & MASK) & ~1
        elif opc == 0x63 and f3 not in (2, 3):
            off = sext(((inst >> 31) << 12) | (((inst >> 7) & 1) << 11) | (((inst >> 25) & 0x3F) << 5) |
                       (((inst >> 8) & 0xF) << 1), 13)
            take = {0: a == b, 1: a != b, 4: signed(a) < signed(b), 5: signed(a) >= signed(b),
                    6: a < b, 7: a >= b}[f3]
            if take:
                npc = (pc + off) & MASK
        elif opc == 0x03 and f3 == 2:
            addr = (a + imm_i) & MASK
            legal = addr % 4 == 0
            wen, val = True, mem[(addr >> 2) % MEM_WORDS]
        elif opc == 0x23 and f3 == 2:
            addr = (a + sext(((inst >> 25) << 5) | ((inst >> 7) & 0x1F), 12)) & MASK
            legal = addr % 4 == 0
            if legal:
                mem[(addr >> 2) % MEM_WORDS] = b
        elif opc in (0x13, 0x33):
            is_reg = opc == 0x33
            bb = b if is_reg else imm_i & MASK
            sh = bb & 0x1F
            alt = (f7 >> 5) & 1
            if is_reg:
                legal = f7 == 0 or (f7 == 0x20 and f3 in (0, 5))
            elif f3 == 1:
                legal = f7 == 0
            elif f3 == 5:
                legal = f7 in (0, 0x20)
            val = {0: (a - bb) if (is_reg and alt) else (a + bb), 1: a << sh,
                   2: int(signed(a) < signed(bb)), 3: int(a < bb), 4: a ^ bb,
                   5: (signed(a) >> sh) if alt else (a >> sh), 6: a | bb, 7: a & bb}[f3] & MASK
            wen = True
        else:
            legal = False
        if not legal:
            out.append(f"ILLEGAL {pc:08x}")
            break
        if wen and rd != 0:
            x[rd] = val
            out.append(f"{pc:08x} x{rd}={val:08x}")
        else:
            out.append(f"{pc:08x} -")
        pc = npc
    else:
        out.append("TIMEOUT")
    with open(trace_path, "w") as f:
        f.write("\n".join(out) + "\n")
    return out[-1]


def difftest(ref_path, dut_path):
    ref = open(ref_path).read().splitlines()
    dut = open(dut_path).read().splitlines()
    for i, (r, d) in enumerate(zip(ref, dut)):
        if r != d:
            print(f"DIFFTEST MISMATCH at commit #{i}")
            for j in range(max(0, i - 3), i):
                print(f"   ok   {ref[j]}")
            print(f"   REF  {r}\n   DUT  {d}")
            return 1
    if len(ref) != len(dut):
        print(f"DIFFTEST LENGTH MISMATCH ref={len(ref)} dut={len(dut)}")
        return 1
    print(f"DIFFTEST PASS {len(ref) - 1} commits, final: {ref[-1]}")
    return 0


def gen_random(path, seed, count):
    rng = random.Random(seed)
    regs = ["t0", "t1", "t2", "s0", "s1", "a1", "a2", "a3", "a4", "a5"]
    lines = [f"# constrained-random ALU test, seed={seed}"]
    for r in regs:
        lines.append(f"li {r}, {rng.choice([0, 1, -1, 0x7FFFFFFF, -0x80000000, rng.getrandbits(32)])}")
    for _ in range(count):
        kind = rng.random()
        rd, r1, r2 = rng.choice(regs), rng.choice(regs), rng.choice(regs)
        if kind < 0.45:
            lines.append(f"{rng.choice(list(R_OPS))} {rd}, {r1}, {r2}")
        elif kind < 0.75:
            lines.append(f"{rng.choice(list(I_OPS))} {rd}, {r1}, {rng.randint(-2048, 2047)}")
        elif kind < 0.9:
            lines.append(f"{rng.choice(list(SHIFT_I))} {rd}, {r1}, {rng.randint(0, 31)}")
        else:
            lines.append(f"sw {r1}, {rng.randrange(0, 64) * 4}(gp)")
            lines.append(f"lw {rd}, {rng.randrange(0, 64) * 4}(gp)")
    lines[1:1] = ["li gp, 3072"]
    lines += ["li a0, 0", "halt"]
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("asm"); s.add_argument("src"); s.add_argument("out")
    s = sub.add_parser("ref"); s.add_argument("hex"); s.add_argument("trace")
    s = sub.add_parser("diff"); s.add_argument("ref"); s.add_argument("dut")
    s = sub.add_parser("random"); s.add_argument("out"); s.add_argument("--seed", type=int, default=1)
    s.add_argument("--count", type=int, default=300)
    args = p.parse_args()
    if args.cmd == "asm":
        print(f"assembled {assemble(args.src, args.out)} words")
    elif args.cmd == "ref":
        print(f"reference: {run_reference(args.hex, args.trace)}")
    elif args.cmd == "diff":
        sys.exit(difftest(args.ref, args.dut))
    else:
        gen_random(args.out, args.seed, args.count)


if __name__ == "__main__":
    main()

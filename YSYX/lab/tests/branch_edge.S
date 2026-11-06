# Signed/unsigned compare and shift edge cases; each failed check exits with a distinct code.
    li t0, -1
    li t1, 1
    li a0, 1
    bge t0, t1, fail          # signed: -1 < 1
    li a0, 2
    bltu t0, t1, fail         # unsigned: 0xffffffff > 1
    li a0, 3
    slt a1, t0, t1
    beqz a1, fail
    li a0, 4
    sltu a1, t0, t1
    bnez a1, fail
    li a0, 5
    li t2, -2147483648
    srai a2, t2, 31
    bne a2, t0, fail          # arithmetic shift keeps sign
    li a0, 6
    srli a3, t2, 31
    bne a3, t1, fail          # logical shift inserts zero
    li a0, 7
    sltiu a4, zero, 1         # seqz idiom
    bne a4, t1, fail
    li a0, 8
    lui a5, 0x80000
    bne a5, t2, fail
    li a0, 9
    auipc s0, 0
    jal s1, next
next:
    sub s1, s1, s0
    li t0, 8
    bne s1, t0, fail
    li a0, 0
fail:
    halt

# Bubble sort of 12 signed words, then verify non-decreasing order with blt.
    la s0, data
    li s1, 12
outer:
    li t0, 1
    li a5, 0             # swapped flag
inner:
    bge t0, s1, inner_done
    slli t1, t0, 2
    add t1, t1, s0
    lw a1, -4(t1)
    lw a2, 0(t1)
    bge a2, a1, no_swap
    sw a2, -4(t1)
    sw a1, 0(t1)
    li a5, 1
no_swap:
    addi t0, t0, 1
    j inner
inner_done:
    bnez a5, outer
    li t0, 1
check:
    bge t0, s1, pass
    slli t1, t0, 2
    add t1, t1, s0
    lw a1, -4(t1)
    lw a2, 0(t1)
    blt a2, a1, fail
    addi t0, t0, 1
    j check
pass:
    li a0, 0
    halt
fail:
    li a0, 1
    halt
data:
    .word 42, -7, 1000, 0, -2147483648, 2147483647, 5, 5, -1, 13, 99, -300

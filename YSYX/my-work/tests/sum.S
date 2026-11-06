# Sum 1..100 and compare with 5050 (F-stage style program on the RV32E core).
    li t0, 0          # sum
    li t1, 1          # i
    li t2, 101
loop:
    add t0, t0, t1
    addi t1, t1, 1
    bne t1, t2, loop
    li a1, 5050
    sub a0, t0, a1    # a0 = 0 when correct
    halt

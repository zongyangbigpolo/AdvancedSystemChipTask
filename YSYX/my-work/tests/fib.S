# Recursive fib(15) = 610 with stack frames, exercising jal/jalr and lw/sw.
    li sp, 4096
    li a0, 15
    call fib
    li a1, 610
    sub a0, a0, a1
    halt
fib:
    li t0, 2
    blt a0, t0, fib_base
    addi sp, sp, -12
    sw ra, 8(sp)
    sw s0, 4(sp)
    sw s1, 0(sp)
    mv s0, a0
    addi a0, s0, -1
    call fib
    mv s1, a0
    addi a0, s0, -2
    call fib
    add a0, a0, s1
    lw s1, 0(sp)
    lw s0, 4(sp)
    lw ra, 8(sp)
    addi sp, sp, 12
fib_base:
    ret

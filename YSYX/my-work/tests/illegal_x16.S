# Negative test: "addi x16, x0, 1" is not available in RV32E and must stop with ILLEGAL.
    li a0, 0
    .word 0x00100813
    halt
